//! 通用 tombstone GC(v0.7.20):按设备游标回收已删条目。
//!
//! 背景:`sync_items`(非 history 域)的墓碑此前**永久保留**——删除在 LWW 里
//! 就是普通一行,任何"所有设备都已经看到这次删除"的判定都要求设备侧游标。
//! 本模块补上这条闭环:
//!
//! - **上报**:拉取请求带 `device` 参数时,把该设备的复合游标
//!   `(updated_at, id)` 记进 `sync_pull_cursors`(`seen_at` 每次刷新)。
//!   游标 = 请求里的 `since`(即"这次拉取之前已经拥有的全部行")——保守,
//!   比按响应末条记账迟一轮,但绝不多删。
//! - **回收**:对每个域取**活跃设备**(90 天内拉过)的最小游标,删除
//!   `updated_at ≤ 最小游标` **且**超过宽限期(30 天)的墓碑;设备游标为
//!   NULL(旧版 ts-only 客户端)视为已见该时刻全部行。
//! - **兜底**:没有任何活跃设备游标(老客户端/从未增量拉过)→ 只删超过
//!   180 天的墓碑。
//! - **残留风险(写明)**:180 天没拉过的设备其游标被清理后,它"没见过的
//!   删除"可能被 GC 掉,该设备下次同步时会把本地副本当新写入推上来(复活)。
//!   这是拿掉台账的代价:判据是"半年没同步的设备"本来就与现状分叉严重,
//!   复活语义与"离线设备重连"一致,不额外加锁。history 域不走这里(0007
//!   起已有 90 天 TTL,含墓碑)。
//!
//! 触发:拉取后 best-effort 限量跑(每用户每小时一次)+ 显式
//! `POST /sync/gc`(运维/测试,限自己的数据)+ `desire-admin sync gc`(全量)。

use std::collections::{BTreeMap, HashMap};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use chrono::NaiveDateTime;
use serde::Serialize;
use sqlx::MySqlPool;
use tracing::{info, warn};
use utoipa::ToSchema;

use super::sync_model::DOMAINS;

/// 活跃设备判定窗口(天):超过就不再用它的游标挡 GC。
pub const CURSOR_ACTIVE_DAYS: i64 = 90;
/// 墓碑宽限期(天):无论游标怎样,太新的墓碑不删(给离线设备留余地)。
pub const GC_GRACE_DAYS: i64 = 30;
/// 无任何活跃游标时的兜底保留期(天);也是过期设备游标的清理窗口。
pub const GC_FALLBACK_DAYS: i64 = 180;

/// GC 结果(运维/测试断言用)。
#[derive(Debug, Serialize, ToSchema)]
pub struct GcReport {
  pub dry_run: bool,
  /// 各域被删(或 dry-run 下将被删)的墓碑数(只含非零域)。
  pub deleted: BTreeMap<String, u64>,
  /// 各域采用的判定来源:`cursor`(活跃设备最小游标)/`fallback`(无游标)。
  pub basis: BTreeMap<String, String>,
  /// 顺带清理的过期设备游标行数。
  pub stale_cursors: u64,
}

/// 拉取后上报设备游标(`since` 缺省 = 全量,不上报——全量拉完的游标要等
/// 下一次增量拉取才知道,保守记为未知)。
pub async fn record_pull_cursor(
  pool: &MySqlPool,
  user_id: i64,
  domain: &str,
  device_id: &str,
  since: Option<NaiveDateTime>,
  since_id: Option<i64>,
) {
  let Some(ts) = since else { return };
  let result = sqlx::query(
    "INSERT INTO sync_pull_cursors \
     (user_id, domain, device_id, cursor_updated_at, cursor_id) VALUES (?, ?, ?, ?, ?) \
     ON DUPLICATE KEY UPDATE cursor_updated_at = VALUES(cursor_updated_at), \
     cursor_id = VALUES(cursor_id), seen_at = CURRENT_TIMESTAMP(6)",
  )
  .bind(user_id)
  .bind(domain)
  .bind(device_id)
  .bind(ts)
  .bind(since_id)
  .execute(pool)
  .await;
  if let Err(e) = result {
    warn!("record pull cursor failed (user {user_id} domain {domain}): {e}");
  }
}

