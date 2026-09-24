use chrono::{NaiveDateTime, Utc};

use crate::errors::AppError;
use crate::types::AppState;

use super::sync_model::{
  MAX_PAYLOAD_BYTES, MAX_PUSH_ITEMS, PULL_LIMIT, SyncItemDto, SyncPullResp, SyncPushItem,
  SyncPushResp, SyncPushResultItem, SyncRowRaw,
};

/// 拉取:增量行(含 tombstone),按 (updated_at, id) 升序,单批 ≤1000。
/// 游标语义:
/// - 仅 `since`(naive ts):updated_at > since —— 旧版客户端兼容;
/// - `since` + `since_id`:**(updated_at, id) 字典序 >** (since, since_id) ——
///   复合游标,消除同 updated_at 行恰跨分页边界时 `> ts` 永久跳过的静默丢失。
/// since 缺省 = 全量(新设备首拉)。
pub async fn pull(
  state: &AppState,
  user_id: i64,
  domain: &str,
  since: Option<NaiveDateTime>,
  since_id: Option<i64>,
) -> Result<SyncPullResp, AppError> {
  let rows = match (since, since_id) {
    (None, _) => {
      sqlx::query_as::<_, SyncRowRaw>(
        "SELECT id, client_id, client_updated_at, deleted_at, \
         CAST(payload AS CHAR) AS payload_str, updated_at \
         FROM sync_items WHERE user_id = ? AND domain = ? \
         ORDER BY updated_at, id LIMIT ?",
      )
      .bind(user_id)
      .bind(domain)
      .bind(PULL_LIMIT)
      .fetch_all(&state.pool)
      .await?
    }
    (Some(ts), Some(id)) => {
      sqlx::query_as::<_, SyncRowRaw>(
        "SELECT id, client_id, client_updated_at, deleted_at, \
         CAST(payload AS CHAR) AS payload_str, updated_at \
         FROM sync_items \
         WHERE user_id = ? AND domain = ? AND (updated_at > ? OR (updated_at = ? AND id > ?)) \
         ORDER BY updated_at, id LIMIT ?",
      )
      .bind(user_id)
      .bind(domain)
      .bind(ts)
      .bind(ts)
      .bind(id)
      .bind(PULL_LIMIT)
      .fetch_all(&state.pool)
      .await?
    }
    (Some(ts), None) => {
      sqlx::query_as::<_, SyncRowRaw>(
        "SELECT id, client_id, client_updated_at, deleted_at, \
         CAST(payload AS CHAR) AS payload_str, updated_at \
         FROM sync_items WHERE user_id = ? AND domain = ? AND updated_at > ? \
         ORDER BY updated_at, id LIMIT ?",
      )
      .bind(user_id)
      .bind(domain)
      .bind(ts)
      .bind(PULL_LIMIT)
      .fetch_all(&state.pool)
      .await?
    }
  };
  let mut items = Vec::with_capacity(rows.len());
  for row in rows {
    let client_id = row.client_id.clone();
    items.push(row.into_dto().map_err(|e| {
      AppError::Internal(format!(
        "sync payload decode failed (client_id={client_id}): {e}"
      ))
    })?);
  }
  Ok(SyncPullResp {
    items,
    server_time: Utc::now().naive_utc(),
  })
}

/// 单条推送的时间戳钳制:低于 2000 年(如客户端 .distantPast 泄漏会撞
/// MySQL DATETIME 下限)或超前服务器 5 分钟以上(快钟设备可永久霸占 LWW)
/// 都钳回边界内。
fn clamp_client_stamp(ts: NaiveDateTime, now: NaiveDateTime) -> NaiveDateTime {
  let min =
    NaiveDateTime::parse_from_str("2000-01-01T00:00:00", "%Y-%m-%dT%H:%M:%S").expect("固定常量");
  let max = now + chrono::Duration::minutes(5);
  ts.max(min).min(max)
}

