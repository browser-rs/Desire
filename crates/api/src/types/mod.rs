use serde::{Deserialize, Serialize};
use sqlx::MySqlPool;
use std::sync::Arc;

use crate::configs::Config;
use crate::utils::rate_limit::RateLimiter;

#[derive(Clone)]
pub struct AppState {
  pub pool: MySqlPool,
  pub config: Arc<Config>,
  /// 可选 Redis 缓存(None = 未配置,业务直连数据源;见 cache.rs)
  pub redis: Option<crate::cache::RedisConn>,
  /// 登录/注册限流(进程内滑动窗口;见 utils/rate_limit.rs)
  pub rate_limiter: Arc<RateLimiter>,
}

impl AppState {
  /// 认证类限流（v0.8.81 批 1）：配置了 Redis 就用共享计数器（多实例
  /// 一致），否则回退进程内滑动窗口。Redis 出错也回退，绝不因限流层挂业务。
  pub async fn allow_rate(&self, key: &str, limit: usize, window_secs: u64) -> bool {
    if let Some(conn) = &self.redis {
      let mut conn = conn.clone();
      let redis_key = format!("desire:rl:{key}");
      let script = "local c=redis.call('INCR',KEYS[1]);                     if c==1 then redis.call('EXPIRE',KEYS[1],ARGV[1]) end;                     return c";
      match redis::cmd("EVAL")
        .arg(script)
        .arg(1)
        .arg(&redis_key)
        .arg(window_secs)
        .query_async::<i64>(&mut conn)
        .await
      {
        Ok(count) => return count.max(0) as usize <= limit,
        Err(error) => {
          tracing::warn!("redis rate limit failed, falling back: {error}");
        }
      }
    }
    self
      .rate_limiter
      .allow(key, limit, std::time::Duration::from_secs(window_secs))
  }
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
