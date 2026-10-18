use axum::Json;
use axum::extract::{Extension, Path, Query, State};

use crate::api_ok;
use crate::errors::AppError;
use crate::types::{ApiResponse, ApiResult, AppState};
use crate::utils::jwt::Claims;

use super::sync_gc::{self, GcReport};
use super::sync_model::{
  KeyCheckBody, KeyCheckResp, SyncDeviceDto, SyncPullResp, SyncPushReq, SyncPushResp,
};
use super::sync_service;

/// 同步密钥指纹(E2E):客户端持有主密钥,服务端只存指纹用于导入校验。
/// GET 返回 None = 该账号还没有任何密文(第一台设备)。
#[utoipa::path(
  get, path = "/sync/key-check", tag = "sync",
  responses((status = 200))
)]
pub async fn key_check(
  State(state): State<AppState>,
  Extension(claims): Extension<Claims>,
) -> ApiResult<KeyCheckResp> {
  let check = sync_service::key_check_get(&state, claims.sub).await?;
  api_ok!(KeyCheckResp { check })
}

/// 上报密钥指纹。已有指纹且不同 → 409(拿错密钥,防止用新密钥把旧密文全量覆盖)。
#[utoipa::path(
  put, path = "/sync/key-check", tag = "sync",
  request_body = KeyCheckBody,
  responses((status = 200))
)]
pub async fn set_key_check(
  State(state): State<AppState>,
  Extension(claims): Extension<Claims>,
  Json(req): Json<KeyCheckBody>,
) -> ApiResult<()> {
  sync_service::key_check_set(&state, claims.sub, &req.check).await?;
  Ok(Json(ApiResponse::<()>::empty()))
}

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
    ("since" = Option<String>, Query, description = "上次拉取游标的时间部分(末条 updated_at);缺省 = 全量"),
    ("since_id" = Option<i64>, Query, description = "复合游标的行 id 部分;与 since 同传,消除同刻行跨页丢失"),
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
  let since_id = match q
    .get("since_id")
    .map(|s| s.trim())
    .filter(|s| !s.is_empty())
  {
    None => None,
    Some(raw) => Some(sync_service::parse_since_id(raw)?),
  };
  let device = q
    .get("device")
    .map(|s| s.trim().to_string())
    .filter(|s| !s.is_empty() && s.len() <= 64);
  let resp = sync_service::pull(&state, claims.sub, &domain, since, since_id).await?;
  // 设备游标记账(v0.7.20 tombstone GC 的依据;best-effort,失败不影响拉取)。
  if let Some(device) = device {
    sync_gc::record_pull_cursor(&state.pool, claims.sub, &domain, &device, since, since_id).await;
    sync_gc::maybe_gc_after_pull(&state.pool, claims.sub).await;
  }
  api_ok!(resp)
}

/// 设备面板（v0.7.23）：设备清单 + 各自拉取游标台账（只读、限自己）。
#[utoipa::path(
  get, path = "/sync/devices", tag = "sync",
  responses((status = 200, body = Vec<SyncDeviceDto>))
)]
pub async fn devices(
  State(state): State<AppState>,
  Extension(claims): Extension<Claims>,
) -> ApiResult<Vec<SyncDeviceDto>> {
  let rows = sync_service::devices(&state.pool, claims.sub).await?;
  api_ok!(rows)
}

/// 通用墓碑 GC(v0.7.20):回收"所有活跃设备都已越过 + 超过宽限期"的已删
/// 条目。只作用于当前用户自己的数据;`dry_run=true` 只数不删。
#[utoipa::path(
  post, path = "/sync/gc", tag = "sync",
  params(("dry_run" = Option<bool>, Query, description = "只统计不删除")),
  responses((status = 200, body = GcReport))
)]
pub async fn gc(
  State(state): State<AppState>,
  Extension(claims): Extension<Claims>,
  Query(q): Query<std::collections::HashMap<String, String>>,
) -> ApiResult<GcReport> {
  let dry_run = matches!(
    q.get("dry_run").map(|s| s.trim().to_lowercase()).as_deref(),
    Some("1") | Some("true") | Some("yes")
  );
  let report = sync_gc::gc_tombstones(&state.pool, claims.sub, dry_run)
    .await
    .map_err(|e| AppError::Internal(format!("sync gc failed: {e}")))?;
  api_ok!(report)
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
