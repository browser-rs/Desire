use axum::extract::{Request, State};
use axum::http::header::AUTHORIZATION;
use axum::middleware::Next;
use axum::response::Response;

use crate::errors::AppError;
use crate::types::AppState;
use crate::utils::jwt::{self, Claims};

pub async fn jwt_auth(
  State(state): State<AppState>,
  mut req: Request,
  next: Next,
) -> Result<Response, AppError> {
  let token = req
    .headers()
    .get(AUTHORIZATION)
    .and_then(|v| v.to_str().ok())
    .and_then(|v| v.strip_prefix("Bearer "))
    .ok_or_else(|| AppError::Unauthorized("missing bearer token".into()))?;
  let claims: Claims = jwt::parse_token(token, &state.config.jwt_secret)?;
  // 封禁用户与 token 版本：每次请求核对（v0.8.80 批 7）——改密/全设备吊销
  // 会 +1 用户版本，logout/单设备吊销会 +1 设备版本，旧 access token 立即失效。
  let (status, user_version): (i8, i64) =
    sqlx::query_as("SELECT status, token_version FROM users WHERE id = ?")
      .bind(claims.sub)
      .fetch_optional(&state.pool)
      .await?
      .ok_or_else(|| AppError::Unauthorized("user no longer exists".into()))?;
  if status == 0 {
    return Err(AppError::Forbidden("account disabled".into()));
  }
  if !session_versions_valid(claims.ver, user_version, None) {
    return Err(AppError::Unauthorized("session revoked".into()));
  }
  if let Some(device_row_id) = claims.dev {
    let row: Option<(i64, Option<chrono::NaiveDateTime>)> =
      sqlx::query_as("SELECT token_version, revoked_at FROM devices WHERE id = ? AND user_id = ?")
        .bind(device_row_id)
        .bind(claims.sub)
        .fetch_optional(&state.pool)
        .await?;
    let Some((device_version, revoked_at)) = row else {
      return Err(AppError::Unauthorized("device removed".into()));
    };
    if !session_versions_valid(
      claims.ver,
      user_version,
      Some((claims.dver, device_version, revoked_at.is_some())),
    ) {
      return Err(AppError::Unauthorized("device session revoked".into()));
    }
  }
  // 访问日志带 user id（v0.8.80 批 7）：request_context 在外层拿不到 claims，
  // 这里补一条关联行，排障时按 request_id + user_id 串起来。
  tracing::info!(user_id = claims.sub, device = ?claims.dev, "authenticated");
  req.extensions_mut().insert(claims);
  Ok(next.run(req).await)
}

/// 会话版本判定（v0.8.80 批 7，纯逻辑便于单测）：用户版本必须一致；
/// 设备三元组存在时设备版本必须一致且未吊销。
fn session_versions_valid(
  claim_user_version: i64,
  current_user_version: i64,
  device: Option<(i64, i64, bool)>,
) -> bool {
  if claim_user_version != current_user_version {
    return false;
  }
  match device {
    Some((claim_device_version, current_device_version, revoked)) => {
      !revoked && claim_device_version == current_device_version
    }
    None => true,
  }
}

#[cfg(test)]
mod tests {
  use super::session_versions_valid;

  #[test]
  fn session_versions_revoke_immediately() {
    assert!(session_versions_valid(0, 0, None));
    assert!(!session_versions_valid(0, 1, None));
    assert!(session_versions_valid(0, 0, Some((2, 2, false))));
    assert!(!session_versions_valid(0, 0, Some((2, 3, false))));
    assert!(!session_versions_valid(0, 0, Some((2, 2, true))));
  }
}
