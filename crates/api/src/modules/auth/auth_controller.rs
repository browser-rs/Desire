use axum::Json;
use axum::extract::{Extension, State};

use crate::api_ok;
use crate::errors::AppError;
use crate::types::{ApiResponse, ApiResult, AppState};
use crate::utils::jwt::Claims;

use super::auth_model::{
  CaptchaResp, DeviceDto, KeyEscrowBody, KeyEscrowResp, LoginReq, LogoutReq, MeDto, QrConfirmReq,
  QrCreateReq, QrCreateResp, QrScanReq, QrStatusResp, RefreshReq, RegisterReq, RevokeDeviceReq,
  SetPasswordReq, TokenPair, UpdateProfileReq,
};
use super::auth_service;

/// 注册验证码图片（公开；dev 环境响应附带明文码供冒烟脚本用）。
#[utoipa::path(
  get, path = "/auth/captcha", tag = "auth",
  responses((status = 200, body = CaptchaResp))
)]
pub async fn captcha(
  State(state): State<AppState>,
  headers: axum::http::HeaderMap,
) -> ApiResult<CaptchaResp> {
  let resp = auth_service::new_captcha(&state, &headers).await?;
  api_ok!(resp)
}

#[utoipa::path(
  post, path = "/auth/register", tag = "auth",
  request_body = RegisterReq,
  responses((status = 200, body = TokenPair))
)]
pub async fn register(
  State(state): State<AppState>,
  headers: axum::http::HeaderMap,
  Json(req): Json<RegisterReq>,
) -> ApiResult<TokenPair> {
  let tokens = auth_service::register(&state, &headers, req).await?;
  api_ok!(tokens)
}

#[utoipa::path(
  post, path = "/auth/login", tag = "auth",
  request_body = LoginReq,
  responses((status = 200, body = TokenPair))
)]
pub async fn login(
  State(state): State<AppState>,
  headers: axum::http::HeaderMap,
  Json(req): Json<LoginReq>,
) -> ApiResult<TokenPair> {
  let tokens = auth_service::login(&state, &headers, req).await?;
  api_ok!(tokens)
}

/// POST /auth/qr/create —— 桌面端出票并渲染二维码(无鉴权;IP 限流)。
pub async fn qr_create(
  State(state): State<AppState>,
  headers: axum::http::HeaderMap,
  Json(req): Json<QrCreateReq>,
) -> ApiResult<QrCreateResp> {
  let client_ip = headers
    .get("x-forwarded-for")
    .and_then(|v| v.to_str().ok())
    .unwrap_or("");
  if !state.rate_limiter.allow(
    &format!("qr-create-ip:{client_ip}"),
    20,
    std::time::Duration::from_secs(600),
  ) {
    return Err(AppError::Validation("创建过于频繁".into()));
  }
  let (ticket, expires_at) = auth_service::qr_create(
    &state,
    &req.desktop_device_id,
    req.desktop_name.as_deref().unwrap_or(""),
    &headers,
  )
  .await?;
  api_ok!(QrCreateResp { ticket, expires_at })
}

/// GET /auth/qr/status?ticket= —— 桌面端轮询(无鉴权;token 一次性消费)。
pub async fn qr_status(
  State(state): State<AppState>,
  axum::extract::Query(params): axum::extract::Query<std::collections::HashMap<String, String>>,
) -> ApiResult<QrStatusResp> {
  let ticket = params.get("ticket").cloned().unwrap_or_default();
  if ticket.is_empty() || ticket.len() > 64 {
    return Err(AppError::Validation("invalid ticket".into()));
  }
  let (status, access_token, refresh_token, username) =
    auth_service::qr_status(&state, &ticket).await?;
  api_ok!(QrStatusResp { status, access_token, refresh_token, username })
}

/// POST /auth/qr/scan —— 手机端扫码(鉴权):置"已扫码待确认"。
pub async fn qr_scan(
  State(state): State<AppState>,
  Extension(_claims): Extension<Claims>,
  Json(req): Json<QrScanReq>,
) -> ApiResult<serde_json::Value> {
  let desktop_name = auth_service::qr_scan(&state, &req.ticket).await?;
  api_ok!(serde_json::json!({ "desktopName": desktop_name }))
}

