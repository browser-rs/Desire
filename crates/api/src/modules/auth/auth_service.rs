use axum::http::HeaderMap;
use chrono::Utc;

use crate::errors::AppError;
use crate::types::AppState;
use crate::utils::jwt;
use crate::utils::refresh_token;

use super::auth_model::{
  DeviceDto, DeviceInfoReq, DeviceRow, LoginReq, MeDto, RefreshTokenRow, RegisterReq,
  SetPasswordReq, TokenPair, UpdateProfileReq, UserRow,
};

/// 用户名:字母开头,3-32 位字母/数字/下划线
pub fn is_valid_username(username: &str) -> bool {
  let bytes = username.as_bytes();
  if !(3..=32).contains(&bytes.len()) {
    return false;
  }
  bytes[0].is_ascii_alphabetic()
    && bytes[1..]
      .iter()
      .all(|b| b.is_ascii_alphanumeric() || *b == b'_')
}

/// 密码 6-72 字节(72 是 bcrypt 的硬上限)
fn validate_password(password: &str) -> Result<(), AppError> {
  if !(6..=72).contains(&password.len()) {
    return Err(AppError::Validation("密码长度须为 6-72 字节".into()));
  }
  Ok(())
}

fn trim_or_empty(s: &Option<String>) -> &str {
  s.as_deref().map(str::trim).unwrap_or("")
}

fn ua(headers: &HeaderMap) -> String {
  headers
    .get(axum::http::header::USER_AGENT)
    .and_then(|v| v.to_str().ok())
    .unwrap_or("")
    .chars()
    .take(255)
    .collect()
}

fn ip(headers: &HeaderMap) -> String {
  headers
    .get("x-forwarded-for")
    .and_then(|v| v.to_str().ok())
    .unwrap_or("")
    .chars()
    .take(45)
    .collect()
}

/// 登录/注册时登记设备:同一 (user, device_id) 视为同一台设备,
/// 重复登录 = 显式行为,撤销态一并清掉。返回 devices.id 供 refresh token 绑定。
async fn upsert_device(
  pool: &sqlx::MySqlPool,
  user_id: i64,
  device: &DeviceInfoReq,
  headers: &HeaderMap,
) -> Result<i64, AppError> {
  let device_id = device.device_id.trim();
  if device_id.is_empty() || device_id.len() > 64 {
    return Err(AppError::Validation(
      "device.device_id is required (1-64 chars)".into(),
    ));
  }
  let name = trim_or_empty(&device.name);
  let platform = trim_or_empty(&device.platform);
  let res = sqlx::query(
    "INSERT INTO devices (user_id, device_id, name, platform, user_agent, ip) \
     VALUES (?, ?, ?, ?, ?, ?) AS new \
     ON DUPLICATE KEY UPDATE id = LAST_INSERT_ID(id), name = new.name, \
     platform = new.platform, user_agent = new.user_agent, ip = new.ip, revoked_at = NULL",
  )
  .bind(user_id)
  .bind(device_id)
  .bind(name)
  .bind(platform)
  .bind(ua(headers))
  .bind(ip(headers))
  .execute(pool)
  .await?;
  Ok(res.last_insert_id() as i64)
}

async fn issue_tokens(
  state: &AppState,
  user_id: i64,
  device: Option<&DeviceInfoReq>,
  headers: &HeaderMap,
) -> Result<TokenPair, AppError> {
  let device_row_id = match device {
    Some(d) => Some(upsert_device(&state.pool, user_id, d, headers).await?),
    None => None,
  };
  let access_token = jwt::create_token(
    user_id,
    state.config.access_token_ttl,
    &state.config.jwt_secret,
  )?;
  let raw_refresh = refresh_token::generate();
  let token_hash = refresh_token::hash_token(&raw_refresh);
  let expires_at = Utc::now() + state.config.refresh_token_ttl;
  sqlx::query(
    "INSERT INTO user_refresh_tokens (user_id, device_id, token_hash, expires_at, user_agent, ip) \
     VALUES (?, ?, ?, ?, ?, ?)",
  )
  .bind(user_id)
  .bind(device_row_id)
  .bind(&token_hash)
  .bind(expires_at.naive_utc())
  .bind(ua(headers))
  .bind(ip(headers))
  .execute(&state.pool)
  .await?;
  Ok(TokenPair {
    access_token,
    refresh_token: raw_refresh,
    expires_in: state.config.access_token_ttl.num_seconds(),
  })
}

