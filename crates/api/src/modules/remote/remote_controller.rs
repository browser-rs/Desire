use std::collections::HashMap;
use std::time::Duration;

use axum::Json;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Extension, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use futures_util::StreamExt;
use serde_json::{Value, json};
use tokio::sync::mpsc;

use crate::errors::AppError;
use crate::types::AppState;
use crate::utils::jwt::Claims;

use super::remote_model::{PairingClaimReq, PairingRevokeReq, PairingStartReq, PushFrameReq};
use super::remote_service::{self, Mailbox};

fn api_ok<T: serde::Serialize>(data: T) -> Response {
  Json(json!({"code": 0, "message": "ok", "data": data})).into_response()
}

fn api_err(err: AppError) -> Response {
  let (status, code, message) = match err {
    AppError::Validation(m) => (StatusCode::UNPROCESSABLE_ENTITY, 422, m),
    AppError::Unauthorized(m) => (StatusCode::UNAUTHORIZED, 401, m),
    AppError::Forbidden(m) => (StatusCode::FORBIDDEN, 403, m),
    other => (StatusCode::INTERNAL_SERVER_ERROR, 500, other.to_string()),
  };
  (
    status,
    Json(json!({"code": code, "message": message, "data": null})),
  )
    .into_response()
}

/// POST /remote/pairing/start —— desktop 端签发一次性配对码。
pub async fn pairing_start(
  State(state): State<AppState>,
  Extension(claims): Extension<Claims>,
  Json(body): Json<PairingStartReq>,
) -> Response {
  if body.desktop_device_id.trim().is_empty() || body.desktop_device_id.len() > 64 {
    return api_err(AppError::Validation(
      "desktop_device_id 须为 1-64 字符".into(),
    ));
  }
  if !state.rate_limiter.allow(
    &format!("remote-start-{}", claims.sub),
    20,
    std::time::Duration::from_secs(3600),
  ) {
    return api_err(AppError::Validation("配对码签发过于频繁".into()));
  }
  match remote_service::pairing_start(
    &state,
    claims.sub,
    &body.desktop_device_id,
    &body.desktop_name,
  )
  .await
  {
    Ok((code, expires_at)) => api_ok(json!({"code": code, "expiresAt": expires_at})),
    Err(e) => api_err(e),
  }
}

/// POST /remote/pairing/claim —— controller 端扫码后认领。
pub async fn pairing_claim(
  State(state): State<AppState>,
  Extension(claims): Extension<Claims>,
  Json(body): Json<PairingClaimReq>,
) -> Response {
  if !state.rate_limiter.allow(
    &format!("remote-claim-{}", claims.sub),
    30,
    std::time::Duration::from_secs(3600),
  ) {
    return api_err(AppError::Validation("尝试过于频繁".into()));
  }
  match remote_service::pairing_claim(&state, claims.sub, &body.code, &body.controller_name).await {
    Ok((device_id, desktop_name)) => {
      api_ok(json!({"desktopDeviceId": device_id, "desktopName": desktop_name}))
    }
    Err(e) => api_err(e),
  }
}

/// GET /remote/devices —— 该用户全部在效配对 + 在线状态(last_seen 戳,跨实例)。
pub async fn devices(
  State(state): State<AppState>,
  Extension(claims): Extension<Claims>,
) -> Response {
  match remote_service::list_devices(&state, claims.sub).await {
    Ok(list) => api_ok(json!({"devices": list})),
    Err(e) => api_err(e),
  }
}

/// POST /remote/pairing/revoke —— desktop 端吊销配对。
pub async fn pairing_revoke(
  State(state): State<AppState>,
  Extension(claims): Extension<Claims>,
  Json(body): Json<PairingRevokeReq>,
) -> Response {
  match remote_service::pairing_revoke(
    &state,
    claims.sub,
    &body.desktop_device_id,
    body.controller_name.as_deref(),
  )
  .await
  {
    Ok(n) => api_ok(json!({"revoked": n})),
    Err(e) => api_err(e),
  }
}

fn sender_mailbox(params: &HashMap<String, String>) -> Result<(Mailbox, String), Response> {
  let role = params.get("role").cloned().unwrap_or_default();
  let device_id = params.get("device").cloned().unwrap_or_default();
  if device_id.is_empty() || device_id.len() > 64 {
    return Err(api_err(AppError::Validation("invalid device".into())));
  }
  let Some(mailbox) = Mailbox::for_sender(&role) else {
    return Err((StatusCode::BAD_REQUEST, "invalid role").into_response());
  };
  Ok((mailbox, device_id))
}

fn receiver_mailbox(params: &HashMap<String, String>) -> Result<(Mailbox, String), Response> {
  let role = params.get("role").cloned().unwrap_or_default();
  let device_id = params.get("device").cloned().unwrap_or_default();
  if device_id.is_empty() || device_id.len() > 64 {
    return Err(api_err(AppError::Validation("invalid device".into())));
  }
  // pull 的 role = 收件方自己(桌面拉 desktop 信箱,控制器拉 controller 信箱)
  let Some(mailbox) = Mailbox::from_str(&role) else {
    return Err((StatusCode::BAD_REQUEST, "invalid role").into_response());
  };
  Ok((mailbox, device_id))
}

