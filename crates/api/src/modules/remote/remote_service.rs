use chrono::{Duration, Utc};
use rand::Rng;
use sha2::{Digest, Sha256};

use crate::errors::AppError;
use crate::types::AppState;

/// 配对码有效期(分钟)与字符集(无易混字符)。
pub const PAIRING_TTL_MINUTES: i64 = 10;
pub const CODE_CHARS: &[u8] = b"ABCDEFGHJKMNPQRSTUVWXYZ23456789";
/// 离线留言保留期(小时)与单条密文上限。
pub const INBOX_TTL_HOURS: i64 = 24;
pub const MAX_PAYLOAD_BYTES: usize = 32 * 1024;
/// 在线判定窗口(秒):桌面 pull 时服务器盖 last_seen 戳,窗口内 = 在线。
pub const ONLINE_WINDOW_SECS: i64 = 15;
/// 单用户桌面配对数上限。
pub const MAX_DESKTOPS_PER_USER: usize = 4;

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

/// 信箱归属。传输拓扑(可水平扩展,连接无状态):
/// - 发送一律 `POST /remote/push`:INSERT remote_inbox(持久,离线 24h 可达)
///   → Redis PUBLISH express 信封(尽力而为,任意实例可投)。
/// - 接收 = WS 频道订阅(即时) + `GET /remote/pull`(兜底,1s),按行 id 去重。
/// - WS 只做"订阅自己频道的下行管道 + 心跳",不承载业务帧。
/// - Controller 与 ControllerSnap 是控制器的两条 lane:replace 只清同 lane,
///   否则快照的 replace 会把先落地的 sessions 回包从信箱里删掉
///   (远程"新建会话"列表永远刷不出来的根因)。
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Mailbox {
  /// 收件方 = 桌面(手机发的指令/留言)
  Desktop,
  /// 收件方 = 控制器,回包 lane(sessions 列表/错误回执;共享信箱)
  Controller,
  /// 收件方 = 控制器,快照 lane(只有最新有意义,replace 清旧)
  ControllerSnap,
}

impl Mailbox {
  pub fn as_str(&self) -> &'static str {
    match self {
      Mailbox::Desktop => "desktop",
      Mailbox::Controller => "controller",
      // varchar(16) 上限;"controller_snap" 15 字符
      Mailbox::ControllerSnap => "controller_snap",
    }
  }

  pub fn from_str(s: &str) -> Option<Mailbox> {
    match s {
      "desktop" => Some(Mailbox::Desktop),
      "controller" => Some(Mailbox::Controller),
      _ => None,
    }
  }

  /// 发送方角色 + 可选 lane → 收件信箱。lane=snapshot 仅桌面发快照时用。
  pub fn for_sender(sender_role: &str, lane: &str) -> Option<Mailbox> {
    match (sender_role, lane) {
      ("desktop", "snapshot") => Some(Mailbox::ControllerSnap),
      ("desktop", "") => Some(Mailbox::Controller),
      ("controller", "") => Some(Mailbox::Desktop),
      _ => None,
    }
  }

  /// pull 时该收件角色的全部 lane(controller 角色取两条)。
  pub fn pull_lanes(receiver_role: &str) -> Option<Vec<Mailbox>> {
    match receiver_role {
      "desktop" => Some(vec![Mailbox::Desktop]),
      "controller" => Some(vec![Mailbox::Controller, Mailbox::ControllerSnap]),
      _ => None,
    }
  }

  /// WS 订阅/发布频道(照 Trove im_ws:每连接一条 PubSub,任意实例投递皆可达)。
  /// 同一收件方的两条 lane 共用一个频道。
  pub fn channel_of(receiver: Mailbox, user_id: i64, desktop_device_id: &str) -> String {
    let role = match receiver {
      Mailbox::Desktop => "desktop",
      Mailbox::Controller | Mailbox::ControllerSnap => "controller",
    };
    format!("remote:{role}:{user_id}:{desktop_device_id}")
  }

  /// 本信箱的下行发布频道。
  pub fn channel(&self, user_id: i64, desktop_device_id: &str) -> String {
    Mailbox::channel_of(
      match self {
        Mailbox::Desktop => Mailbox::Desktop,
        Mailbox::Controller | Mailbox::ControllerSnap => Mailbox::Controller,
      },
      user_id,
      desktop_device_id,
    )
  }
}

/// 配对码校验:desktop 设备在该用户名下存在在效配对(claimed 未 revoked)。
pub async fn pairing_exists(state: &AppState, user_id: i64, desktop_device_id: &str) -> bool {
  sqlx::query_scalar::<_, i64>(
    "SELECT COUNT(*) FROM remote_pairings \
     WHERE user_id = ? AND desktop_device_id = ? AND claimed_at IS NOT NULL AND revoked_at IS NULL",
  )
  .bind(user_id)
  .bind(desktop_device_id)
  .fetch_one(&state.pool)
  .await
  .unwrap_or(0)
    > 0
}