pub async fn register(
  state: &AppState,
  headers: &HeaderMap,
  req: RegisterReq,
) -> Result<TokenPair, AppError> {
  let username = req.username.trim();
  if !is_valid_username(username) {
    return Err(AppError::Validation(
      "用户名须为字母开头,3-32 位字母/数字/下划线".into(),
    ));
  }
  validate_password(&req.password)?;
  let exists: Option<i64> = sqlx::query_scalar("SELECT id FROM users WHERE username = ?")
    .bind(username)
    .fetch_optional(&state.pool)
    .await?;
  if exists.is_some() {
    return Err(AppError::Conflict("username already registered".into()));
  }
  let nickname = {
    let n = trim_or_empty(&req.nickname);
    if n.is_empty() {
      username.to_string()
    } else {
      n.to_string()
    }
  };
  // 并发重复注册时撞 UNIQUE(username),经 AppError::from 统一映射 409
  let hash = bcrypt::hash(&req.password, 10)
    .map_err(|e| AppError::Internal(format!("password hash failed: {e}")))?;
  let res = sqlx::query("INSERT INTO users (username, nickname, password_hash) VALUES (?, ?, ?)")
    .bind(username)
    .bind(nickname)
    .bind(&hash)
    .execute(&state.pool)
    .await?;
  let user_id = res.last_insert_id() as i64;
  sqlx::query("UPDATE users SET last_login_at = ? WHERE id = ?")
    .bind(Utc::now().naive_utc())
    .bind(user_id)
    .execute(&state.pool)
    .await?;
  issue_tokens(state, user_id, req.device.as_ref(), headers).await
}

/// 密码登录:账号不存在或密码错误统一 401(防枚举),不区分"没注册"。
pub async fn login(
  state: &AppState,
  headers: &HeaderMap,
  req: LoginReq,
) -> Result<TokenPair, AppError> {
  let username = req.username.trim();
  if username.is_empty() || req.password.is_empty() {
    return Err(AppError::Unauthorized("账号或密码错误".into()));
  }
  let row: Option<(i64, String)> =
    sqlx::query_as("SELECT id, password_hash FROM users WHERE username = ?")
      .bind(username)
      .fetch_optional(&state.pool)
      .await?;
  let Some((user_id, hash)) = row else {
    return Err(AppError::Unauthorized("账号或密码错误".into()));
  };
  let ok = bcrypt::verify(&req.password, &hash).unwrap_or(false);
  if !ok {
    return Err(AppError::Unauthorized("账号或密码错误".into()));
  }
  sqlx::query("UPDATE users SET last_login_at = ? WHERE id = ?")
    .bind(Utc::now().naive_utc())
    .bind(user_id)
    .execute(&state.pool)
    .await?;
  issue_tokens(state, user_id, req.device.as_ref(), headers).await
}

