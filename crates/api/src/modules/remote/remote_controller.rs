use axum::Json;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Extension, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use serde_json::{Value, json};

fn frame(v: Value) -> Message {
  Message::Text(v.to_string().into())
}
use tokio::sync::mpsc;

use crate::errors::AppError;
use crate::types::AppState;
use crate::utils::jwt::Claims;

use super::remote_model::{PairingClaimReq, PairingRevokeReq, PairingStartReq, WsFrame};
use super::remote_service::{self};

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

/// GET /remote/devices —— 该用户全部在效配对 + 在线状态。
pub async fn devices(
  State(state): State<AppState>,
  Extension(claims): Extension<Claims>,
) -> Response {
  match remote_service::list_devices(&state, claims.sub, &state.remote).await {
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

/// WS /remote/ws —— 中继通道。鉴权走 jwt_auth 中间件(Authorization 头,
/// URLSessionWebSocketTask 可带自定义头,令牌不进 URL/日志)。
pub async fn ws(
  ws: WebSocketUpgrade,
  State(state): State<AppState>,
  Extension(claims): Extension<Claims>,
  Query(params): Query<std::collections::HashMap<String, String>>,
) -> Response {
  let role = params.get("role").cloned().unwrap_or_default();
  let device_id = params.get("device").cloned().unwrap_or_default();
  if role != "desktop" && role != "controller" {
    return (StatusCode::BAD_REQUEST, "invalid role").into_response();
  }
  if device_id.is_empty() || device_id.len() > 64 {
    return (StatusCode::BAD_REQUEST, "invalid device").into_response();
  }
  if role == "controller" {
    // 未配对(或已吊销)的控制器在升级前就拒绝:零信息面
    let paired = sqlx::query_scalar::<_, i64>(
      "SELECT COUNT(*) FROM remote_pairings \
       WHERE user_id = ? AND desktop_device_id = ? AND claimed_at IS NOT NULL AND revoked_at IS NULL",
    )
    .bind(claims.sub)
    .bind(&device_id)
    .fetch_one(&state.pool)
    .await
    .unwrap_or(0);
    if paired == 0 {
      return (StatusCode::FORBIDDEN, "not paired").into_response();
    }
  }
  ws.on_upgrade(move |socket| handle_socket(socket, state, claims.sub, role, device_id))
}

async fn handle_socket(
  mut socket: WebSocket,
  state: AppState,
  user_id: i64,
  role: String,
  device_id: String,
) {
  let (tx, mut rx) = mpsc::channel::<Message>(64);
  let registered = if role == "desktop" {
    state
      .remote
      .insert_desktop(user_id, &device_id, tx.clone())
      .await
  } else {
    state
      .remote
      .insert_controller(user_id, &device_id, tx.clone())
      .await
  };
  if registered.is_err() {
    let _ = socket
      .send(frame(json!({"kind":"closed","reason":"connection limit"})))
      .await;
    return;
  }
  tracing::info!(user = user_id, role = %role, device = %device_id, "remote ws connected");

  // 桌面连上即投递离线留言(密文原样,至多一次延迟、确认前保留)
  if role == "desktop" {
    if let Ok(pending) = remote_service::inbox_pending(&state, user_id, &device_id).await {
      if !pending.is_empty() {
        let items: Vec<Value> = pending
          .iter()
          .map(|(id, payload)| json!({"id": id, "payload": payload}))
          .collect();
        let _ = tx.send(frame(json!({"kind":"inbox","items":items}))).await;
      }
    }
  }

  // 单任务 select:信箱出站 + socket 入站互不阻塞(不依赖 futures::split)
  loop {
    tokio::select! {
      outbound = rx.recv() => {
        let Some(msg) = outbound else { break };
        if socket.send(msg).await.is_err() { break; }
      }
      inbound = socket.recv() => {
        let Some(Ok(msg)) = inbound else { break };
        let Message::Text(text) = msg else { continue };
        let Ok(incoming) = serde_json::from_str::<WsFrame>(&text) else {
          tracing::info!(user = user_id, role = %role, "ws frame parse failed: {}", &text[..text.len().min(120)]);
          continue;
        };
        match incoming.kind.as_str() {
          "ping" => {
            let _ = tx.send(frame(json!({"kind":"pong"}))).await;
          }
          "ack" => {
            let _ = remote_service::inbox_ack(&state, &incoming.ids, user_id).await;
          }
          "route" => {
            let Some(payload) = incoming.payload else { continue };
            if payload.len() > remote_service::MAX_PAYLOAD_BYTES {
              continue;
            }
            if role == "controller" {
              let delivered = state
                .remote
                .forward_to_desktop(user_id, &device_id, Message::Text(payload.clone().into()))
                .await;
              tracing::info!(user = user_id, device = %device_id, delivered, "route controller→desktop");
              if !delivered && incoming.deliver_if_offline {
                let _ =
                  remote_service::inbox_push(&state, user_id, &device_id, &payload).await;
              }
            } else {
              tracing::info!(user = user_id, device = %device_id, "route desktop→controllers");
              // desktop → 全部控制器广播(控制器数量小,v1 不做定向);包同一信封
              let envelope = json!({"kind": "route", "payload": payload});
              let _ = state
                .remote
                .broadcast_to_controllers(
                  user_id, &device_id, Message::Text(envelope.to_string().into()))
                .await;
            }
          }
          _ => {}
        }
      }
    }
  }

  // 断开清理
  if role == "desktop" {
    state.remote.remove_desktop(user_id, &device_id, &tx).await;
  } else {
    state
      .remote
      .remove_controller(user_id, &device_id, &tx)
      .await;
  }
  tracing::info!(user = user_id, role = %role, device = %device_id, "remote ws disconnected");
}
