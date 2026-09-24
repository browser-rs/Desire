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
  // 封禁用户(status=0)不能等 access token 自然过期:每次请求核对一次
  let status: i8 = sqlx::query_scalar("SELECT status FROM users WHERE id = ?")
    .bind(claims.sub)
    .fetch_optional(&state.pool)
    .await?
    .ok_or_else(|| AppError::Unauthorized("user no longer exists".into()))?;
  if status == 0 {
    return Err(AppError::Forbidden("account disabled".into()));
  }
  req.extensions_mut().insert(claims);
  Ok(next.run(req).await)
}
