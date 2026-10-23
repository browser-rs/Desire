use std::time::Duration;

use axum::Json;
use axum::extract::{Query, State};
use axum::http::HeaderMap;

use crate::api_ok;
use crate::errors::AppError;
use crate::types::{ApiResult, AppState};

use super::growth_model::{GrowthEventReq, GrowthSummary};
use super::growth_service;

fn client_ip(headers: &HeaderMap) -> String {
  headers
    .get("x-forwarded-for")
    .and_then(|v| v.to_str().ok())
    .unwrap_or("")
    .chars()
    .take(45)
    .collect()
}

/// POST /growth/event —— 公开、匿名、限流。产品页 beacon 与 App 首启都打这里。
#[utoipa::path(
  post, path = "/growth/event", tag = "growth",
  request_body = GrowthEventReq,
  responses((status = 200), (status = 429))
)]
pub async fn event(
  State(state): State<AppState>,
  headers: HeaderMap,
  Json(req): Json<GrowthEventReq>,
) -> ApiResult<()> {
  let ip = client_ip(&headers);
  if !state
    .rate_limiter
    .allow(&format!("growth-ip:{ip}"), 120, Duration::from_secs(60))
  {
    return Err(AppError::RateLimited("too many growth events".into()));
  }
  growth_service::record_event(&state.pool, req).await?;
  api_ok!(())
}

/// GET /growth/summary?days=30 —— 登录态可读的匿名聚合（单实例/单 owner 部署）。
#[utoipa::path(
  get, path = "/growth/summary", tag = "growth",
  params(("days" = Option<u32>, Query, description = "1..180，默认 30")),
  responses((status = 200, body = GrowthSummary))
)]
pub async fn summary(
  State(state): State<AppState>,
  Query(q): Query<std::collections::HashMap<String, String>>,
) -> ApiResult<GrowthSummary> {
  let days = q
    .get("days")
    .and_then(|v| v.trim().parse::<u32>().ok())
    .unwrap_or(30);
  let summary = growth_service::summary(&state.pool, days).await?;
  api_ok!(summary)
}