pub async fn refresh(
  state: &AppState,
  headers: &HeaderMap,
  token: &str,
) -> Result<TokenPair, AppError> {
  let token_hash = refresh_token::hash_token(token);
  let now = Utc::now().naive_utc();
  // FOR UPDATE 必须在事务内:自动提交下锁立即释放,同一 token 可并发重放轮换
  let mut tx = state.pool.begin().await?;
  let row = sqlx::query_as::<_, RefreshTokenRow>(
    "SELECT id, user_id, device_id, expires_at, revoked_at \
     FROM user_refresh_tokens WHERE token_hash = ? FOR UPDATE",
  )
  .bind(&token_hash)
  .fetch_optional(&mut *tx)
  .await?
  .ok_or_else(|| AppError::Unauthorized("invalid refresh token".into()))?;
  if row.revoked_at.is_some() {
    return Err(AppError::Unauthorized("refresh token revoked".into()));
  }
  if row.expires_at < now {
    return Err(AppError::Unauthorized("refresh token expired".into()));
  }
  let status: i8 = sqlx::query_scalar("SELECT status FROM users WHERE id = ?")
    .bind(row.user_id)
    .fetch_optional(&mut *tx)
    .await?
    .ok_or_else(|| AppError::Unauthorized("user no longer exists".into()))?;
  if status == 0 {
    return Err(AppError::Forbidden("account disabled".into()));
  }
  sqlx::query("UPDATE user_refresh_tokens SET revoked_at = ? WHERE id = ?")
    .bind(now)
    .bind(row.id)
    .execute(&mut *tx)
    .await?;
  // 设备活跃度:每次轮换顺手推进 last_seen(无 device 绑定的老 token 跳过)
  if let Some(device_row_id) = row.device_id {
    sqlx::query("UPDATE devices SET last_seen_at = ? WHERE id = ?")
      .bind(now)
      .bind(device_row_id)
      .execute(&mut *tx)
      .await?;
  }
  let new_access = jwt::create_token(
    row.user_id,
    state.config.access_token_ttl,
    &state.config.jwt_secret,
  )?;
  let new_raw = refresh_token::generate();
  let new_hash = refresh_token::hash_token(&new_raw);
  let new_expires = Utc::now() + state.config.refresh_token_ttl;
  sqlx::query(
    "INSERT INTO user_refresh_tokens (user_id, device_id, token_hash, expires_at, user_agent, ip) \
     VALUES (?, ?, ?, ?, ?, ?)",
  )
  .bind(row.user_id)
  .bind(row.device_id)
  .bind(&new_hash)
  .bind(new_expires.naive_utc())
  .bind(ua(headers))
  .bind(ip(headers))
  .execute(&mut *tx)
  .await?;
  tx.commit().await?;
  Ok(TokenPair {
    access_token: new_access,
    refresh_token: new_raw,
    expires_in: state.config.access_token_ttl.num_seconds(),
  })
}

pub async fn logout(state: &AppState, token: &str) -> Result<(), AppError> {
  let token_hash = refresh_token::hash_token(token);
  let now = Utc::now().naive_utc();
  let res = sqlx::query(
    "UPDATE user_refresh_tokens SET revoked_at = ? WHERE token_hash = ? AND revoked_at IS NULL",
  )
  .bind(now)
  .bind(&token_hash)
  .execute(&state.pool)
  .await?;
  if res.rows_affected() == 0 {
    return Err(AppError::Unauthorized("invalid refresh token".into()));
  }
  Ok(())
}

pub async fn me(state: &AppState, user_id: i64) -> Result<MeDto, AppError> {
  let row = sqlx::query_as::<_, UserRow>(
    "SELECT id, username, nickname, email, status FROM users WHERE id = ?",
  )
  .bind(user_id)
  .fetch_optional(&state.pool)
  .await?
  .ok_or_else(|| AppError::NotFound("user not found".into()))?;
  Ok(MeDto {
    id: row.id,
    username: row.username,
    nickname: row.nickname,
    email: row.email.unwrap_or_default(),
  })
}

pub async fn update_profile(
  state: &AppState,
  user_id: i64,
  req: UpdateProfileReq,
) -> Result<MeDto, AppError> {
  if let Some(nickname) = &req.nickname {
    let nickname = nickname.trim();
    if nickname.is_empty() || nickname.chars().count() > 64 {
      return Err(AppError::Validation("nickname 须为 1-64 字符".into()));
    }
    sqlx::query("UPDATE users SET nickname = ? WHERE id = ?")
      .bind(nickname)
      .bind(user_id)
      .execute(&state.pool)
      .await?;
  }
  if let Some(email) = &req.email {
    let email = email.trim();
    if email.is_empty() {
      // 空串 = 清除绑定
      sqlx::query("UPDATE users SET email = NULL WHERE id = ?")
        .bind(user_id)
        .execute(&state.pool)
        .await?;
    } else {
      if !email.contains('@') || email.len() > 254 {
        return Err(AppError::Validation("invalid email".into()));
      }
      // 撞 UNIQUE(email) 时经 AppError::from 映射 409
      sqlx::query("UPDATE users SET email = ? WHERE id = ?")
        .bind(email)
        .bind(user_id)
        .execute(&state.pool)
        .await?;
    }
  }
  me(state, user_id).await
}