/// POST /auth/qr/confirm —— 手机端确认(鉴权):为桌面设备签发 token 对。
pub async fn qr_confirm(
  State(state): State<AppState>,
  Extension(claims): Extension<crate::utils::jwt::Claims>,
  headers: axum::http::HeaderMap,
  Json(req): Json<QrConfirmReq>,
) -> ApiResult<serde_json::Value> {
  auth_service::qr_confirm(
    &state,
    claims.sub,
    &req.ticket,
    req.device.as_ref(),
    &headers,
  )
  .await?;
  api_ok!(serde_json::json!({ "ok": true }))
}

#[utoipa::path(
  post, path = "/auth/refresh", tag = "auth",
  request_body = RefreshReq,
  responses((status = 200, body = TokenPair))
)]
pub async fn refresh(
  State(state): State<AppState>,
  headers: axum::http::HeaderMap,
  Json(req): Json<RefreshReq>,
) -> ApiResult<TokenPair> {
  let tokens = auth_service::refresh(&state, &headers, &req.refresh_token).await?;
  api_ok!(tokens)
}

#[utoipa::path(
  post, path = "/auth/logout", tag = "auth",
  request_body = LogoutReq,
  responses((status = 200))
)]
pub async fn logout(State(state): State<AppState>, Json(req): Json<LogoutReq>) -> ApiResult<()> {
  auth_service::logout(&state, &req.refresh_token).await?;
  Ok(Json(ApiResponse::<()>::empty()))
}

#[utoipa::path(
  get, path = "/auth/me", tag = "auth",
  responses((status = 200, body = MeDto))
)]
pub async fn me(
  State(state): State<AppState>,
  Extension(claims): Extension<Claims>,
) -> ApiResult<MeDto> {
  let me = auth_service::me(&state, claims.sub).await?;
  api_ok!(me)
}

#[utoipa::path(
  put, path = "/auth/me", tag = "auth",
  request_body = UpdateProfileReq,
  responses((status = 200, body = MeDto))
)]
pub async fn update_me(
  State(state): State<AppState>,
  Extension(claims): Extension<Claims>,
  Json(req): Json<UpdateProfileReq>,
) -> ApiResult<MeDto> {
  let me = auth_service::update_profile(&state, claims.sub, req).await?;
  api_ok!(me)
}

#[utoipa::path(
  put, path = "/auth/password", tag = "auth",
  request_body = SetPasswordReq,
  responses((status = 200))
)]
pub async fn set_password(
  State(state): State<AppState>,
  Extension(claims): Extension<Claims>,
  Json(req): Json<SetPasswordReq>,
) -> Result<Json<ApiResponse<()>>, AppError> {
  auth_service::set_password(&state, claims.sub, req).await?;
  Ok(Json(ApiResponse::<()>::empty()))
}

/// E2E 密钥托管：读取（GET）或上报（PUT）盐+包裹 DEK+指纹。
#[utoipa::path(
  get, path = "/sync/key-escrow", tag = "sync",
  responses((status = 200, body = KeyEscrowResp))
)]
pub async fn key_escrow(
  State(state): State<AppState>,
  Extension(claims): Extension<Claims>,
) -> ApiResult<KeyEscrowResp> {
  let resp = auth_service::key_escrow_get(&state, claims.sub).await?;
  api_ok!(resp)
}

#[utoipa::path(
  put, path = "/sync/key-escrow", tag = "sync",
  request_body = KeyEscrowBody,
  responses((status = 200))
)]
pub async fn set_key_escrow(
  State(state): State<AppState>,
  Extension(claims): Extension<Claims>,
  Json(req): Json<KeyEscrowBody>,
) -> ApiResult<()> {
  auth_service::key_escrow_set(
    &state,
    claims.sub,
    &req.kdf_salt,
    &req.wrapped_dek,
    &req.key_check,
  )
  .await?;
  Ok(Json(ApiResponse::<()>::empty()))
}

#[utoipa::path(
  get, path = "/auth/devices", tag = "auth",
  responses((status = 200, body = [DeviceDto]))
)]
pub async fn list_devices(
  State(state): State<AppState>,
  Extension(claims): Extension<Claims>,
) -> ApiResult<Vec<DeviceDto>> {
  let devices = auth_service::list_devices(&state, claims.sub).await?;
  api_ok!(devices)
}

#[utoipa::path(
  post, path = "/auth/devices/revoke", tag = "auth",
  request_body = RevokeDeviceReq,
  responses((status = 200))
)]
pub async fn revoke_device(
  State(state): State<AppState>,
  Extension(claims): Extension<Claims>,
  Json(req): Json<RevokeDeviceReq>,
) -> ApiResult<()> {
  auth_service::revoke_device(&state, claims.sub, &req.device_id).await?;
  Ok(Json(ApiResponse::<()>::empty()))
}
