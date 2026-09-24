use axum::Json;
use axum::extract::{Extension, Path, Query, State};

use crate::api_ok;
use crate::errors::AppError;
use crate::types::{ApiResult, AppState};
use crate::utils::jwt::Claims;

use super::sync_model::{SyncPullResp, SyncPushReq, SyncPushResp};
use super::sync_service;

/// 域白名单校验(controller 层统一做,service 不再重复)
fn ensure_domain(domain: &str) -> Result<(), AppError> {
  if super::sync_model::is_valid_domain(domain) {
    Ok(())
  } else {
    Err(AppError::NotFound(format!(
      "unknown sync domain '{domain}'"
    )))
  }
}

#[utoipa::path(
  get, path = "/sync/{domain}", tag = "sync",
  params(
    ("domain" = String, Path, description = "bookmarks/quickdials/reading_list/keyboard_shortcuts/settings"),
    ("since" = Option<String>, Query, description = "上次拉取的游标(末条 updated_at);缺省 = 全量"),
  ),
  responses((status = 200, body = SyncPullResp))
)]
pub async fn pull(
  State(state): State<AppState>,
  Extension(claims): Extension<Claims>,
  Path(domain): Path<String>,
  Query(q): Query<std::collections::HashMap<String, String>>,
) -> ApiResult<SyncPullResp> {
  ensure_domain(&domain)?;
  let since = match q.get("since").map(|s| s.trim()).filter(|s| !s.is_empty()) {
    None => None,
    Some(raw) => Some(sync_service::parse_since(raw)?),
  };
  let resp = sync_service::pull(&state, claims.sub, &domain, since).await?;
  api_ok!(resp)
}

#[utoipa::path(
  post, path = "/sync/{domain}", tag = "sync",
  request_body = SyncPushReq,
  params(("domain" = String, Path)),
  responses((status = 200, body = SyncPushResp))
)]
pub async fn push(
  State(state): State<AppState>,
  Extension(claims): Extension<Claims>,
  Path(domain): Path<String>,
  Json(req): Json<SyncPushReq>,
) -> ApiResult<SyncPushResp> {
  ensure_domain(&domain)?;
  let resp = sync_service::push(&state, claims.sub, &domain, req.items).await?;
  api_ok!(resp)
}
