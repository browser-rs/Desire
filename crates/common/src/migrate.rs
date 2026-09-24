use sqlx::MySqlPool;
use std::path::Path;

/// 运行时从 migrations 目录加载并执行迁移。
/// 迁移 SQL 独立于二进制，改迁移文件无需重新编译。
/// 目录由环境变量 MIGRATIONS_DIR 指定，默认依次探测：
///   ./migrations、crates/common/migrations（workspace 根目录运行）
///
/// 模型：增量 `NNNN_name.sql`（sqlx 按版本序执行，每条只跑一次并记录在
/// `_sqlx_migrations`）。已应用的文件永不改动（sqlx 校验 SHA-384，
/// 改动会以 `migration N was previously applied but has been modified` 拒绝启动）；
/// schema 变更一律写新文件。
/// 本进程是否要自动跑迁移：默认 dev 自动跑（本地便利）；prod 不跑——
/// 迁移由部署阶段单独执行 `desire-migrate`（单点执行者，改迁移不牵连 api 镜像）。
/// 任何环境都可用 `DESIRE_MIGRATE_ON_START=1/0` 强制覆盖。
pub fn should_migrate_on_start(is_prod: bool) -> bool {
  match std::env::var("DESIRE_MIGRATE_ON_START") {
    Ok(v) => v == "1" || v.eq_ignore_ascii_case("true"),
    Err(_) => !is_prod,
  }
}

pub async fn migrate(pool: &MySqlPool) -> anyhow::Result<()> {
  let dir = resolve_migrations_dir();
  if !dir.exists() {
    // 业务镜像不打包 migrations（归 desire-migrate 执行器）:
    // - 显式 DESIRE_MIGRATE_ON_START=1 → 配置错误,大声失败
    // - dev 自动迁移 → 警告跳过,提示走 migrate 执行器
    if std::env::var("DESIRE_MIGRATE_ON_START").is_ok() {
      anyhow::bail!(
        "DESIRE_MIGRATE_ON_START 已开启但迁移目录不存在: {}(请用 desire-migrate 执行迁移)",
        dir.display()
      );
    }
    tracing::warn!(
      "迁移目录 {} 不存在,跳过自动迁移(请用 desire-migrate 执行迁移)",
      dir.display()
    );
    return Ok(());
  }
  let migrator = sqlx::migrate::Migrator::new(dir).await?;
  migrator.run(pool).await?;
  Ok(())
}

fn resolve_migrations_dir() -> std::path::PathBuf {
  if let Ok(dir) = std::env::var("MIGRATIONS_DIR") {
    if !dir.is_empty() {
      return dir.into();
    }
  }
  let candidates = [
    "migrations",
    "crates/common/migrations",
    "../crates/common/migrations",
  ];
  for c in candidates {
    if Path::new(c).exists() {
      return c.into();
    }
  }
  "migrations".into()
}

#[cfg(test)]
mod tests {
  use super::resolve_migrations_dir;
  use std::path::Path;

  #[test]
  fn finds_migrations_from_workspace_root() {
    let dir = resolve_migrations_dir();
    assert!(
      Path::new(&dir).exists(),
      "migrations dir not found: {dir:?}"
    );
  }
}
