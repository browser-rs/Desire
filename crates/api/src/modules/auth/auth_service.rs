use axum::http::HeaderMap;
use base64::Engine as _;
use chrono::{NaiveDateTime, Utc};
use std::time::Duration;
use uuid::Uuid;

use crate::errors::AppError;
use crate::types::AppState;
use crate::utils::jwt;
use crate::utils::refresh_token;

use super::auth_model::{
  CaptchaResp, DeviceDto, DeviceInfoReq, DeviceRow, KeyEscrowResp, LoginReq, MeDto,
  RefreshTokenRow, RegisterReq, SetPasswordReq, TokenPair, UpdateProfileReq, UserRow,
};

/// 注册验证码有效期(分钟)
const CAPTCHA_TTL_MINUTES: i64 = 5;

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
/// 密码策略:8-72 字节(bcrypt 上限),且须同时包含字母与数字(防纯数字/纯字母弱口令)。
/// 注册与修改密码共用;已有账号的旧弱口令仍可登录(登录不校验复杂度)。
fn validate_password(password: &str) -> Result<(), AppError> {
  if !(8..=72).contains(&password.len()) {
    return Err(AppError::Validation(
      "密码须为 8-72 位,且同时包含字母和数字".into(),
    ));
  }
  let has_letter = password.bytes().any(|b| b.is_ascii_alphabetic());
  let has_digit = password.bytes().any(|b| b.is_ascii_digit());
  if !has_letter || !has_digit {
    return Err(AppError::Validation("密码须同时包含字母和数字".into()));
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

// MARK: - E2E 密钥托管

/// 指纹 64 位 hex / 盐 base64 ≤64 / 包裹体 ≤4KB 的轻量校验。
fn validate_escrow(kdf_salt: &str, wrapped_dek: &str, key_check: &str) -> Result<(), AppError> {
  let salt_ok = !kdf_salt.is_empty() && kdf_salt.len() <= 64;
  let dek_ok = !wrapped_dek.is_empty() && wrapped_dek.len() <= 4096;
  let check_ok = key_check.len() == 64 && key_check.bytes().all(|b| b.is_ascii_hexdigit());
  if salt_ok && dek_ok && check_ok {
    Ok(())
  } else {
    Err(AppError::Validation("key escrow 字段非法".into()))
  }
}

pub async fn key_escrow_get(state: &AppState, user_id: i64) -> Result<KeyEscrowResp, AppError> {
  let row: Option<(Option<String>, Option<String>, Option<String>)> =
    sqlx::query_as("SELECT kdf_salt, wrapped_dek, sync_key_check FROM users WHERE id = ?")
      .bind(user_id)
      .fetch_optional(&state.pool)
      .await?;
  let Some((salt, wrapped, check)) = row else {
    return Err(AppError::NotFound("user not found".into()));
  };
  Ok(KeyEscrowResp {
    kdf_salt: salt.filter(|s| !s.is_empty()),
    wrapped_dek: wrapped.filter(|s| !s.is_empty()),
    key_check: check.filter(|c| !c.is_empty()),
  })
}

/// 上报托管:无已有指纹 → 首次登记;一致 → 幂等;不一致 → 409(防拿错密钥覆盖)。
pub async fn key_escrow_set(
  state: &AppState,
  user_id: i64,
  kdf_salt: &str,
  wrapped_dek: &str,
  key_check: &str,
) -> Result<(), AppError> {
  validate_escrow(kdf_salt, wrapped_dek, key_check)?;
  let existing: Option<Option<String>> =
    sqlx::query_scalar("SELECT sync_key_check FROM users WHERE id = ?")
      .bind(user_id)
      .fetch_optional(&state.pool)
      .await?;
  let Some(existing) = existing else {
    return Err(AppError::NotFound("user not found".into()));
  };
  match existing.as_deref().filter(|c| !c.is_empty()) {
    None => {}
    Some(c) if c == key_check => {}
    Some(_) => {
      return Err(AppError::Conflict(
        "sync key does not match existing data".into(),
      ));
    }
  }
  sqlx::query("UPDATE users SET kdf_salt = ?, wrapped_dek = ?, sync_key_check = ? WHERE id = ?")
    .bind(kdf_salt)
    .bind(wrapped_dek)
    .bind(key_check)
    .bind(user_id)
    .execute(&state.pool)
    .await?;
  Ok(())
}

/// 纯同步渲染:4 位字符码 + PNG 字节。Captcha 内嵌的 ThreadRng/图片缓冲
/// 都是 !Send,必须在此函数内销毁,不能跨 await 存活。
fn render_captcha() -> Result<(String, Vec<u8>), AppError> {
  const POOL: &[char] = &[
    '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F', 'H', 'J', 'K', 'L', 'M',
    'N', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z',
  ];
  let mut cap = captcha::Captcha::new();
  cap.set_chars(POOL);
  cap.add_chars(4);
  cap.view(140, 44);
  cap.apply_filter(captcha::filters::Noise::new(0.1));
  cap.apply_filter(captcha::filters::Wave::new(2.0, 3.0));
  cap
    .as_tuple()
    .map(|(code, png)| (code.to_uppercase(), png))
    .ok_or_else(|| AppError::Internal("captcha render failed".into()))
}

pub async fn new_captcha(state: &AppState, headers: &HeaderMap) -> Result<CaptchaResp, AppError> {
  if !state.rate_limiter.allow(
    &format!("captcha:ip:{}", ip(headers)),
    30,
    Duration::from_secs(60),
  ) {
    return Err(AppError::RateLimited("请求过于频繁，请稍后再试".into()));
  }
  let (code, png) = render_captcha()?;
  let id = Uuid::new_v4().simple().to_string();
  let now = Utc::now().naive_utc();
  let expires = now + chrono::Duration::minutes(CAPTCHA_TTL_MINUTES);
  sqlx::query("DELETE FROM registration_captchas WHERE expires_at < ?")
    .bind(now)
    .execute(&state.pool)
    .await?;
  sqlx::query("INSERT INTO registration_captchas (id, code, expires_at) VALUES (?, ?, ?)")
    .bind(&id)
    .bind(&code)
    .bind(expires)
    .execute(&state.pool)
    .await?;
  Ok(CaptchaResp {
    captcha_id: id,
    image: base64::engine::general_purpose::STANDARD.encode(&png),
    code: (state.config.env == crate::configs::Env::Dev).then_some(code),
  })
}

/// 注册验证码校验:一次性原子消费(id + code + 未用 + 未过期 全匹配才置 used)。
/// 失败不消耗验证码(用户可重试),但客户端失败后应主动刷新。
async fn verify_captcha(
  state: &AppState,
  captcha_id: &str,
  captcha_code: &str,
  now: NaiveDateTime,
) -> Result<(), AppError> {
  let result =
    sqlx::query("UPDATE registration_captchas SET used = 1 WHERE id = ? AND code = ? AND used = 0 AND expires_at > ?")
      .bind(captcha_id)
      .bind(captcha_code.trim())
      .bind(now)
      .execute(&state.pool)
      .await?;
  if result.rows_affected() == 0 {
    return Err(AppError::Unauthorized(
      "验证码错误或已过期，请刷新后重试".into(),
    ));
  }
  Ok(())
}

pub async fn register(
  state: &AppState,
  headers: &HeaderMap,
  req: RegisterReq,
) -> Result<TokenPair, AppError> {
  // 注册开关:env 显式设置优先,否则读 server_settings(缺省开放;desire-admin 可切)
  let allowed = match std::env::var("DESIRE_API_ALLOW_REGISTRATION")
    .ok()
    .as_deref()
    .map(str::to_lowercase)
    .as_deref()
  {
    Some("1") | Some("true") | Some("yes") => true,
    Some(_) => false,
    None => {
      let value: Option<String> = sqlx::query_scalar(
        "SELECT `value` FROM server_settings WHERE `key` = 'allow_registration'",
      )
      .fetch_optional(&state.pool)
      .await?
      .flatten();
      match value {
        Some(v) => v != "0",
        None => true,
      }
    }
  };
  if !allowed {
    return Err(AppError::Forbidden(
      "registration is disabled on this server".into(),
    ));
  }
  // 按来源 IP 限流(防注册滥用);经反代时依赖 x-forwarded-for
  if !state.rate_limiter.allow(
    &format!("register:ip:{}", ip(headers)),
    10,
    Duration::from_secs(3600),
  ) {
    return Err(AppError::RateLimited("注册过于频繁，请稍后再试".into()));
  }
  let username = req.username.trim();
  if !is_valid_username(username) {
    return Err(AppError::Validation(
      "用户名须为字母开头,3-32 位字母/数字/下划线".into(),
    ));
  }
  validate_password(&req.password)?;
  verify_captcha(
    state,
    req.captcha_id.trim(),
    &req.captcha_code,
    Utc::now().naive_utc(),
  )
  .await?;
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

/// 扫码登录 —— 照 Trove login_tickets 三步流：
/// 桌面 `qr_create` 出票并渲染二维码 → 手机 `qr_scan`(鉴权)置已扫 →
/// 手机 `qr_confirm`(鉴权)为桌面设备签发 token 对 → 桌面 `qr_status`
/// 轮询领走。**token 一次性消费**：被领走时原子清空，防止同一 token 对
/// 被第二个轮询方领走（Trove 踩过的坑）。
#[derive(sqlx::FromRow)]
struct QrLoginRow {
  id: i64,
  status: i16,
  user_id: Option<i64>,
  token: Option<String>,
  refresh_token: Option<String>,
  expires_at: chrono::NaiveDateTime,
}

pub async fn qr_create(
  state: &AppState,
  desktop_device_id: &str,
  desktop_name: &str,
  headers: &HeaderMap,
) -> Result<(String, String), AppError> {
  let device_id = desktop_device_id.trim();
  if device_id.is_empty() || device_id.len() > 64 {
    return Err(AppError::Validation(
      "desktop_device_id is required (1-64 chars)".into(),
    ));
  }
  let now = Utc::now().naive_utc();
  sqlx::query("DELETE FROM auth_qr_logins WHERE expires_at < ?")
    .bind(now)
    .execute(&state.pool)
    .await?;
  let ticket = crate::utils::refresh_token::generate();
  let ticket = format!("{ticket}{}", crate::utils::refresh_token::generate());
  let expires_at = Utc::now() + chrono::Duration::minutes(5);
  sqlx::query(
    "INSERT INTO auth_qr_logins (ticket, status, desktop_device_id, desktop_name, expires_at)      VALUES (?, 0, ?, ?, ?)",
  )
  .bind(&ticket)
  .bind(device_id)
  .bind(trim_or_empty(&Some(desktop_name.to_string())))
  .bind(expires_at.naive_utc())
  .execute(&state.pool)
  .await?;
  let _ = headers;
  Ok((ticket, expires_at.to_rfc3339()))
}

pub async fn qr_status(
  state: &AppState,
  ticket: &str,
) -> Result<(i16, Option<String>, Option<String>, Option<String>), AppError> {
  // (status, access_token, refresh_token, username)
  let row: Option<QrLoginRow> = sqlx::query_as(
    "SELECT id, status, user_id, token, refresh_token, expires_at FROM auth_qr_logins WHERE ticket = ?",
  )
  .bind(ticket)
  .fetch_optional(&state.pool)
  .await?;
  let Some(row) = row else {
    return Err(AppError::NotFound("ticket not found".into()));
  };
  if row.expires_at < Utc::now().naive_utc() {
    return Ok((3, None, None, None));
  }
  // 一次性消费:token 只发给第一个看到 status=2 的轮询方,随后原子清空
  if row.status == 2 && row.token.is_some() {
    let consumed = sqlx::query(
      "UPDATE auth_qr_logins SET token = NULL, refresh_token = NULL        WHERE ticket = ? AND status = 2 AND token IS NOT NULL",
    )
    .bind(ticket)
    .execute(&state.pool)
    .await?;
    let username = match row.user_id {
      Some(uid) => sqlx::query_scalar::<_, String>("SELECT username FROM users WHERE id = ?")
        .bind(uid)
        .fetch_optional(&state.pool)
        .await
        .ok()
        .flatten(),
      None => None,
    };
    if consumed.rows_affected() == 1 {
      return Ok((2, row.token, row.refresh_token, username));
    }
    // 并发轮询:token 已被另一方领走
    return Ok((2, None, None, username));
  }
  // status=2 且 token 已被并发领走时 username 仍可查——无妨,token 拿不到
  let username = match row.user_id {
    Some(uid) => sqlx::query_scalar("SELECT username FROM users WHERE id = ?")
      .bind(uid)
      .fetch_optional(&state.pool)
      .await
      .ok()
      .flatten(),
    None => None,
  };
  Ok((row.status, username, None, None))
}

pub async fn qr_scan(state: &AppState, ticket: &str) -> Result<String, AppError> {
  let now = Utc::now().naive_utc();
  let res = sqlx::query(
    "UPDATE auth_qr_logins SET status = 1 WHERE ticket = ? AND status = 0 AND expires_at > ?",
  )
  .bind(ticket)
  .bind(now)
  .execute(&state.pool)
  .await?;
  if res.rows_affected() == 0 {
    return Err(AppError::Conflict("ticket already scanned or expired".into()));
  }
  let name: Option<String> = sqlx::query_scalar(
    "SELECT desktop_name FROM auth_qr_logins WHERE ticket = ?",
  )
  .bind(ticket)
  .fetch_optional(&state.pool)
  .await?
  .flatten();
  Ok(name.unwrap_or_default())
}

pub async fn qr_confirm(
  state: &AppState,
  user_id: i64,
  ticket: &str,
  device: Option<&DeviceInfoReq>,
  headers: &HeaderMap,
) -> Result<(), AppError> {
  let row: Option<QrLoginRow> = sqlx::query_as(
    "SELECT id, status, user_id, token, refresh_token, expires_at FROM auth_qr_logins WHERE ticket = ?",
  )
  .bind(ticket)
  .fetch_optional(&state.pool)
  .await?;
  let Some(row) = row else {
    return Err(AppError::NotFound("ticket not found".into()));
  };
  if row.expires_at < Utc::now().naive_utc() {
    return Err(AppError::Conflict("ticket expired".into()));
  }
  if row.status != 1 {
    return Err(AppError::Conflict("ticket not scanned".into()));
  }
  // 手机端申报的 device_id 必须与桌面 create 时申报一致——refresh token
  // 绑定到桌面的设备行上(吊销该设备即可吊销这次扫码登录)
  let desktop_device_id: String = sqlx::query_scalar(
    "SELECT desktop_device_id FROM auth_qr_logins WHERE id = ?",
  )
  .bind(row.id)
  .fetch_one(&state.pool)
  .await?;
  if let Some(d) = device {
    if !d.device_id.trim().is_empty() && d.device_id.trim() != desktop_device_id {
      return Err(AppError::Validation("device mismatch".into()));
    }
  }
  let token_pair = issue_tokens(
    state,
    user_id,
    Some(&DeviceInfoReq {
      device_id: desktop_device_id.clone(),
      name: None,
      platform: Some("macOS".into()),
    }),
    headers,
  )
  .await?;
  sqlx::query(
    "UPDATE auth_qr_logins SET status = 2, user_id = ?, token = ?, refresh_token = ? WHERE id = ?",
  )
  .bind(user_id)
  .bind(&token_pair.access_token)
  .bind(&token_pair.refresh_token)
  .bind(row.id)
  .execute(&state.pool)
  .await?;
  Ok(())
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
  // 双重限流:按 IP(防分布式爆破太贵,单实例先挡住单源)与按用户名(防定点爆破)。
  // 失败尝试同样计数。
  if !state.rate_limiter.allow(
    &format!("login:ip:{}", ip(headers)),
    20,
    Duration::from_secs(60),
  ) {
    return Err(AppError::RateLimited("尝试过于频繁，请稍后再试".into()));
  }
  if !state.rate_limiter.allow(
    &format!("login:user:{username}"),
    10,
    Duration::from_secs(60),
  ) {
    return Err(AppError::RateLimited("尝试过于频繁，请稍后再试".into()));
  }
  let row: Option<(i64, String, i8)> =
    sqlx::query_as("SELECT id, password_hash, status FROM users WHERE username = ?")
      .bind(username)
      .fetch_optional(&state.pool)
      .await?;
  let Some((user_id, hash, status)) = row else {
    return Err(AppError::Unauthorized("账号或密码错误".into()));
  };
  if status == 0 {
    return Err(AppError::Forbidden("account disabled".into()));
  }
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
  // E2E 换包:客户端随改密提交新盐+新包裹体(同 DEK 重包裹),既有密文保持可解
  if let (Some(salt), Some(wrapped)) = (&req.new_kdf_salt, &req.new_wrapped_dek) {
    sqlx::query("UPDATE users SET password_hash = ?, kdf_salt = ?, wrapped_dek = ? WHERE id = ?")
      .bind(new_hash)
      .bind(salt)
      .bind(wrapped)
      .bind(user_id)
      .execute(&state.pool)
      .await?;
    return Ok(());
  }
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
    // 合法:8 位起,字母+数字
    assert!(validate_password("pass1234").is_ok());
    assert!(validate_password("a1").is_err()); // 太短
    assert!(validate_password("aaaaaaaa").is_err()); // 纯字母
    assert!(validate_password("12345678").is_err()); // 纯数字
    assert!(validate_password("a".repeat(72).as_str()).is_err()); // 无数字
    assert!(validate_password("a1".repeat(36).as_str()).is_ok()); // 72 位上限
    let too_long = format!("{}a", "a1".repeat(36));
    assert!(matches!(
      validate_password(too_long.as_str()),
      Err(AppError::Validation(_))
    ));
    assert!(matches!(
      validate_password("12345"),
      Err(AppError::Validation(_))
    ));
  }
}
