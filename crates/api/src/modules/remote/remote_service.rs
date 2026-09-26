use std::collections::HashMap;
use std::sync::Arc;

use axum::extract::ws::Message;
use chrono::{Duration, Utc};
use rand::Rng;
use serde_json::json;
use sha2::{Digest, Sha256};
use tokio::sync::{Mutex, mpsc};

use crate::errors::AppError;
use crate::types::AppState;

/// 配对码有效期(分钟)与字符集(无易混字符)。
pub const PAIRING_TTL_MINUTES: i64 = 10;
pub const CODE_CHARS: &[u8] = b"ABCDEFGHJKMNPQRSTUVWXYZ23456789";
/// 离线留言保留期(小时)与单条密文上限。
pub const INBOX_TTL_HOURS: i64 = 24;
pub const MAX_PAYLOAD_BYTES: usize = 32 * 1024;
/// 单用户桌面连接 / 单桌面控制器连接上限。
pub const MAX_DESKTOPS_PER_USER: usize = 4;
pub const MAX_CONTROLLERS_PER_DESKTOP: usize = 4;

fn hash_code(code: &str) -> String {
  let mut hasher = Sha256::new();
  hasher.update(code.as_bytes());
  hex::encode(hasher.finalize())
}

/// 生成 8 位一次性配对码。
pub fn generate_pairing_code() -> String {
  let mut rng = rand::rng();
  (0..8)
    .map(|_| CODE_CHARS[rng.random_range(0..CODE_CHARS.len())] as char)
    .collect()
}

/// 桌面/控制器在线注册表。服务器只持有"谁能收到帧"的信箱,
/// 不解读业务载荷。
#[derive(Default)]
pub struct RemoteRegistry {
  inner: Mutex<RegistryInner>,
}

#[derive(Default)]
struct RegistryInner {
  /// user_id → (desktop_device_id → 发送信箱)
  desktops: HashMap<i64, HashMap<String, mpsc::Sender<Message>>>,
  /// user_id → (desktop_device_id → [控制器发送信箱])
  controllers: HashMap<i64, HashMap<String, Vec<mpsc::Sender<Message>>>>,
}

impl RemoteRegistry {
  pub async fn insert_desktop(
    &self,
    user_id: i64,
    device_id: &str,
    tx: mpsc::Sender<Message>,
  ) -> Result<(), AppError> {
    let mut inner = self.inner.lock().await;
    let desktops = inner.desktops.entry(user_id).or_default();
    if !desktops.contains_key(device_id) && desktops.len() >= MAX_DESKTOPS_PER_USER {
      return Err(AppError::Validation("桌面连接数已达上限".into()));
    }
    desktops.insert(device_id.to_string(), tx);
    Ok(())
  }

  pub async fn remove_desktop(&self, user_id: i64, device_id: &str, tx: &mpsc::Sender<Message>) {
    let mut inner = self.inner.lock().await;
    if let Some(devices) = inner.desktops.get_mut(&user_id) {
      // 只在信箱仍是本连接时移除(重连竞态:新连接已登记,别把新的踢掉)
      if devices
        .get(device_id)
        .is_some_and(|existing| existing.same_channel(tx))
      {
        devices.remove(device_id);
      }
      if devices.is_empty() {
        inner.desktops.remove(&user_id);
      }
    }
  }

  pub async fn insert_controller(
    &self,
    user_id: i64,
    device_id: &str,
    tx: mpsc::Sender<Message>,
  ) -> Result<(), AppError> {
    let mut inner = self.inner.lock().await;
    let controllers = inner.controllers.entry(user_id).or_default();
    let list = controllers.entry(device_id.to_string()).or_default();
    if list.len() >= MAX_CONTROLLERS_PER_DESKTOP {
      return Err(AppError::Validation("控制器连接数已达上限".into()));
    }
    list.push(tx);
    Ok(())
  }

  pub async fn remove_controller(&self, user_id: i64, device_id: &str, tx: &mpsc::Sender<Message>) {
    let mut inner = self.inner.lock().await;
    if let Some(devices) = inner.controllers.get_mut(&user_id) {
      if let Some(list) = devices.get_mut(device_id) {
        list.retain(|existing| !existing.same_channel(tx));
        if list.is_empty() {
          devices.remove(device_id);
        }
      }
      if devices.is_empty() {
        inner.controllers.remove(&user_id);
      }
    }
  }

  /// controller → desktop 转发。返回 false = 桌面不在线。
  pub async fn forward_to_desktop(&self, user_id: i64, device_id: &str, msg: Message) -> bool {
    let inner = self.inner.lock().await;
    let Some(tx) = inner
      .desktops
      .get(&user_id)
      .and_then(|devices| devices.get(device_id))
    else {
      return false;
    };
    tx.send(msg).await.is_ok()
  }

