//! demo 演示端点——公开（不过 JWT）、落 MySQL（部署是多实例 +
//! nginx 轮询无 sticky，演示态必须共享存储）、给 website/demo 的
//! DPP 演示页用。不做 OpenAPI 注解：这不是产品 API 面，是协议演示场。

use std::collections::HashMap;
use std::time::Duration;

use axum::Json;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use futures_util::StreamExt;
use tokio::sync::mpsc;

use crate::api_ok;
use crate::errors::AppError;
use crate::types::{ApiResult, AppState};

use super::demo_model::{
  AddCartReq, BookReq, DemoAdminPost, DemoArticlesPage, DemoBooking, DemoCartSnapshot,
  DemoForumComment, DemoForumPost, DemoImChannel, DemoImMessage, DemoOrder, DemoProduct,
  DemoSlotsResp, DemoStats, DemoWizardApp, HideReq, ImQuery, ImSendReq, LikeResult, NewCommentReq,
  NewPostReq, NewsQuery, SlotsQuery, WizardApplyReq,
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
  api_ok!(demo_service::im_send(&state, &client, body.channel.trim(), &body.content).await?)
}

/// WS /demo/im/ws?channel=&client= —— 下行即时通道（照 remote 的 im_ws
/// 模式，连接无状态可水平扩展）：每连接一条独立 Redis PubSub 订阅该
/// 访客频道，任意实例 im_send 皆可达；服务端 20s Ping 保活，入站 Ping
/// 显式回 Pong。未配置 Redis → PubSub 任务空转，客户端轮询兜底。
/// 业务写入仍走 REST POST /demo/im/messages，WS 只做下行。
pub async fn im_ws(
  ws: WebSocketUpgrade,
  State(state): State<AppState>,
  headers: HeaderMap,
  Query(params): Query<HashMap<String, String>>,
) -> Response {
  let _ = headers;
  let channel = params.get("channel").cloned().unwrap_or_default();
  let client = params.get("client").cloned().unwrap_or_default();
  if !demo_service::im_channel_ok(&channel) {
    return (StatusCode::BAD_REQUEST, "invalid channel").into_response();
  }
  if client.is_empty() || client.len() > 64 {
    return (StatusCode::BAD_REQUEST, "invalid client").into_response();
  }
  ws.on_upgrade(move |socket| handle_im_socket(socket, state, client, channel))
}

