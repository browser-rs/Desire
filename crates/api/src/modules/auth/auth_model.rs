use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

/// 登录态设备描述(可选携带):device_id 由客户端生成并持久稳定,
/// 同一 (user, device_id) 重复登录视为同一台设备(撤销态一并清掉)。
#[derive(Debug, Clone, Deserialize, ToSchema)]
pub struct DeviceInfoReq {
  pub device_id: String,
  #[serde(default)]
  pub name: Option<String>,
  /// 平台标识,如 macOS / iOS / Windows
  #[serde(default)]
  pub platform: Option<String>,
}

#[derive(Debug, Deserialize, ToSchema)]
pub struct RegisterReq {
  /// 字母开头,3-32 位字母/数字/下划线
  pub username: String,
  /// 6-72 字节(bcrypt 上限)
  pub password: String,
  #[serde(default)]
  pub nickname: Option<String>,
  #[serde(default)]
  pub device: Option<DeviceInfoReq>,
}

#[derive(Debug, Deserialize, ToSchema)]
pub struct LoginReq {
  pub username: String,
  pub password: String,
  #[serde(default)]
  pub device: Option<DeviceInfoReq>,
}

#[derive(Debug, Deserialize, ToSchema)]
pub struct RefreshReq {
  pub refresh_token: String,
}

#[derive(Debug, Deserialize, ToSchema)]
pub struct LogoutReq {
  pub refresh_token: String,
}

#[derive(Debug, Deserialize, ToSchema)]
pub struct RevokeDeviceReq {
  /// 客户端侧稳定设备 ID(非 devices.id)
  pub device_id: String,
}

/// 设置/修改密码:已设置过密码的账号必须带 old_password 且匹配,否则 401
#[derive(Debug, Deserialize, ToSchema)]
pub struct SetPasswordReq {
  pub old_password: String,
  pub new_password: String,
}

#[derive(Debug, Deserialize, ToSchema)]
pub struct UpdateProfileReq {
  #[serde(default)]
  pub nickname: Option<String>,
  /// 空串 = 清除邮箱;非空须含 '@'
  #[serde(default)]
  pub email: Option<String>,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct TokenPair {
  pub access_token: String,
  pub refresh_token: String,
  pub expires_in: i64,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct MeDto {
  pub id: i64,
  pub username: String,
  pub nickname: String,
  /// 未绑定时为空串
  pub email: String,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct DeviceDto {
  pub id: i64,
  /// 客户端侧稳定设备 ID
  pub device_id: String,
  pub name: String,
  pub platform: String,
  /// 已被吊销(该设备的 refresh token 全部失效,重新登录即恢复)
  pub revoked: bool,
  pub last_seen_at: chrono::NaiveDateTime,
  pub created_at: chrono::NaiveDateTime,
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct UserRow {
  pub id: i64,
  pub username: String,
  pub nickname: String,
  pub email: Option<String>,
  pub status: i8,
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct RefreshTokenRow {
  pub id: i64,
  pub user_id: i64,
  pub device_id: Option<i64>,
  pub expires_at: chrono::NaiveDateTime,
  pub revoked_at: Option<chrono::NaiveDateTime>,
}

#[derive(Debug, Clone, sqlx::FromRow)]
pub struct DeviceRow {
  pub id: i64,
  pub device_id: String,
  pub name: String,
  pub platform: String,
  pub revoked_at: Option<chrono::NaiveDateTime>,
  pub last_seen_at: chrono::NaiveDateTime,
  pub created_at: chrono::NaiveDateTime,
}

impl From<DeviceRow> for DeviceDto {
  fn from(r: DeviceRow) -> Self {
    DeviceDto {
      id: r.id,
      device_id: r.device_id,
      name: r.name,
      platform: r.platform,
      revoked: r.revoked_at.is_some(),
      last_seen_at: r.last_seen_at,
      created_at: r.created_at,
    }
  }
}