  /// desktop → 全部控制器广播。返回送达数。
  pub async fn broadcast_to_controllers(
    &self,
    user_id: i64,
    device_id: &str,
    msg: Message,
  ) -> usize {
    let inner = self.inner.lock().await;
    let Some(list) = inner
      .controllers
      .get(&user_id)
      .and_then(|devices| devices.get(device_id))
    else {
      return 0;
    };
    let mut delivered = 0;
    for tx in list {
      if tx.send(msg.clone()).await.is_ok() {
        delivered += 1;
      }
    }
    delivered
  }

  pub async fn desktop_online(&self, user_id: i64, device_id: &str) -> bool {
    let inner = self.inner.lock().await;
    inner
      .desktops
      .get(&user_id)
      .is_some_and(|devices| devices.contains_key(device_id))
  }
}

/// 签发配对码(登录态,desktop 端)。过期未认领的码顺带清理。
pub async fn pairing_start(
  state: &AppState,
  user_id: i64,
  desktop_device_id: &str,
  desktop_name: &str,
) -> Result<(String, String), AppError> {
  let expired = Utc::now().naive_utc() - Duration::minutes(PAIRING_TTL_MINUTES);
  sqlx::query(
    "DELETE FROM remote_pairings WHERE user_id = ? AND claimed_at IS NULL AND expires_at < ?",
  )
  .bind(user_id)
  .bind(expired)
  .execute(&state.pool)
  .await?;
  let code = generate_pairing_code();
  let expires_at = Utc::now().naive_utc() + Duration::minutes(PAIRING_TTL_MINUTES);
  sqlx::query(
    "INSERT INTO remote_pairings (user_id, desktop_device_id, desktop_name, code_hash, expires_at) \
     VALUES (?, ?, ?, ?, ?)",
  )
  .bind(user_id)
  .bind(desktop_device_id.trim())
  .bind(desktop_name.trim())
  .bind(hash_code(&code))
  .bind(expires_at)
  .execute(&state.pool)
  .await?;
  Ok((code, expires_at.and_utc().to_rfc3339()))
}

/// 认领配对码(controller 端):必须同账号、未认领、未吊销、未过期。
pub async fn pairing_claim(
  state: &AppState,
  user_id: i64,
  code: &str,
  controller_name: &str,
) -> Result<(String, String), AppError> {
  let trimmed = code.trim().to_uppercase();
  let hash = hash_code(&trimmed);
  let row: Option<(i64, i64, String, String)> = sqlx::query_as(
    "SELECT id, user_id, desktop_device_id, desktop_name FROM remote_pairings \
     WHERE code_hash = ? AND claimed_at IS NULL AND revoked_at IS NULL AND expires_at > ?",
  )
  .bind(&hash)
  .bind(Utc::now().naive_utc())
  .fetch_optional(&state.pool)
  .await?;
  let Some((id, owner, device_id, desktop_name)) = row else {
    return Err(AppError::Validation("配对码无效或已过期".into()));
  };
  if owner != user_id {
    // 码是真实存在的:别告诉非属主"无效",统一口径防枚举
    return Err(AppError::Validation("配对码无效或已过期".into()));
  }
  sqlx::query("UPDATE remote_pairings SET claimed_at = ?, controller_name = ? WHERE id = ?")
    .bind(Utc::now().naive_utc())
    .bind(controller_name.trim())
    .bind(id)
    .execute(&state.pool)
    .await?;
  Ok((device_id, desktop_name))
}

/// 该用户全部在效配对(both 视角:desktop 列表)。
pub async fn list_devices(
  state: &AppState,
  user_id: i64,
  registry: &Arc<RemoteRegistry>,
) -> Result<Vec<serde_json::Value>, AppError> {
  let rows: Vec<(String, String, String, chrono::NaiveDateTime)> = sqlx::query_as(
    "SELECT desktop_device_id, desktop_name, controller_name, created_at FROM remote_pairings \
     WHERE user_id = ? AND claimed_at IS NOT NULL AND revoked_at IS NULL \
     ORDER BY created_at DESC",
  )
  .bind(user_id)
  .fetch_all(&state.pool)
  .await?;
  let mut out = Vec::with_capacity(rows.len());
  for (device_id, desktop_name, controller_name, created) in rows {
    let online = registry.desktop_online(user_id, &device_id).await;
    out.push(json!({
      "desktopDeviceId": device_id,
      "desktopName": desktop_name,
      "controllerName": controller_name,
      "online": online,
      "createdAt": created.and_utc().to_rfc3339(),
    }));
  }
  Ok(out)
}

