use sqlx::mysql::MySqlPoolOptions;

use crate::configs::Config;

pub async fn init(config: &Config) -> anyhow::Result<sqlx::MySqlPool> {
  // 会话时区固定 UTC:created_at/updated_at 一律存 UTC naive,
  // 不依赖服务器 SYSTEM 时区;CURRENT_TIMESTAMP 默认值也随之确定。
  let pool = MySqlPoolOptions::new()
    .after_connect(|conn, _| {
      Box::pin(async {
        sqlx::Executor::execute(conn, "SET time_zone = '+00:00'").await?;
        Ok(())
      })
    })
    .connect(&config.database_url)
    .await?;
  // 迁移只在 dev 自动跑;prod 由部署阶段统一执行 desire-migrate(改迁移不牵连本镜像)
  if desire_common::should_migrate_on_start(config.env == crate::configs::Env::Prod) {
    desire_common::migrate(&pool).await?;
  }
  Ok(pool)
}
