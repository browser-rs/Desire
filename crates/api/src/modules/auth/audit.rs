//! 账号安全审计（v0.8.80 批 7）：登录/登出/改密/设备吊销/恢复等事件留痕。
//! best-effort：审计失败只记日志，绝不让安全动作失败。

use sqlx::MySqlPool;
use tracing::warn;

pub async fn record(pool: &MySqlPool, user_id: Option<i64>, event: &str, detail: &str, ip: &str) {
  let result =
    sqlx::query("INSERT INTO audit_events (user_id, event, detail, ip) VALUES (?, ?, ?, ?)")
      .bind(user_id)
      .bind(event)
      .bind(detail.chars().take(255).collect::<String>())
      .bind(ip.chars().take(64).collect::<String>())
      .execute(pool)
      .await;
  if let Err(error) = result {
    warn!("audit event '{event}' failed: {error}");
  }
}

/// 用户自查：最近 N 条（不含其它用户数据）。
pub async fn recent(
  pool: &MySqlPool,
  user_id: i64,
  limit: i64,
) -> Result<Vec<(i64, String, String, String, chrono::NaiveDateTime)>, sqlx::Error> {
  sqlx::query_as(
    "SELECT id, event, detail, ip, created_at FROM audit_events \
     WHERE user_id = ? ORDER BY id DESC LIMIT ?",
  )
  .bind(user_id)
  .bind(limit.clamp(1, 200))
  .fetch_all(pool)
  .await
}
