//! demo 演示端点——公开（不过 JWT）、内存态、给 website/demo 的 DPP
//! 演示页用。不做 OpenAPI 注解：这不是产品 API 面，是协议演示场。

use axum::Json;
use axum::extract::{Path, State};
use axum::http::HeaderMap;

use crate::api_ok;
use crate::errors::AppError;
use crate::types::{ApiResult, AppState};

use super::demo_model::{AddCartReq, DemoCartSnapshot, DemoOrder, DemoProduct};
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
pub async fn products(_state: State<AppState>) -> ApiResult<Vec<DemoProduct>> {
  api_ok!(demo_service::products())
}

/// GET /demo/cart
pub async fn cart_get(
  State(_state): State<AppState>,
  headers: HeaderMap,
) -> ApiResult<DemoCartSnapshot> {
  let client = client_id(&headers)?;
  api_ok!(demo_service::cart_get(&client).await)
}

/// POST /demo/cart/items {sku, qty?}
pub async fn cart_add(
  State(_state): State<AppState>,
  headers: HeaderMap,
  Json(body): Json<AddCartReq>,
) -> ApiResult<DemoCartSnapshot> {
  let client = client_id(&headers)?;
  let sku = body.sku.trim();
  if sku.is_empty() {
    return Err(AppError::Validation("sku 不能为空".into()));
  }
  api_ok!(demo_service::cart_add(&client, sku, body.qty.unwrap_or(1)).await?)
}

/// DELETE /demo/cart/items/:sku
pub async fn cart_remove(
  State(_state): State<AppState>,
  headers: HeaderMap,
  Path(sku): Path<String>,
) -> ApiResult<DemoCartSnapshot> {
  let client = client_id(&headers)?;
  api_ok!(demo_service::cart_remove(&client, &sku).await?)
}

/// POST /demo/orders —— 结算：购物车 → 订单，并清空购物车。
pub async fn checkout(State(_state): State<AppState>, headers: HeaderMap) -> ApiResult<DemoOrder> {
  let client = client_id(&headers)?;
  api_ok!(demo_service::checkout(&client).await?)
}

/// GET /demo/orders —— 当前访客的订单列表（新的在前）。
pub async fn orders_get(
  State(_state): State<AppState>,
  headers: HeaderMap,
) -> ApiResult<Vec<DemoOrder>> {
  let client = client_id(&headers)?;
  api_ok!(demo_service::orders_get(&client).await)
}