/// 拉取后的限量 GC:每用户每小时最多一次,best-effort(失败只记日志)。
pub async fn maybe_gc_after_pull(pool: &MySqlPool, user_id: i64) {
  static LAST_RUN: OnceLock<Mutex<HashMap<i64, Instant>>> = OnceLock::new();
  let map = LAST_RUN.get_or_init(|| Mutex::new(HashMap::new()));
  {
    let mut guard = match map.lock() {
      Ok(guard) => guard,
      Err(_) => return,
    };
    let now = Instant::now();
    if let Some(last) = guard.get(&user_id)
      && now.duration_since(*last) < Duration::from_secs(3600)
    {
      return;
    }
    guard.insert(user_id, now);
  }
  match gc_tombstones(pool, user_id, false).await {
    Ok(report) if !report.deleted.is_empty() => {
      info!("sync gc (user {user_id}): {report:?}");
    }
    Ok(_) => {}
    Err(e) => warn!("sync gc failed (user {user_id}): {e}"),
  }
}

/// 对单个用户跑一遍 GC(全部通用域)。`dry_run` = 只数不删。
pub async fn gc_tombstones(
  pool: &MySqlPool,
  user_id: i64,
  dry_run: bool,
) -> Result<GcReport, sqlx::Error> {
  let mut report = GcReport {
    dry_run,
    deleted: BTreeMap::new(),
    basis: BTreeMap::new(),
    stale_cursors: 0,
  };
  for domain in DOMAINS {
    // history 有独立 TTL(0007),不走通用墓碑回收。
    if *domain == "history" {
      continue;
    }
    let affected = match min_active_cursor(pool, user_id, domain).await? {
      Some((ts, id)) => {
        report.basis.insert((*domain).to_string(), "cursor".to_string());
        if dry_run {
          count_cursor_cutoff(pool, user_id, domain, ts, id).await?
        } else {
          delete_cursor_cutoff(pool, user_id, domain, ts, id).await?
        }
      }
      None => {
        report
          .basis
          .insert((*domain).to_string(), "fallback".to_string());
        if dry_run {
          count_fallback(pool, user_id, domain).await?
        } else {
          delete_fallback(pool, user_id, domain).await?
        }
      }
    };
    if affected > 0 {
      report.deleted.insert((*domain).to_string(), affected);
    }
  }
  // 过期设备游标(180 天没拉过)顺带清理——它们不再参与判定,留着只是垃圾。
  if !dry_run {
    let purged = sqlx::query(
      "DELETE FROM sync_pull_cursors WHERE user_id = ? \
       AND seen_at < NOW() - INTERVAL ? DAY",
    )
    .bind(user_id)
    .bind(GC_FALLBACK_DAYS)
    .execute(pool)
    .await?;
    report.stale_cursors = purged.rows_affected();
  }
  Ok(report)
}

/// 活跃设备游标的最小 `(updated_at, id)`;无 = None。`cursor_id` 为 NULL 的
/// 行按 i64::MAX 处理(旧版 ts-only 客户端 = 已见该时刻全部行)。
async fn min_active_cursor(
  pool: &MySqlPool,
  user_id: i64,
  domain: &str,
) -> Result<Option<(NaiveDateTime, i64)>, sqlx::Error> {
  let rows: Vec<(Option<NaiveDateTime>, Option<i64>)> = sqlx::query_as(
    "SELECT cursor_updated_at, cursor_id FROM sync_pull_cursors \
     WHERE user_id = ? AND domain = ? AND cursor_updated_at IS NOT NULL \
     AND seen_at >= NOW() - INTERVAL ? DAY",
  )
  .bind(user_id)
  .bind(domain)
  .bind(CURSOR_ACTIVE_DAYS)
  .fetch_all(pool)
  .await?;
  Ok(
    rows
      .into_iter()
      .filter_map(|(ts, id)| ts.map(|ts| (ts, id.unwrap_or(i64::MAX))))
      .min(),
  )
}