/// 推送:逐条在事务内 SELECT .. FOR UPDATE 后按 client_updated_at LWW 仲裁。
/// - 无行 → 插入(applied);
/// - 客户端戳 **>=** 服务端 → 覆盖;**等于 = 幂等重放:不写库直接 applied**
///   (拉取/冲突采纳过的条目其戳与服务端相等,严格 `>` 会让它们每轮全量
///   push 都吃一次 conflict 回包,纯属噪音);
/// - 客户端戳更旧 → 拒收,conflict 并给回服务端胜出版本(客户端应采纳);
/// - deleted=true → tombstone:deleted_at 置位 + payload 置 NULL(已删内容不留库)。
pub async fn push(
  state: &AppState,
  user_id: i64,
  domain: &str,
  items: Vec<SyncPushItem>,
) -> Result<SyncPushResp, AppError> {
  if items.len() > MAX_PUSH_ITEMS {
    return Err(AppError::Validation(format!(
      "单批最多 {} 条",
      MAX_PUSH_ITEMS
    )));
  }
  let mut results = Vec::with_capacity(items.len());
  let now = Utc::now().naive_utc();
  let mut tx = state.pool.begin().await?;
  for item in items {
    let client_id = item.client_id.trim();
    if client_id.is_empty() || client_id.len() > 64 {
      return Err(AppError::Validation("client_id 须为 1-64 字符".into()));
    }
    if let Some(payload) = &item.payload {
      let size = serde_json::to_vec(payload)
        .map_err(|e| AppError::Internal(format!("payload 序列化失败: {e}")))?
        .len();
      if size > MAX_PAYLOAD_BYTES {
        return Err(AppError::Validation(format!(
          "单条 payload 最大 {} 字节",
          MAX_PAYLOAD_BYTES
        )));
      }
    }
    let client_at = clamp_client_stamp(item.client_updated_at, now);
    let existing = sqlx::query_as::<_, SyncRowRaw>(
      "SELECT id, client_id, client_updated_at, deleted_at, \
       CAST(payload AS CHAR) AS payload_str, updated_at \
       FROM sync_items WHERE user_id = ? AND domain = ? AND client_id = ? FOR UPDATE",
    )
    .bind(user_id)
    .bind(domain)
    .bind(client_id)
    .fetch_optional(&mut *tx)
    .await?;
    let result = match existing {
      None => {
        let payload = if item.deleted { None } else { item.payload };
        sqlx::query(
          "INSERT INTO sync_items (user_id, domain, client_id, payload, client_updated_at, deleted_at) \
           VALUES (?, ?, ?, ?, ?, ?)",
        )
        .bind(user_id)
        .bind(domain)
        .bind(client_id)
        .bind(payload)
        .bind(client_at)
        .bind(if item.deleted { Some(now) } else { None })
        .execute(&mut *tx)
        .await?;
        SyncPushResultItem {
          client_id: client_id.to_string(),
          status: "applied".into(),
          item: None,
        }
      }
      Some(row) => {
        if client_at > row.client_updated_at {
          let payload = if item.deleted { None } else { item.payload };
          sqlx::query(
            "UPDATE sync_items SET payload = ?, client_updated_at = ?, deleted_at = ? WHERE id = ?",
          )
          .bind(payload)
          .bind(client_at)
          .bind(if item.deleted { Some(now) } else { None })
          .bind(row.id)
          .execute(&mut *tx)
          .await?;
          SyncPushResultItem {
            client_id: client_id.to_string(),
            status: "applied".into(),
            item: None,
          }
        } else if client_at == row.client_updated_at {
          // 幂等重放:同戳视为同一版本,不写库、报 applied。
          // (若同戳却内容不同,先后无从事后区分,维持服务端现状。)
          SyncPushResultItem {
            client_id: client_id.to_string(),
            status: "applied".into(),
            item: None,
          }
        } else {
          // 服务端版本更新:拒收,回传胜出版本让客户端对齐
          let winner = row
            .clone()
            .into_dto()
            .map_err(|e| AppError::Internal(format!("sync payload decode failed: {e}")))?;
          SyncPushResultItem {
            client_id: client_id.to_string(),
            status: "conflict".into(),
            item: Some(winner),
          }
        }
      }
    };
    results.push(result);
  }
  tx.commit().await?;
  Ok(SyncPushResp {
    results,
    server_time: Utc::now().naive_utc(),
  })
}

/// `since` 查询参数解析:无时区 naive datetime,如 `2026-09-24T12:00:00.123456`
/// (与响应里 updated_at 的序列化格式一致,客户端原样回传即可)。
pub fn parse_since(raw: &str) -> Result<NaiveDateTime, AppError> {
  NaiveDateTime::parse_from_str(raw, "%Y-%m-%dT%H:%M:%S%.f").map_err(|_| {
    AppError::Validation("since 须为 naive datetime,如 2026-09-24T12:00:00.123456".into())
  })
}

/// `since_id` 查询参数:复合游标的行 id 部分。
pub fn parse_since_id(raw: &str) -> Result<i64, AppError> {
  raw
    .parse::<i64>()
    .map_err(|_| AppError::Validation("since_id 须为整数".into()))
}

/// 复合游标的排序推进保证:结果集非空时,末条 (updated_at, id) 即新游标。
/// 该函数只做类型收敛,防止客户端拿到 Option。
pub fn last_cursor(items: &[SyncItemDto]) -> Option<(NaiveDateTime, i64)> {
  items.last().map(|item| (item.updated_at, item.id))
}

#[cfg(test)]
mod tests {
  use super::{clamp_client_stamp, parse_since, parse_since_id};
  use crate::errors::AppError;
  use chrono::NaiveDateTime;

  fn ts(s: &str) -> NaiveDateTime {
    NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S").unwrap()
  }

  #[test]
  fn since_parsing() {
    assert!(parse_since("2026-09-24T12:00:00").is_ok());
    assert!(parse_since("2026-09-24T12:00:00.123456").is_ok());
    assert!(matches!(
      parse_since("2026-09-24 12:00:00"),
      Err(AppError::Validation(_))
    ));
    assert!(matches!(
      parse_since("yesterday"),
      Err(AppError::Validation(_))
    ));
  }

  #[test]
  fn since_id_parsing() {
    assert_eq!(parse_since_id("42").unwrap(), 42);
    assert!(matches!(parse_since_id("x"), Err(AppError::Validation(_))));
  }

  #[test]
  fn stamp_clamping() {
    let now = ts("2026-09-25T12:00:00");
    // 正常范围不动
    assert_eq!(
      clamp_client_stamp(ts("2026-09-25T11:59:00"), now),
      ts("2026-09-25T11:59:00")
    );
    // 快钟:超前 5 分钟内保留,超过钳到 now+5min
    assert_eq!(
      clamp_client_stamp(ts("2026-09-25T12:03:00"), now),
      ts("2026-09-25T12:03:00")
    );
    assert_eq!(
      clamp_client_stamp(ts("2026-09-25T12:30:00"), now),
      ts("2026-09-25T12:05:00")
    );
    // 慢钟/.distantPast 泄漏:钳到 2000 年下限(不撞 MySQL DATETIME 下限)
    assert_eq!(
      clamp_client_stamp(ts("1970-01-01T00:00:00"), now),
      ts("2000-01-01T00:00:00")
    );
  }
}