async fn handle_im_socket(mut socket: WebSocket, state: AppState, client: String, channel: String) {
  let topic = demo_service::im_ws_channel(&client, &channel);
  let (tx, mut rx) = mpsc::channel::<String>(64);

  // 每连接一条独立 PubSub（订阅模式与复用 ConnectionManager 互斥）；
  // 未配置 Redis → 空转等待，信道靠轮询兜底。
  let pubsub_task = {
    let redis_url = state.config.redis_url.clone();
    let tx = tx.clone();
    let topic = topic.clone();
    tokio::spawn(async move {
      if redis_url.is_empty() {
        std::future::pending::<()>().await;
        return;
      }
      let Ok(redis_client) = redis::Client::open(redis_url.as_str()) else {
        return;
      };
      let Ok(mut pubsub) = redis_client.get_async_pubsub().await else {
        return;
      };
      if pubsub.subscribe(topic).await.is_err() {
        return;
      }
      let mut msgs = pubsub.into_on_message();
      while let Some(msg) = msgs.next().await {
        let Ok(payload) = msg.get_payload::<String>() else {
          continue;
        };
        if tx.send(payload).await.is_err() {
          break;
        }
      }
    })
  };

  let mut ping = tokio::time::interval(Duration::from_secs(20));
  ping.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
  tracing::info!(channel = %channel, "demo im ws connected");
  loop {
    tokio::select! {
      outbound = rx.recv() => {
        let Some(text) = outbound else { break };
        if socket.send(Message::Text(text.into())).await.is_err() {
          break;
        }
      }
      _ = ping.tick() => {
        if socket.send(Message::Ping(vec![].into())).await.is_err() {
          break;
        }
      }
      inbound = socket.recv() => {
        match inbound {
          Some(Ok(Message::Ping(_))) => {
            let _ = socket.send(Message::Pong(vec![].into())).await;
          }
          Some(Ok(Message::Close(_))) | None => break,
          _ => {}
        }
      }
    }
  }
  drop(pubsub_task);
  tracing::info!(channel = %channel, "demo im ws disconnected");
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

// ── 预约演示 ──────────────────────────────────────────────

/// GET /demo/booking/slots?date=YYYY-MM-DD
pub async fn booking_slots(
  State(state): State<AppState>,
  Query(q): Query<SlotsQuery>,
) -> ApiResult<DemoSlotsResp> {
  api_ok!(demo_service::booking_slots(&state.pool, q.date.as_deref().unwrap_or("")).await?)
}

/// POST /demo/booking/book {date, slot, name} —— 双订吃唯一约束 → 409。
pub async fn booking_book(
  State(state): State<AppState>,
  headers: HeaderMap,
  Json(body): Json<BookReq>,
) -> ApiResult<DemoBooking> {
  let client = client_id(&headers)?;
  api_ok!(
    demo_service::booking_book(&state.pool, &client, &body.date, &body.slot, &body.name).await?
  )
}

/// GET /demo/booking/mine —— 我的预约。
pub async fn bookings_mine(
  State(state): State<AppState>,
  headers: HeaderMap,
) -> ApiResult<Vec<DemoBooking>> {
  let client = client_id(&headers)?;
  api_ok!(demo_service::bookings_mine(&state.pool, &client).await?)
}

// ── 资讯演示（合成内容） ─────────────────────────────────

/// GET /demo/news/articles?page=N —— 确定性合成、无表。
pub async fn news_articles(Query(q): Query<NewsQuery>) -> ApiResult<DemoArticlesPage> {
  api_ok!(demo_service::news_page(q.page.unwrap_or(1)))
}

// ── 看板演示（聚合） ─────────────────────────────────────

/// GET /demo/stats —— 聚合各 demo 表。
pub async fn stats(State(state): State<AppState>) -> ApiResult<DemoStats> {
  api_ok!(demo_service::stats(&state.pool).await?)
}

// ── 审核台演示 ────────────────────────────────────────────

/// GET /demo/admin/posts —— 全量（含已隐藏）。
pub async fn admin_posts(State(state): State<AppState>) -> ApiResult<Vec<DemoAdminPost>> {
  api_ok!(demo_service::admin_posts(&state.pool).await?)
}

/// POST /demo/admin/posts/{id}/hidden {hidden} —— 隐藏/恢复。
pub async fn admin_set_hidden(
  State(state): State<AppState>,
  Path(post_id): Path<i64>,
  Json(body): Json<HideReq>,
) -> ApiResult<()> {
  api_ok!(demo_service::admin_set_hidden(&state.pool, post_id, body.hidden).await?)
}

/// DELETE /demo/admin/posts/{id} —— 连同评论/点赞一并删除（danger 动作本体）。
pub async fn admin_delete_post(
  State(state): State<AppState>,
  Path(post_id): Path<i64>,
) -> ApiResult<()> {
  api_ok!(demo_service::admin_delete_post(&state.pool, post_id).await?)
}

// ── 入驻向导演示 ─────────────────────────────────────────

/// POST /demo/wizard/apply {shop, category, contact, phone}
pub async fn wizard_apply(
  State(state): State<AppState>,
  headers: HeaderMap,
  Json(body): Json<WizardApplyReq>,
) -> ApiResult<DemoWizardApp> {
  let client = client_id(&headers)?;
  api_ok!(
    demo_service::wizard_apply(
      &state.pool,
      &client,
      &body.shop,
      &body.category,
      &body.contact,
      &body.phone
    )
    .await?
  )
}

/// GET /demo/wizard/mine
pub async fn wizard_mine(
  State(state): State<AppState>,
  headers: HeaderMap,
) -> ApiResult<Vec<DemoWizardApp>> {
  let client = client_id(&headers)?;
  api_ok!(demo_service::wizard_mine(&state.pool, &client).await?)
}
