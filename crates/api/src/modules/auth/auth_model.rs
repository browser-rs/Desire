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
  /// 8-72 字节,须含字母和数字
  pub password: String,
  #[serde(default)]
  pub nickname: Option<String>,
  #[serde(default)]
  pub device: Option<DeviceInfoReq>,
  /// 注册验证码 id(GET /auth/captcha 签发)
  pub captcha_id: String,
  /// 用户输入的验证码字符
  pub captcha_code: String,
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
  /// 改密时同步换包:新盐 + 新 KEK 包裹的 DEK(E2E;缺省 = 该账号无托管密钥)
  #[serde(default)]
  pub new_kdf_salt: Option<String>,
  #[serde(default)]
  pub new_wrapped_dek: Option<String>,
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

#[derive(Debug, Serialize, ToSchema)]
pub struct KeyEscrowResp {
  /// PBKDF2 盐(base64);None = 该账号尚未托管密钥(第一台设备)
  pub kdf_salt: Option<String>,
  /// 包裹后的 DEK(JSON 信封文本,服务端不可读);None = 无
  pub wrapped_dek: Option<String>,
  /// DEK 指纹(hex),客户端用于校验密钥一致性
  pub key_check: Option<String>,
}

#[derive(Debug, Deserialize, ToSchema)]
pub struct KeyEscrowBody {
  pub kdf_salt: String,
  pub wrapped_dek: String,
  /// DEK 指纹(hex);与已有指纹不一致时 409(防拿错密钥覆盖)
  pub key_check: String,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct CaptchaResp {
  pub captcha_id: String,
  /// PNG 图片的 base64(标准字母表)
  pub image: String,
  /// 仅 dev 环境返回明文码(冒烟脚本用);prod 为 None
  #[serde(skip_serializing_if = "Option::is_none")]
  pub code: Option<String>,
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

// MARK: - 扫码登录（桌面显示二维码，手机 App 扫码并在手机上确认）

#[derive(Debug, Deserialize, ToSchema)]
pub struct QrCreateReq {
  /// 桌面端稳定设备 id（确认时为该设备登记并签发 refresh）
  pub desktop_device_id: String,
  #[serde(default)]
  pub desktop_name: Option<String>,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct QrCreateResp {
  /// 手机端扫码内容即此 ticket（二维码 payload 建议带服务器地址便于校验）
  pub ticket: String,
  pub expires_at: String,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct QrStatusResp {
  /// 0=待扫码 1=已扫码待确认 2=已确认(含 token，一次性领取) 3=过期
  pub status: i16,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub access_token: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub refresh_token: Option<String>,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub username: Option<String>,
}

#[derive(Debug, Deserialize, ToSchema)]
pub struct QrScanReq {
  pub ticket: String,
}

#[derive(Debug, Deserialize, ToSchema)]
pub struct QrConfirmReq {
  pub ticket: String,
  /// 桌面端设备信息（create 时申报的 desktop_device_id 须一致）
  #[serde(default)]
  pub device: Option<DeviceInfoReq>,
}
