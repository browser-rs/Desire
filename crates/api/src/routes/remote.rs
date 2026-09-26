use crate::modules::remote::remote_controller;
use crate::types::AppState;
use axum::Router;
use axum::routing::{get, post};

/// 远程控制：配对 REST + 中继 WS。全部在 jwt_auth 保护层内;
/// WS 的角色/设备经查询参数,业务载荷为 E2E 密文,服务器只路由。
pub fn router() -> Router<AppState> {
  Router::new()
    .route(
      "/remote/pairing/start",
      post(remote_controller::pairing_start),
    )
    .route(
      "/remote/pairing/claim",
      post(remote_controller::pairing_claim),
    )
    .route(
      "/remote/pairing/revoke",
      post(remote_controller::pairing_revoke),
    )
    .route("/remote/devices", get(remote_controller::devices))
    .route("/remote/pull", get(remote_controller::pull_inbox))
    .route("/remote/ws", get(remote_controller::ws))
}
