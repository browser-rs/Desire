use crate::modules::auth::auth_controller;
use crate::types::AppState;
use axum::Router;
use axum::routing::{get, post};

pub fn public() -> Router<AppState> {
  Router::new()
    .route("/auth/captcha", get(auth_controller::captcha))
    .route("/auth/register", post(auth_controller::register))
    .route("/auth/login", post(auth_controller::login))
    .route("/auth/refresh", post(auth_controller::refresh))
    .route("/auth/logout", post(auth_controller::logout))
}

pub fn protected() -> Router<AppState> {
  Router::new()
    .route("/auth/me", get(auth_controller::me))
    .route("/auth/me", axum::routing::put(auth_controller::update_me))
    .route(
      "/auth/password",
      axum::routing::put(auth_controller::set_password),
    )
    .route("/auth/devices", get(auth_controller::list_devices))
    .route("/auth/devices/revoke", post(auth_controller::revoke_device))
}