/// 吊销配对(desktop 端操作;controller_name 缺省 = 全部)。
pub async fn pairing_revoke(
  state: &AppState,
  user_id: i64,
  desktop_device_id: &str,
  controller_name: Option<&str>,
) -> Result<u64, AppError> {
  let result = if let Some(name) = controller_name {
    sqlx::query(
      "UPDATE remote_pairings SET revoked_at = ? \
       WHERE user_id = ? AND desktop_device_id = ? AND controller_name = ? AND revoked_at IS NULL",
    )
    .bind(Utc::now().naive_utc())
    .bind(user_id)
    .bind(desktop_device_id)
    .bind(name)
    .execute(&state.pool)
    .await?
  } else {
    sqlx::query(
      "UPDATE remote_pairings SET revoked_at = ? \
       WHERE user_id = ? AND desktop_device_id = ? AND revoked_at IS NULL",
    )
    .bind(Utc::now().naive_utc())
    .bind(user_id)
    .bind(desktop_device_id)
    .execute(&state.pool)
    .await?
  };
  Ok(result.rows_affected())
}

/// 桌面不在线时投递离线留言(E2E 密文原样入库);顺带清理超期行。
pub async fn inbox_push(
  state: &AppState,
  user_id: i64,
  desktop_device_id: &str,
  payload: &str,
) -> Result<(), AppError> {
  let cutoff = Utc::now().naive_utc() - Duration::hours(INBOX_TTL_HOURS);
  sqlx::query("DELETE FROM remote_inbox WHERE created_at < ?")
    .bind(cutoff)
    .execute(&state.pool)
    .await?;
  sqlx::query("INSERT INTO remote_inbox (user_id, desktop_device_id, payload) VALUES (?, ?, ?)")
    .bind(user_id)
    .bind(desktop_device_id)
    .bind(payload)
    .execute(&state.pool)
    .await?;
  Ok(())
}

/// 桌面连接后取未投递的离线留言。
pub async fn inbox_pending(
  state: &AppState,
  user_id: i64,
  desktop_device_id: &str,
) -> Result<Vec<(i64, String)>, AppError> {
  sqlx::query_as::<_, (i64, String)>(
    "SELECT id, payload FROM remote_inbox \
     WHERE user_id = ? AND desktop_device_id = ? AND delivered_at IS NULL ORDER BY id",
  )
  .bind(user_id)
  .bind(desktop_device_id)
  .fetch_all(&state.pool)
  .await
  .map_err(|e| AppError::Internal(format!("inbox pending: {e}")))
}

/// 桌面轮询取帧：取未投递行并标记 delivered（不删——WS/HTTP 都可能丢，
/// 由 TTL 与 ack 双保险；重复风险由客户端幂等处理承担，v1 取"不重复派活"
/// 优先：delivered_at 置位后不再返回）。
pub async fn inbox_take(
  state: &AppState,
  user_id: i64,
  desktop_device_id: &str,
) -> Result<Vec<(i64, String)>, AppError> {
  let rows: Vec<(i64, String)> = sqlx::query_as::<_, (i64, String)>(
    "SELECT id, payload FROM remote_inbox \
     WHERE user_id = ? AND desktop_device_id = ? AND delivered_at IS NULL ORDER BY id LIMIT 100",
  )
  .bind(user_id)
  .bind(desktop_device_id)
  .fetch_all(&state.pool)
  .await
  .map_err(|e| AppError::Internal(format!("inbox take: {e}")))?;
  if !rows.is_empty() {
    let now = Utc::now().naive_utc();
    for (id, _) in &rows {
      let _ = sqlx::query("UPDATE remote_inbox SET delivered_at = ? WHERE id = ?")
        .bind(now)
        .bind(id)
        .execute(&state.pool)
        .await;
    }
  }
  Ok(rows)
}

/// 桌面确认已处理离线留言。
pub async fn inbox_ack(state: &AppState, ids: &[i64], user_id: i64) -> Result<(), AppError> {
  if ids.is_empty() {
    return Ok(());
  }
  // 逐条删:量小(每设备至多几条),避免动态 IN 拼接
  for id in ids {
    sqlx::query("DELETE FROM remote_inbox WHERE id = ? AND user_id = ?")
      .bind(id)
      .bind(user_id)
      .execute(&state.pool)
      .await?;
  }
  Ok(())
}

#[cfg(test)]
mod tests {
  use super::{CODE_CHARS, generate_pairing_code, hash_code};

  #[test]
  fn code_shape() {
    for _ in 0..50 {
      let code = generate_pairing_code();
      assert_eq!(code.len(), 8);
      assert!(code.chars().all(|c| CODE_CHARS.contains(&(c as u8))));
    }
    assert_ne!(generate_pairing_code(), generate_pairing_code());
  }

  #[test]
  fn hash_deterministic() {
    assert_eq!(hash_code("ABCD2345"), hash_code("ABCD2345"));
    assert_ne!(hash_code("ABCD2345"), hash_code("ABCD2346"));
  }
}