/// 在线判定:桌面 last_seen 戳在窗口内(跨实例,基于 DB,不依赖进程内注册表)。
pub async fn desktop_online(state: &AppState, user_id: i64, desktop_device_id: &str) -> bool {
  let seen: Option<chrono::NaiveDateTime> = sqlx::query_scalar(
    "SELECT desktop_last_seen_at FROM remote_pairings \
     WHERE user_id = ? AND desktop_device_id = ? AND claimed_at IS NOT NULL AND revoked_at IS NULL \
     ORDER BY id DESC LIMIT 1",
  )
  .bind(user_id)
  .bind(desktop_device_id)
  .fetch_optional(&state.pool)
  .await
  .ok()
  .flatten();
  match seen {
    Some(seen) => Utc::now().naive_utc() - seen < Duration::seconds(ONLINE_WINDOW_SECS),
    None => false,
  }
}

/// 桌面 pull 时盖章(在线判定的依据)。
async fn touch_desktop(state: &AppState, user_id: i64, desktop_device_id: &str) {
  let _ = sqlx::query(
    "UPDATE remote_pairings SET desktop_last_seen_at = ? \
     WHERE user_id = ? AND desktop_device_id = ? AND claimed_at IS NOT NULL AND revoked_at IS NULL",
  )
  .bind(Utc::now().naive_utc())
  .bind(user_id)
  .bind(desktop_device_id)
  .execute(&state.pool)
  .await;
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
  // 桌面配对数上限(吊销的不占额)
  let active: i64 = sqlx::query_scalar(
    "SELECT COUNT(DISTINCT desktop_device_id) FROM remote_pairings \
     WHERE user_id = ? AND claimed_at IS NOT NULL AND revoked_at IS NULL",
  )
  .bind(user_id)
  .fetch_one(&state.pool)
  .await?;
  let is_new_desktop = !pairing_exists(state, user_id, desktop_device_id).await;
  if is_new_desktop && active >= MAX_DESKTOPS_PER_USER as i64 {
    return Err(AppError::Validation("桌面配对数已达上限".into()));
  }
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
/// 成功后向桌面频道发布控制通知(明文、无业务数据),桌面端据此收起二维码。
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
  // 同一台手机重新配对：吊销同 (user, desktop_device_id, controller_name)
  // 的旧在效配对——重装 App / 重扫不会在桌面设备列表里堆积垃圾行。
  // 各手机的会话密钥互不相同，旧行吊销后旧手机自然失联。
  sqlx::query(
    "UPDATE remote_pairings SET revoked_at = ? \
     WHERE user_id = ? AND desktop_device_id = ? AND controller_name = ? \
       AND id != ? AND revoked_at IS NULL",
  )
  .bind(Utc::now().naive_utc())
  .bind(user_id)
  .bind(&device_id)
  .bind(controller_name.trim())
  .bind(id)
  .execute(&state.pool)
  .await?;
  publish_notify(state, user_id, &device_id, "pairing_claimed").await;
  Ok((device_id, desktop_name))
}

