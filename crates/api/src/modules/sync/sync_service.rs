use chrono::{NaiveDateTime, Utc};

use crate::errors::AppError;
use crate::types::AppState;

use super::sync_model::{
  MAX_PUSH_ITEMS, PULL_LIMIT, SyncPullResp, SyncPushItem, SyncPushResp, SyncPushResultItem,
  SyncRowRaw,
};

/// 拉取:updated_at 严格大于 since 的全部行(含 tombstone),按 updated_at 升序,
/// 单批 ≤1000;客户端把游标推进到末条 updated_at 再拉下一页。
/// since 缺省 = 全量(新设备首拉)。
pub async fn pull(
  state: &AppState,
  user_id: i64,
  domain: &str,
  since: Option<NaiveDateTime>,
) -> Result<SyncPullResp, AppError> {
  let rows = match since {
    None => {
      sqlx::query_as::<_, SyncRowRaw>(
        "SELECT id, client_id, client_updated_at, deleted_at, \
         CAST(payload AS CHAR) AS payload_str, updated_at \
         FROM sync_items WHERE user_id = ? AND domain = ? \
         ORDER BY updated_at LIMIT ?",
      )
      .bind(user_id)
      .bind(domain)
      .bind(PULL_LIMIT)
      .fetch_all(&state.pool)
      .await?
    }
    Some(since) => {
      sqlx::query_as::<_, SyncRowRaw>(
        "SELECT id, client_id, client_updated_at, deleted_at, \
         CAST(payload AS CHAR) AS payload_str, updated_at \
         FROM sync_items WHERE user_id = ? AND domain = ? AND updated_at > ? \
         ORDER BY updated_at LIMIT ?",
      )
      .bind(user_id)
      .bind(domain)
      .bind(since)
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

/// 推送:逐条在事务内 SELECT .. FOR UPDATE 后按 client_updated_at LWW 仲裁。
/// - 无行或本地更新 → 覆盖(applied);
/// - 服务端更新 → 拒收,conflict 并给回服务端胜出版本(客户端应采纳);
/// - deleted=true → tombstone:deleted_at 置位 + payload 置 NULL。
/// payload 解析失败属数据损坏 → 500(Internal),不该静默吞。
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
        .bind(item.client_updated_at)
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
        if item.client_updated_at > row.client_updated_at {
          let payload = if item.deleted { None } else { item.payload };
          sqlx::query(
            "UPDATE sync_items SET payload = ?, client_updated_at = ?, deleted_at = ? WHERE id = ?",
          )
          .bind(payload)
          .bind(item.client_updated_at)
          .bind(if item.deleted { Some(now) } else { None })
          .bind(row.id)
          .execute(&mut *tx)
          .await?;
          SyncPushResultItem {
            client_id: client_id.to_string(),
            status: "applied".into(),
            item: None,
          }
        } else {
          // 服务端版本更新(或同刻):拒收,回传胜出版本让客户端对齐
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

#[cfg(test)]
mod tests {
  use super::parse_since;
  use crate::errors::AppError;

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
}
