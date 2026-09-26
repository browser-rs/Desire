use crate::modules::auth::auth_controller;
use crate::types::AppState;
use axum::Router;
use axum::routing::{get, post};

/// 公开端点(无需登录):验证码 / 注册 / 登录 / 刷新 / 登出。
pub fn public() -> Router<AppState> {
  Router::new()
    .route("/auth/captcha", get(auth_controller::captcha))
    .route("/auth/register", post(auth_controller::register))
    .route("/auth/login", post(auth_controller::login))
    .route("/auth/refresh", post(auth_controller::refresh))
    .route("/auth/logout", post(auth_controller::logout))
    .route("/auth/qr/create", post(auth_controller::qr_create))
    .route("/auth/qr/status", get(auth_controller::qr_status))
}

/// 登录态端点(jwt_auth 统一保护)。
pub fn protected() -> Router<AppState> {
  Router::new()
    .route(
      "/sync/key-escrow",
      get(auth_controller::key_escrow).put(auth_controller::set_key_escrow),
    )
    .route("/auth/me", get(auth_controller::me))
    .route("/auth/me", axum::routing::put(auth_controller::update_me))
    .route(
      "/auth/password",
      axum::routing::put(auth_controller::set_password),
    )
    .route("/auth/qr/scan", post(auth_controller::qr_scan))
    .route("/auth/qr/confirm", post(auth_controller::qr_confirm))
    .route("/auth/devices", get(auth_controller::list_devices))
    .route("/auth/devices/revoke", post(auth_controller::revoke_device))
}