/// 该用户全部在效配对(both 视角:desktop 列表)。
pub async fn list_devices(
  state: &AppState,
  user_id: i64,
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
    let online = desktop_online(state, user_id, &device_id).await;
    out.push(serde_json::json!({
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

/// 入站帧:入库(持久) + express 发布(尽力而为)。返回行 id。
pub async fn inbox_push(
  state: &AppState,
  user_id: i64,
  desktop_device_id: &str,
  mailbox: Mailbox,
  payload: &str,
  replace: bool,
) -> Result<i64, AppError> {
  let cutoff = Utc::now().naive_utc() - Duration::hours(INBOX_TTL_HOURS);
  sqlx::query("DELETE FROM remote_inbox WHERE created_at < ?")
    .bind(cutoff)
    .execute(&state.pool)
    .await?;
  // replace:新帧使同信箱的 pending 旧帧作废(快照语义:只有最新有意义,
  // 手机离线堆积有界)
  if replace {
    sqlx::query(
      "DELETE FROM remote_inbox \
       WHERE user_id = ? AND desktop_device_id = ? AND recipient = ? AND delivered_at IS NULL",
    )
    .bind(user_id)
    .bind(desktop_device_id)
    .bind(mailbox.as_str())
    .execute(&state.pool)
    .await?;
  }
  let result = sqlx::query(
    "INSERT INTO remote_inbox (user_id, desktop_device_id, recipient, payload) VALUES (?, ?, ?, ?)",
  )
  .bind(user_id)
  .bind(desktop_device_id)
  .bind(mailbox.as_str())
  .bind(payload)
  .execute(&state.pool)
  .await?;
  let id = i64::try_from(result.last_insert_id()).unwrap_or_default();
  // express:与实例无关,收件方的 WS 连接(挂在任意实例上)各自消费本频道。
  // Redis 未配置/发布失败静默——兜底是 pull(1s)。
  publish_express(state, user_id, desktop_device_id, mailbox, id, payload).await;
  Ok(id)
}

/// 取走信箱帧:SELECT + DELETE 同事务(delivered_at 弃用,取走即删;
/// 语义 = 取后不重投,"不重复派活"优先)。桌面 pull 顺带盖在线戳。
/// controller 角色一次取全部 lane(回包 + 快照,按 id 排序)。
pub async fn inbox_take(
  state: &AppState,
  user_id: i64,
  desktop_device_id: &str,
  lanes: &[Mailbox],
) -> Result<Vec<(i64, String)>, AppError> {
  assert!(!lanes.is_empty(), "pull_lanes 不返回空");
  if lanes.contains(&Mailbox::Desktop) {
    touch_desktop(state, user_id, desktop_device_id).await;
  }
  let first = lanes[0].as_str();
  let second = lanes.get(1).map(Mailbox::as_str).unwrap_or(first);
  let mut tx = state
    .pool
    .begin()
    .await
    .map_err(|e| AppError::Internal(format!("inbox take: {e}")))?;
  let rows: Vec<(i64, String)> = sqlx::query_as(
    "SELECT id, payload FROM remote_inbox \
     WHERE user_id = ? AND desktop_device_id = ? AND delivered_at IS NULL \
       AND (recipient = ? OR recipient = ?) \
     ORDER BY id LIMIT 100",
  )
  .bind(user_id)
  .bind(desktop_device_id)
  .bind(first)
  .bind(second)
  .fetch_all(&mut *tx)
  .await
  .map_err(|e| AppError::Internal(format!("inbox take: {e}")))?;
  for (id, _) in &rows {
    sqlx::query("DELETE FROM remote_inbox WHERE id = ?")
      .bind(id)
      .execute(&mut *tx)
      .await
      .map_err(|e| AppError::Internal(format!("inbox take: {e}")))?;
  }
  tx.commit()
    .await
    .map_err(|e| AppError::Internal(format!("inbox take: {e}")))?;
  Ok(rows)
}

/// express 信封 `{"id":..,"payload":".."}`(与 pull items 同形,客户端单一处理路径)。
async fn publish_express(
  state: &AppState,
  user_id: i64,
  desktop_device_id: &str,
  mailbox: Mailbox,
  id: i64,
  payload: &str,
) {
  let Some(conn) = &state.redis else { return };
  let envelope = serde_json::json!({"id": id, "payload": payload});
  let channel = mailbox.channel(user_id, desktop_device_id);
  let _: Result<(), _> =
    redis::AsyncCommands::publish(&mut conn.clone(), channel, envelope.to_string())
      .await
      .inspect_err(|e| tracing::warn!("remote express publish: {e}"));
}

/// 控制通知(明文,无业务数据):配对认领等服务器侧事件。
pub async fn publish_notify(state: &AppState, user_id: i64, desktop_device_id: &str, event: &str) {
  let Some(conn) = &state.redis else { return };
  let envelope = serde_json::json!({"kind": "notify", "event": event});
  let channel = Mailbox::Desktop.channel(user_id, desktop_device_id);
  let _: Result<(), _> =
    redis::AsyncCommands::publish(&mut conn.clone(), channel, envelope.to_string())
      .await
      .inspect_err(|e| tracing::warn!("remote notify publish: {e}"));
}

#[cfg(test)]
mod tests {
  use super::{CODE_CHARS, Mailbox, generate_pairing_code, hash_code};

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

  #[test]
  fn mailbox_routing() {
    // 桌面发 → 控制器信箱;手机发 → 桌面信箱;快照 lane 独立
    assert_eq!(Mailbox::for_sender("desktop", ""), Some(Mailbox::Controller));
    assert_eq!(
      Mailbox::for_sender("desktop", "snapshot"),
      Some(Mailbox::ControllerSnap)
    );
    assert_eq!(Mailbox::for_sender("controller", ""), Some(Mailbox::Desktop));
    assert_eq!(Mailbox::for_sender("bogus", ""), None);
    assert_eq!(Mailbox::for_sender("controller", "snapshot"), None);
    // 控制器两条 lane 共用一个下行频道
    assert_eq!(
      Mailbox::Controller.channel(7, "DEV"),
      Mailbox::ControllerSnap.channel(7, "DEV")
    );
    // pull:控制器取两条 lane,桌面取一条
    assert_eq!(
      Mailbox::pull_lanes("controller"),
      Some(vec![Mailbox::Controller, Mailbox::ControllerSnap])
    );
    assert_eq!(Mailbox::pull_lanes("desktop"), Some(vec![Mailbox::Desktop]));
  }
}
