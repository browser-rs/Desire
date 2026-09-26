use serde::{Deserialize, Serialize};

/// 配对码签发请求(desktop 端,登录态)。
#[derive(Deserialize)]
pub struct PairingStartReq {
  /// 浏览器的稳定设备 id(与云同步 device_id 同源)
  pub desktop_device_id: String,
  pub desktop_name: String,
}

/// 配对码认领请求(controller 端,登录态;扫码得到 code)。
#[derive(Deserialize)]
pub struct PairingClaimReq {
  pub code: String,
  pub controller_name: String,
}

#[derive(Serialize, utoipa::ToSchema)]
pub struct PairingClaimResp {
  pub desktop_device_id: String,
  pub desktop_name: String,
}

#[derive(Serialize, utoipa::ToSchema)]
pub struct PairedDevice {
  pub desktop_device_id: String,
  pub desktop_name: String,
  pub controller_name: String,
  pub online: bool,
  #[serde(rename = "createdAt")]
  pub created_at: String,
}

#[derive(Deserialize)]
pub struct PairingRevokeReq {
  pub desktop_device_id: String,
  /// 缺省 = 吊销该桌面全部配对(如换手机)
  pub controller_name: Option<String>,
}

/// POST /remote/push 请求体。业务载荷 `payload`(E2E 密文,服务器不解读);
/// `replace` = 新帧作废收件信箱里的 pending 旧帧(快照语义,离线堆积有界)。
#[derive(Deserialize)]
pub struct PushFrameReq {
  pub payload: String,
  #[serde(default)]
  pub replace: bool,
}