/// 游标判定支的删除条件 = 宽限 AND (updated_at, id) ≤ 最小游标。
const DELETE_CURSOR_SQL: &str = "DELETE FROM sync_items WHERE user_id = ? AND domain = ? \
   AND deleted_at IS NOT NULL \
   AND updated_at < NOW() - INTERVAL ? DAY \
   AND (updated_at < ? OR (updated_at = ? AND id <= ?))";

/// 无游标兜底支 = 只保留期判据。
const DELETE_FALLBACK_SQL: &str = "DELETE FROM sync_items WHERE user_id = ? AND domain = ? \
   AND deleted_at IS NOT NULL AND updated_at < NOW() - INTERVAL ? DAY";

/// dry-run 的配套 COUNT(与两条 DELETE 同条件;sqlx 0.9 对动态 SQL 有
/// 编译期审计,静态常量而非拼接)。
const COUNT_CURSOR_SQL: &str = "SELECT COUNT(*) FROM sync_items WHERE user_id = ? AND domain = ? \
   AND deleted_at IS NOT NULL \
   AND updated_at < NOW() - INTERVAL ? DAY \
   AND (updated_at < ? OR (updated_at = ? AND id <= ?))";

const COUNT_FALLBACK_SQL: &str = "SELECT COUNT(*) FROM sync_items WHERE user_id = ? AND domain = ? \
   AND deleted_at IS NOT NULL AND updated_at < NOW() - INTERVAL ? DAY";

async fn count_cursor_cutoff(
  pool: &MySqlPool,
  user_id: i64,
  domain: &str,
  ts: NaiveDateTime,
  id: i64,
) -> Result<u64, sqlx::Error> {
  let count: i64 = sqlx::query_scalar(COUNT_CURSOR_SQL)
    .bind(user_id)
    .bind(domain)
    .bind(GC_GRACE_DAYS)
    .bind(ts)
    .bind(ts)
    .bind(id)
    .fetch_one(pool)
    .await?;
  Ok(count.max(0) as u64)
}

async fn delete_cursor_cutoff(
  pool: &MySqlPool,
  user_id: i64,
  domain: &str,
  ts: NaiveDateTime,
  id: i64,
) -> Result<u64, sqlx::Error> {
  let result = sqlx::query(DELETE_CURSOR_SQL)
    .bind(user_id)
    .bind(domain)
    .bind(GC_GRACE_DAYS)
    .bind(ts)
    .bind(ts)
    .bind(id)
    .execute(pool)
    .await?;
  Ok(result.rows_affected())
}

async fn count_fallback(
  pool: &MySqlPool,
  user_id: i64,
  domain: &str,
) -> Result<u64, sqlx::Error> {
  let count: i64 = sqlx::query_scalar(COUNT_FALLBACK_SQL)
    .bind(user_id)
    .bind(domain)
    .bind(GC_FALLBACK_DAYS)
    .fetch_one(pool)
    .await?;
  Ok(count.max(0) as u64)
}

async fn delete_fallback(
  pool: &MySqlPool,
  user_id: i64,
  domain: &str,
) -> Result<u64, sqlx::Error> {
  let result = sqlx::query(DELETE_FALLBACK_SQL)
    .bind(user_id)
    .bind(domain)
    .bind(GC_FALLBACK_DAYS)
    .execute(pool)
    .await?;
  Ok(result.rows_affected())
}

/// 全部用户跑一遍(`desire-admin sync gc` 用;逐个用户,失败不中断)。
pub async fn gc_all_users(pool: &MySqlPool, dry_run: bool) -> Result<Vec<(i64, GcReport)>, sqlx::Error> {
  let user_ids: Vec<i64> = sqlx::query_scalar("SELECT DISTINCT user_id FROM sync_items")
    .fetch_all(pool)
    .await?;
  let mut out = Vec::new();
  for user_id in user_ids {
    match gc_tombstones(pool, user_id, dry_run).await {
      Ok(report) => out.push((user_id, report)),
      Err(e) => warn!("sync gc failed (user {user_id}): {e}"),
    }
  }
  Ok(out)
}
