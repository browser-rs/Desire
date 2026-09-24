use serde::{Deserialize, Serialize};
use sqlx::MySqlPool;
use std::sync::Arc;

use crate::configs::Config;

#[derive(Clone)]
pub struct AppState {
  pub pool: MySqlPool,
  pub config: Arc<Config>,
  /// 可选 Redis 缓存(None = 未配置,业务直连数据源;见 cache.rs)
  pub redis: Option<crate::cache::RedisConn>,
}

#[derive(Debug, Serialize)]
pub struct ApiResponse<T> {
  pub code: i32,
  pub message: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub data: Option<T>,
}

/// handler 统一返回类型别名
pub type ApiResult<T> = Result<axum::Json<ApiResponse<T>>, crate::errors::AppError>;

/// 包装 `Ok(Json(ApiResponse::ok(expr)))`
#[macro_export]
macro_rules! api_ok {
  ($expr:expr) => {
    Ok(axum::Json($crate::types::ApiResponse::ok($expr)))
  };
}

impl<T> ApiResponse<T> {
  pub fn ok(data: T) -> Self {
    ApiResponse {
      code: 0,
      message: "ok".into(),
      data: Some(data),
    }
  }

  pub fn empty() -> ApiResponse<()> {
    ApiResponse {
      code: 0,
      message: "ok".into(),
      data: None,
    }
  }
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct PageQuery {
  pub page: Option<u32>,
  pub page_size: Option<u32>,
}

impl PageQuery {
  pub fn page(&self) -> u32 {
    // 上限防 offset 乘法溢出(?page=400000000&page_size=100)
    self.page.unwrap_or(1).clamp(1, 100_000)
  }

  pub fn page_size(&self) -> u32 {
    self.page_size.unwrap_or(20).clamp(1, 100)
  }

  pub fn offset(&self) -> u32 {
    (self.page() - 1) * self.page_size()
  }
}