/// GET /remote/pull?role=<收件方角色>&device=<desktop_device_id>
/// 取走本端信箱帧(取走即删);桌面角色顺带盖在线戳。响应带 desktopOnline
/// (收件控制器判定 Mac 是否在线用)。
pub async fn pull_inbox(
  State(state): State<AppState>,
  Extension(claims): Extension<Claims>,
  Query(params): Query<HashMap<String, String>>,
) -> Response {
  let (mailbox, device_id) = match receiver_mailbox(&params) {
    Ok(v) => v,
    Err(resp) => return resp,
  };
  if !state.rate_limiter.allow(
    &format!("remote-pull-{}", claims.sub),
    150,
    std::time::Duration::from_secs(60),
  ) {
    return api_err(AppError::Validation("拉取过于频繁".into()));
  }
  match remote_service::inbox_take(&state, claims.sub, &device_id, mailbox).await {
    Ok(rows) => {
      let online = remote_service::desktop_online(&state, claims.sub, &device_id).await;
      let items: Vec<Value> = rows
        .iter()
        .map(|(id, payload)| json!({"id": id, "payload": payload}))
        .collect();
      api_ok(json!({"items": items, "desktopOnline": online}))
    }
    Err(e) => api_err(e),
  }
}

/// POST /remote/push?role=<发送方角色>&device=<desktop_device_id>
/// 发送业务帧(E2E 密文):入库(持久,离线可达) + Redis express 发布(尽力而为)。
/// 桌面发快照带 replace=true(新帧作废同信箱 pending 旧帧,离线堆积有界)。
pub async fn push_frame(
  State(state): State<AppState>,
  Extension(claims): Extension<Claims>,
  Query(params): Query<HashMap<String, String>>,
  Json(body): Json<PushFrameReq>,
) -> Response {
  let (mailbox, device_id) = match sender_mailbox(&params) {
    Ok(v) => v,
    Err(resp) => return resp,
  };
  if body.payload.is_empty() || body.payload.len() > remote_service::MAX_PAYLOAD_BYTES {
    return api_err(AppError::Validation("invalid payload".into()));
  }
  if !state.rate_limiter.allow(
    &format!("remote-push-{}", claims.sub),
    240,
    std::time::Duration::from_secs(60),
  ) {
    return api_err(AppError::Validation("推送过于频繁".into()));
  }
  if !remote_service::pairing_exists(&state, claims.sub, &device_id).await {
    return api_err(AppError::Forbidden("not paired".into()));
  }
  match remote_service::inbox_push(
    &state,
    claims.sub,
    &device_id,
    mailbox,
    &body.payload,
    body.replace,
  )
  .await
  {
    Ok(_) => api_ok(json!({"ok": true})),
    Err(e) => api_err(e),
  }
}

/// WS /remote/ws?role=&device= —— 下行订阅通道(照 Trove im_ws,连接无状态,
/// 可水平扩展):每连接一条独立 Redis PubSub 订阅本端频道,任意实例投递皆可达;
/// 服务端 20s Ping 保活(防 LB/网关空闲回收);客户端 Ping 显式回 Pong。
/// 业务帧一律走 REST push/pull,WS 不收发业务载荷。
/// 鉴权走 jwt_auth 中间件(Authorization 头,令牌不进 URL)。
pub async fn ws(
  ws: WebSocketUpgrade,
  State(state): State<AppState>,
  Extension(claims): Extension<Claims>,
  Query(params): Query<HashMap<String, String>>,
) -> Response {
  let role = params.get("role").cloned().unwrap_or_default();
  let device_id = params.get("device").cloned().unwrap_or_default();
  let Some(mailbox) = Mailbox::from_str(&role) else {
    return (StatusCode::BAD_REQUEST, "invalid role").into_response();
  };
  if device_id.is_empty() || device_id.len() > 64 {
    return (StatusCode::BAD_REQUEST, "invalid device").into_response();
  }
  if role == "controller" {
    // 未配对(或已吊销)的控制器在升级前就拒绝:零信息面
    if !remote_service::pairing_exists(&state, claims.sub, &device_id).await {
      return (StatusCode::FORBIDDEN, "not paired").into_response();
    }
  }
  ws.on_upgrade(move |socket| handle_socket(socket, state, claims.sub, mailbox, device_id))
}

async fn handle_socket(
  mut socket: WebSocket,
  state: AppState,
  user_id: i64,
  mailbox: Mailbox,
  device_id: String,
) {
  let channel = mailbox.channel(user_id, &device_id);
  let (tx, mut rx) = mpsc::channel::<String>(64);

  // Redis 订阅:每连接一条独立 PubSub(订阅模式与复用 ConnectionManager 互斥);
  // 多实例各自订阅同一频道,天然水平扩展。未配置 Redis → 任务空转,信道靠 pull 兜底。
  let pubsub_task = {
    let redis_url = state.config.redis_url.clone();
    let tx = tx.clone();
    let channel = channel.clone();
    tokio::spawn(async move {
      if redis_url.is_empty() {
        std::future::pending::<()>().await;
        return;
      }
      let Ok(client) = redis::Client::open(redis_url.as_str()) else {
        return;
      };
      let Ok(mut pubsub) = client.get_async_pubsub().await else {
        return;
      };
      if pubsub.subscribe(channel).await.is_err() {
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

  // 单任务 select:频道下行 + 20s Ping 保活 + 入站 Ping 显式回 Pong
  // (URLSession 客户端协议层回 pong 与否不可控,重复 Pong 对端忽略,合法)
  let mut ping = tokio::time::interval(Duration::from_secs(20));
  ping.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
  tracing::info!(user = user_id, mailbox = %mailbox.as_str(), device = %device_id, "remote ws connected");
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
  tracing::info!(user = user_id, mailbox = %mailbox.as_str(), device = %device_id, "remote ws disconnected");
}
