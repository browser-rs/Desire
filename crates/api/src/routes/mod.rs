pub mod auth;
pub mod sync;

use crate::middleware::auth::jwt_auth;
use crate::types::AppState;
use axum::Json;
use axum::Router;
use axum::middleware;
use axum::routing::get;

async fn health() -> Json<serde_json::Value> {
  Json(serde_json::json!({"code": 0, "message": "ok", "data": null}))
}

pub fn build_router(state: AppState) -> Router {
  let protected = Router::new()
    .merge(auth::protected())
    .merge(sync::router())
    .layer(middleware::from_fn_with_state(state.clone(), jwt_auth));

  let root = Router::new()
    .route("/health", get(health))
    .merge(auth::public())
    .merge(protected);
  // OpenAPI 契约仅 dev 暴露(prod 不对外公开接口文档)
  let root = if matches!(state.config.env, crate::configs::Env::Dev) {
    root.route(
      "/openapi.json",
      axum::routing::get(crate::docs::openapi_json),
    )
  } else {
    root
  };
  root.with_state(state)
}
