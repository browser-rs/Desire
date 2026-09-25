use axum::Json;
use axum::extract::{Extension, State};

use crate::api_ok;
use crate::errors::AppError;
use crate::types::{ApiResponse, ApiResult, AppState};
use crate::utils::jwt::Claims;

use super::auth_model::{
  CaptchaResp, DeviceDto, KeyEscrowBody, KeyEscrowResp, LoginReq, LogoutReq, MeDto, RefreshReq,
  RegisterReq, RevokeDeviceReq, SetPasswordReq, TokenPair, UpdateProfileReq,
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
