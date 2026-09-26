use std::sync::Arc;

use desire_api::cache;
use desire_api::configs::{Config, Env};
use desire_api::db;
use desire_api::routes::build_router;
use desire_api::types::AppState;
use desire_api::utils::rate_limit::RateLimiter;
use tracing_subscriber::EnvFilter;

fn init_logging(env: Env) {
  match env {
    Env::Dev => {
      tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive(tracing::Level::DEBUG.into()))
        .init();
    }
    Env::Prod => {
      tracing_subscriber::fmt()
        .json()
        .with_env_filter(EnvFilter::from_default_env().add_directive(tracing::Level::INFO.into()))
        .init();
    }
  }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
  // 本地开发读合并的 .env(不存在则跳过);部署用系统环境变量 / --env-file
  let _ = dotenvy::dotenv();
  let config = Config::from_env()?;
  init_logging(config.env);
  let pool = db::init(&config).await?;
  // 可选 Redis 缓存:未配置 = None(降级直连 DB);配置了但连不上也降级启动
  let redis = if config.redis_url.is_empty() {
    None
  } else {
    cache::connect(&config.redis_url).await
  };
  let app = build_router(AppState {
    pool,
    config: Arc::new(config.clone()),
    redis,
    rate_limiter: Arc::new(RateLimiter::default()),
    remote: Arc::new(desire_api::modules::remote::remote_service::RemoteRegistry::default()),
  });
  let listener = tokio::net::TcpListener::bind(&config.bind_addr).await?;
  tracing::info!("env={:?} api listening on {}", config.env, config.bind_addr);
  axum::serve(listener, app).await?;
  Ok(())
}
