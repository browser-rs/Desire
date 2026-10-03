//! demo 演示端点——公开（不过 JWT）、落 MySQL（部署是多实例 +
//! nginx 轮询无 sticky，演示态必须共享存储）、给 website/demo 的
//! DPP 演示页用。不做 OpenAPI 注解：这不是产品 API 面，是协议演示场。

use std::time::Duration;

use axum::Json;
use axum::extract::{Path, Query, State};
use axum::http::HeaderMap;

use crate::api_ok;
use crate::errors::AppError;
use crate::types::{ApiResult, AppState};

use super::demo_model::{
  AddCartReq, DemoCartSnapshot, DemoForumComment, DemoForumPost, DemoImChannel, DemoImMessage,
  DemoOrder, DemoProduct, ImQuery, ImSendReq, LikeResult, NewCommentReq, NewPostReq,
};
use super::demo_service;

/// `X-Demo-Client`：页面生成的访客标识（localStorage UUID）。
fn client_id(headers: &HeaderMap) -> Result<String, AppError> {
  let raw = headers
    .get("x-demo-client")
    .and_then(|v| v.to_str().ok())
    .unwrap_or("")
    .trim();
  if raw.is_empty() || raw.len() > 64 {
    return Err(AppError::Validation("缺少 X-Demo-Client 头".into()));
  }
  Ok(raw.to_string())
}

/// GET /demo/products
pub async fn products(State(state): State<AppState>) -> ApiResult<Vec<DemoProduct>> {
  let _pool = &state.pool;
  api_ok!(demo_service::products())
}

/// GET /demo/cart
pub async fn cart_get(
  State(state): State<AppState>,
  headers: HeaderMap,
) -> ApiResult<DemoCartSnapshot> {
  let client = client_id(&headers)?;
  api_ok!(demo_service::cart_get(&state.pool, &client).await?)
}

/// POST /demo/cart/items {sku, qty?}
pub async fn cart_add(
  State(state): State<AppState>,
  headers: HeaderMap,
  Json(body): Json<AddCartReq>,
) -> ApiResult<DemoCartSnapshot> {
  let client = client_id(&headers)?;
  let sku = body.sku.trim();
  if sku.is_empty() {
    return Err(AppError::Validation("sku 不能为空".into()));
  }
  api_ok!(demo_service::cart_add(&state.pool, &client, sku, body.qty.unwrap_or(1)).await?)
}

/// DELETE /demo/cart/items/{sku}
pub async fn cart_remove(
  State(state): State<AppState>,
  headers: HeaderMap,
  Path(sku): Path<String>,
) -> ApiResult<DemoCartSnapshot> {
  let client = client_id(&headers)?;
  api_ok!(demo_service::cart_remove(&state.pool, &client, &sku).await?)
}

/// POST /demo/orders —— 结算：购物车 → 订单，并清空购物车。
pub async fn checkout(State(state): State<AppState>, headers: HeaderMap) -> ApiResult<DemoOrder> {
  let client = client_id(&headers)?;
  api_ok!(demo_service::checkout(&state.pool, &client).await?)
}

/// GET /demo/orders —— 当前访客的订单列表（新的在前）。
pub async fn orders_get(
  State(state): State<AppState>,
  headers: HeaderMap,
) -> ApiResult<Vec<DemoOrder>> {
  let client = client_id(&headers)?;
  api_ok!(demo_service::orders_get(&state.pool, &client).await?)
}

// ── IM 演示（客服 / 招聘） ────────────────────────────────

/// GET /demo/im/channels
pub async fn im_channels(State(state): State<AppState>) -> ApiResult<Vec<DemoImChannel>> {
  let _ = &state;
  api_ok!(demo_service::im_channels())
}

/// GET /demo/im/messages?channel=&after_id= —— 增量拉取（轮询，按访客隔离）。
pub async fn im_messages(
  State(state): State<AppState>,
  headers: HeaderMap,
  Query(q): Query<ImQuery>,
) -> ApiResult<Vec<DemoImMessage>> {
  let client = client_id(&headers)?;
  api_ok!(
    demo_service::im_messages(
      &state.pool,
      &client,
      q.channel.trim(),
      q.after_id.unwrap_or(0)
    )
    .await?
  )
}

/// POST /demo/im/messages {channel, content} —— 发送并拿回一问一答。
pub async fn im_send(
  State(state): State<AppState>,
  headers: HeaderMap,
  Json(body): Json<ImSendReq>,
) -> ApiResult<Vec<DemoImMessage>> {
  let client = client_id(&headers)?;
  // 公开端点的最低限度卫生：每客户端 30 条/分钟。
  if !state
    .rate_limiter
    .allow(&format!("demo-im-{client}"), 30, Duration::from_secs(60))
  {
    return Err(AppError::RateLimited("发太快了，稍后再试".into()));
  }
  api_ok!(demo_service::im_send(&state.pool, &client, body.channel.trim(), &body.content).await?)
}

// ── 论坛演示（发帖 / 点赞 / 评论） ────────────────────────

/// GET /demo/forum/posts —— client 头可选（缺席 = 不标 mine/liked_by_me）。
pub async fn forum_posts(
  State(state): State<AppState>,
  headers: HeaderMap,
) -> ApiResult<Vec<DemoForumPost>> {
  let client = client_id(&headers).unwrap_or_default();
  api_ok!(demo_service::forum_posts(&state.pool, &client).await?)
}

/// POST /demo/forum/posts {title, content}
pub async fn forum_create(
  State(state): State<AppState>,
  headers: HeaderMap,
  Json(body): Json<NewPostReq>,
) -> ApiResult<DemoForumPost> {
  let client = client_id(&headers)?;
  api_ok!(demo_service::forum_create_post(&state.pool, &client, &body.title, &body.content).await?)
}

/// POST /demo/forum/posts/{id}/like —— toggle。
pub async fn forum_like(
  State(state): State<AppState>,
  headers: HeaderMap,
  Path(post_id): Path<i64>,
) -> ApiResult<LikeResult> {
  let client = client_id(&headers)?;
  api_ok!(demo_service::forum_toggle_like(&state.pool, &client, post_id).await?)
}

/// GET /demo/forum/posts/{id}/comments
pub async fn forum_comments(
  State(state): State<AppState>,
  headers: HeaderMap,
  Path(post_id): Path<i64>,
) -> ApiResult<Vec<DemoForumComment>> {
  let client = client_id(&headers).unwrap_or_default();
  api_ok!(demo_service::forum_comments(&state.pool, &client, post_id).await?)
}

/// POST /demo/forum/posts/{id}/comments {content}
pub async fn forum_comment(
  State(state): State<AppState>,
  headers: HeaderMap,
  Path(post_id): Path<i64>,
  Json(body): Json<NewCommentReq>,
) -> ApiResult<DemoForumComment> {
  let client = client_id(&headers)?;
  api_ok!(demo_service::forum_comment(&state.pool, &client, post_id, &body.content).await?)
}
