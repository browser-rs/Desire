use axum::Json;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};

#[derive(Debug, thiserror::Error)]
pub enum AppError {
  #[error("unauthorized: {0}")]
  Unauthorized(String),
  #[error("forbidden: {0}")]
  Forbidden(String),
  #[error("not found: {0}")]
  NotFound(String),
  #[error("conflict: {0}")]
  Conflict(String),
  #[error("validation: {0}")]
  Validation(String),
  #[error(transparent)]
  Sql(sqlx::Error),
  #[error("internal: {0}")]
  Internal(String),
}

impl From<sqlx::Error> for AppError {
  /// 唯一键冲突(MySQL 1062)统一映射 409 并尽量透出约束名(不透出冲突值)。
  /// 并发注册/并发绑设备等竞态由这里兜底;其余数据库错误保持 Sql → 500,
  /// Display 可能带 SQL/表结构细节,只进日志不给客户端。
  fn from(e: sqlx::Error) -> Self {
    if let sqlx::Error::Database(db) = &e {
      if db.is_unique_violation() {
        // MySQL 消息形如: Duplicate entry 'x' for key 'uk_xxx'
        let constraint = db
          .message()
          .split("for key '")
          .nth(1)
          .and_then(|rest| rest.split('\'').next())
          .unwrap_or("unique key");
        return AppError::Conflict(format!("唯一键冲突({constraint})"));
      }
    }
    AppError::Sql(e)
  }
}

impl IntoResponse for AppError {
  fn into_response(self) -> Response {
    let (status, code) = match &self {
      AppError::Unauthorized(_) => (StatusCode::UNAUTHORIZED, 401),
      AppError::Forbidden(_) => (StatusCode::FORBIDDEN, 403),
      AppError::NotFound(_) => (StatusCode::NOT_FOUND, 404),
      AppError::Conflict(_) => (StatusCode::CONFLICT, 409),
      AppError::Validation(_) => (StatusCode::UNPROCESSABLE_ENTITY, 422),
      AppError::Sql(_) | AppError::Internal(_) => (StatusCode::INTERNAL_SERVER_ERROR, 500),
    };
    // Sql 错误的 Display 可能携带 SQL/表结构细节,只记日志不给客户端
    let message = match &self {
      AppError::Sql(_) => "服务器内部错误".to_string(),
      other => other.to_string(),
    };
    tracing::error!(error = %self, "request failed");
    (
      status,
      Json(serde_json::json!({"code": code, "message": message, "data": null})),
    )
      .into_response()
  }
}

#[cfg(test)]
mod tests {
  use super::AppError;

  #[test]
  fn error_variants_are_displayable() {
    let cases = [
      AppError::Unauthorized("bad token".into()),
      AppError::Forbidden("no access".into()),
      AppError::NotFound("user".into()),
      AppError::Conflict("phone".into()),
      AppError::Validation("bad field".into()),
      AppError::Internal("boom".into()),
    ];
    for e in cases {
      assert!(!e.to_string().is_empty());
    }
  }
}
