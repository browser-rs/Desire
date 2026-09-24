//! 迁移执行器(desire-migrate):部署阶段对数据库跑一次迁移后退出。
//! 与业务服务解耦——改迁移只需重建本二进制,api 在 prod 不再自动跑迁移
//! (见 desire_common::should_migrate_on_start)。
//!
//! 用法:`DATABASE_URL=mysql://... cargo run -q -p desire-common --bin desire-migrate`
//! (可选 `MIGRATIONS_DIR` 覆盖迁移目录)

use anyhow::Context;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
  let url = std::env::var("DATABASE_URL").context("DATABASE_URL is required")?;
  let pool = sqlx::MySqlPool::connect(&url).await?;
  desire_common::migrate(&pool).await?;
  println!("migrations ok: db schema is up to date");
  Ok(())
}
