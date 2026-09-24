use crate::modules::sync::sync_controller;
use crate::types::AppState;
use axum::Router;
use axum::routing::get;

/// 拉取与推送共用 /sync/{domain}(GET pull / POST push);
/// 密钥指纹在 /sync/key-check;全部在 jwt_auth 保护层内(同步数据永远属于登录用户)。
pub fn router() -> Router<AppState> {
  Router::new()
    .route(
      "/sync/{domain}",
      get(sync_controller::pull).post(sync_controller::push),
    )
    .route(
      "/sync/key-check",
      get(sync_controller::key_check).put(sync_controller::set_key_check),
    )
}
