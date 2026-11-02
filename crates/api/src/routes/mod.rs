pub mod auth;
pub mod demo;
pub mod growth;
pub mod remote;
pub mod sync;

use crate::cache;
use crate::configs::Env;
use crate::middleware::auth::jwt_auth;
use crate::types::AppState;
use axum::Json;
use axum::Router;
use axum::extract::{MatchedPath, Request, State};
use axum::http::{HeaderMap, HeaderValue, StatusCode, header};
use axum::middleware::{self, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use uuid::Uuid;

/// 健康检查（v0.8.38 C6）：DB 与（配置了的话）Redis 真实探活。
/// 任一依赖失败 → 503；响应体带 db/redis 布尔与版本，LB/巡检能区分
/// "进程活着但依赖挂了"。
async fn health(State(state): State<AppState>) -> Response {
  // 3s 上限：依赖挂死时健康检查必须快速返回 503，不能把探活也拖到
  // sqlx 的默认连接超时（LB 会以为进程也挂了）。
  let db_ok = tokio::time::timeout(
    std::time::Duration::from_secs(3),
    sqlx::query_scalar::<_, i32>("SELECT 1").fetch_one(&state.pool),
  )
  .await
  .map(|result| result.is_ok())
  .unwrap_or(false);
  let redis_ok = tokio::time::timeout(std::time::Duration::from_secs(2), cache::ping(&state.redis))
    .await
    .unwrap_or(false);
  let ok = db_ok && redis_ok;
  let status = if ok {
    StatusCode::OK
  } else {
    StatusCode::SERVICE_UNAVAILABLE
  };
  (
    status,
    Json(serde_json::json!({
      "code": if ok { 0 } else { 503 },
      "message": if ok { "ok" } else { "degraded" },
      "data": {
        "db": db_ok,
        "redis": redis_ok,
        "version": env!("CARGO_PKG_VERSION"),
        "serverTime": chrono::Utc::now().to_rfc3339(),
      }
    })),
  )
    .into_response()
}

/// 服务端能力声明（v0.8.38 C9）：客户端据此决定推哪些同步域、用哪些
/// 远端帧，避免"旧服务端只缺 ebooks 就整轮同步失败"。
async fn capabilities() -> Json<serde_json::Value> {
  Json(serde_json::json!({
    "code": 0,
    "message": "ok",
    "data": {
      "apiVersion": "2.0",
      "syncDomains": crate::modules::sync::sync_model::DOMAINS,
      "syncDomainPrefixes": true,
      "remoteFrames": [
        "snapshot", "sessions", "downloads", "recentFiles", "excerpts",
        "briefs", "archivedSessions", "tasks", "notificationPolicy",
        "capabilities", "stats", "trace", "models", "memory",
        "books", "toolboxCatalog", "toolboxRun", "workspaces",
        "sendToPhone", "notify", "turnDone"
      ],
      "features": {
        "remoteAck": true,
        "remoteStats": true,
        "syncUsage": true,
        "metrics": true,
        "requestId": true
      },
      "serverTime": chrono::Utc::now().to_rfc3339(),
    }
  }))
}

/// Prometheus 文本指标（v0.8.38 C6）。dev 直接可读；prod 需要
/// `DESIRE_API_METRICS_TOKEN` 且请求带 `Authorization: Bearer <token>`，
/// 未配置 token 时 prod 返回 404（不把运营数据暴露在公网）。
async fn metrics(State(state): State<AppState>, headers: HeaderMap) -> Response {
  let allowed = matches!(state.config.env, Env::Dev)
    || (!state.config.metrics_token.is_empty()
      && headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .map(|value| value == format!("Bearer {}", state.config.metrics_token))
        .unwrap_or(false));
  if !allowed {
    return StatusCode::NOT_FOUND.into_response();
  }
  (
    [(
      header::CONTENT_TYPE,
      "text/plain; version=0.0.4; charset=utf-8",
    )],
    crate::utils::metrics::render(),
  )
    .into_response()
}

/// 请求 id + 访问日志 + 指标（v0.8.38 C6）。响应头 `x-request-id` 供客户端
/// 报障时带上；日志用同一个 id，能在多行日志里串起一次请求。
async fn request_context(req: Request, next: Next) -> Response {
  let started = std::time::Instant::now();
  let request_id = req
    .headers()
    .get("x-request-id")
    .and_then(|value| value.to_str().ok())
    .filter(|value| !value.is_empty() && value.len() <= 64)
    .map(str::to_string)
    .unwrap_or_else(|| Uuid::new_v4().simple().to_string());
  let route = req
    .extensions()
    .get::<MatchedPath>()
    .map(|path| path.as_str().to_string())
    .unwrap_or_else(|| req.uri().path().to_string());
  let method = req.method().clone();
  let mut response = next.run(req).await;
  let status = response.status().as_u16();
  let duration_ms = started.elapsed().as_millis() as u64;
  crate::utils::metrics::record(&route, status, duration_ms);
  if let Ok(value) = HeaderValue::from_str(&request_id) {
    response.headers_mut().insert("x-request-id", value);
  }
  tracing::info!(
    request_id = %request_id,
    method = %method,
    route = %route,
    status,
    duration_ms,
    "request"
  );
  response
}

pub fn build_router(state: AppState) -> Router {
  let protected = Router::new()
    .merge(auth::protected())
    .merge(sync::router())
    .merge(growth::protected())
    .merge(remote::router())
    .layer(middleware::from_fn_with_state(state.clone(), jwt_auth));

  // demo 演示场：公开 + 单独放行 CORS（网站 demo 页跨源调用）。
  // 数据是无鉴权无 Cookie 的内存演示态，permissive CORS 无风险面；
  // 不要把这层挂到 auth/sync 等真实 API 上。
  let demo = Router::new()
    .merge(demo::router())
    .layer(tower_http::cors::CorsLayer::permissive());
  // 增长事件：公开匿名 + 限定产品页 CORS。
  let growth = growth::public();

  let root = Router::new()
    .route("/health", get(health))
    .route("/meta/capabilities", get(capabilities))
    .route("/metrics", get(metrics))
    .merge(auth::public())
    .merge(demo)
    .merge(growth)
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
  root
    .layer(middleware::from_fn(request_context))
    .with_state(state)
}
