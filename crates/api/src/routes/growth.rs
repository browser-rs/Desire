use axum::Router;
use axum::http::HeaderValue;
use axum::http::Method;
use axum::http::header::CONTENT_TYPE;
use axum::routing::{get, post};
use tower_http::cors::{AllowOrigin, CorsLayer};

use crate::modules::growth::growth_controller;
use crate::types::AppState;

/// 公开事件入口：只允许产品页与本地 fixture 跨源；无凭证、无 Cookie。
pub fn public() -> Router<AppState> {
  let origins: Vec<HeaderValue> = [
    "https://desire.mankong.icu",
    "http://127.0.0.1:8877",
    "http://localhost:8877",
  ]
  .into_iter()
  .filter_map(|origin| origin.parse::<HeaderValue>().ok())
  .collect();
  let cors = CorsLayer::new()
    .allow_origin(AllowOrigin::list(origins))
    .allow_methods([Method::POST, Method::OPTIONS])
    .allow_headers([CONTENT_TYPE]);
  Router::new()
    .route("/growth/event", post(growth_controller::event))
    .layer(cors)
}

/// 聚合读取：登录态（与同步共用账号）。单 owner 部署下够用；公开运营前
/// 再收窄到管理员角色。
pub fn protected() -> Router<AppState> {
  Router::new().route("/growth/summary", get(growth_controller::summary))
}