/// 修改密码: Desire 的账号注册即有密码,old_password 恒必填且须匹配。
pub async fn set_password(
  state: &AppState,
  user_id: i64,
  req: SetPasswordReq,
) -> Result<(), AppError> {
  validate_password(&req.new_password)?;
  let current: Option<String> = sqlx::query_scalar("SELECT password_hash FROM users WHERE id = ?")
    .bind(user_id)
    .fetch_optional(&state.pool)
    .await?
    .flatten();
  let Some(hash) = current else {
    return Err(AppError::NotFound("user not found".into()));
  };
  let ok = bcrypt::verify(&req.old_password, &hash).unwrap_or(false);
  if !ok {
    return Err(AppError::Unauthorized("原密码错误".into()));
  }
  let new_hash = bcrypt::hash(req.new_password.trim(), 10)
    .map_err(|e| AppError::Internal(format!("password hash failed: {e}")))?;
  sqlx::query("UPDATE users SET password_hash = ? WHERE id = ?")
    .bind(new_hash)
    .bind(user_id)
    .execute(&state.pool)
    .await?;
  Ok(())
}

pub async fn list_devices(state: &AppState, user_id: i64) -> Result<Vec<DeviceDto>, AppError> {
  let rows = sqlx::query_as::<_, DeviceRow>(
    "SELECT id, device_id, name, platform, revoked_at, last_seen_at, created_at \
     FROM devices WHERE user_id = ? ORDER BY id",
  )
  .bind(user_id)
  .fetch_all(&state.pool)
  .await?;
  Ok(rows.into_iter().map(DeviceDto::from).collect())
}

/// 吊销设备:设备行标记 revoked_at,该设备名下所有未过期的 refresh token
/// 一并吊销;已签发的 access token 等 ≤2h 自然过期(与封禁用户同一策略)。
/// 幂等:重复吊销返回 ok。
pub async fn revoke_device(
  state: &AppState,
  user_id: i64,
  device_id: &str,
) -> Result<(), AppError> {
  let row: Option<i64> =
    sqlx::query_scalar("SELECT id FROM devices WHERE user_id = ? AND device_id = ?")
      .bind(user_id)
      .bind(device_id)
      .fetch_optional(&state.pool)
      .await?;
  let Some(id) = row else {
    return Err(AppError::NotFound("device not found".into()));
  };
  let now = Utc::now().naive_utc();
  sqlx::query("UPDATE devices SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL")
    .bind(now)
    .bind(id)
    .execute(&state.pool)
    .await?;
  sqlx::query(
    "UPDATE user_refresh_tokens SET revoked_at = ? WHERE device_id = ? AND revoked_at IS NULL",
  )
  .bind(now)
  .bind(id)
  .execute(&state.pool)
  .await?;
  Ok(())
}

#[cfg(test)]
mod tests {
  use super::{is_valid_username, validate_password};
  use crate::errors::AppError;

  #[test]
  fn username_rules() {
    assert!(is_valid_username("abc"));
    assert!(is_valid_username("aBc_123"));
    assert!(is_valid_username("a".repeat(32).as_str())); // 32 = 上限
    assert!(!is_valid_username("ab")); // 太短
    assert!(!is_valid_username("1abc")); // 数字开头
    assert!(!is_valid_username("_abc")); // 下划线开头
    assert!(!is_valid_username("a".repeat(33).as_str())); // 33 = 超限
    assert!(!is_valid_username("ab c")); // 空格
    assert!(!is_valid_username("")); // 空
  }

  #[test]
  fn password_rules() {
    assert!(validate_password("123456").is_ok());
    assert!(validate_password("a".repeat(72).as_str()).is_ok());
    assert!(matches!(
      validate_password("12345"),
      Err(AppError::Validation(_))
    ));
    assert!(matches!(
      validate_password("a".repeat(73).as_str()),
      Err(AppError::Validation(_))
    ));
  }
}
