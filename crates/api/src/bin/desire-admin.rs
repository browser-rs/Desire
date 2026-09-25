//! 运维管理 CLI(desire-admin):账号与注册开关的命令行入口。
//! 与业务服务共用同一个数据库;只动数据,不启服务。
//!
//! 用法(DATABASE_URL 必填,可用 .env):
//!   desire-admin user list
//!   desire-admin user reset-password <username> <new-password>
//!   desire-admin user delete <username>          # 级联清同步数据/设备/令牌
//!   desire-admin user disable <username>         # 禁止登录,已有令牌全部失效
//!   desire-admin user enable <username>
//!   desire-admin registration status|on|off      # 注册开关(env 显式设置时优先)
//!   desire-admin stats                           # 用户数/各域同步行数

use anyhow::{Context, bail};
use sqlx::mysql::MySqlPool;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
  let _ = dotenvy::dotenv();
  let args: Vec<String> = std::env::args().skip(1).collect();
  let args: Vec<&str> = args.iter().map(String::as_str).collect();
  let pool = MySqlPool::connect(&db_url()?).await?;

  match args.as_slice() {
    ["user", "list"] => user_list(&pool).await?,
    ["user", "reset-password", username, password] => {
      user_reset_password(&pool, username, password).await?
    }
    ["user", "delete", username] => user_delete(&pool, username).await?,
    ["user", "disable", username] => user_set_status(&pool, username, 0).await?,
    ["user", "enable", username] => user_set_status(&pool, username, 1).await?,
    ["registration", "status"] => registration_status(&pool).await?,
    ["registration", "on"] => registration_set(&pool, true).await?,
    ["registration", "off"] => registration_set(&pool, false).await?,
    ["stats"] => stats(&pool).await?,
    _ => {
      eprint!("{}", USAGE);
      std::process::exit(2);
    }
  }
  pool.close().await;
  Ok(())
}

static USAGE: &str = "\
用法: desire-admin <命令>

命令:
  user list
  user reset-password <username> <new-password>   # 重置并吊销全部刷新令牌
  user delete <username>                          # 级联删除账号及全部同步数据
  user disable <username>                         # 禁止登录,已有令牌全部失效
  user enable <username>
  registration status | on | off                  # 注册开关
  stats                                           # 用户数 / 各域同步行数
";

fn db_url() -> anyhow::Result<String> {
  std::env::var("DATABASE_URL").context("DATABASE_URL is required")
}

fn env_registration_override() -> Option<bool> {
  let raw = std::env::var("DESIRE_API_ALLOW_REGISTRATION").ok()?;
  Some(matches!(raw.to_lowercase().as_str(), "1" | "true" | "yes"))
}

/// 注册开关的**生效值**:env 显式设置 > DB(缺省开放)。
async fn registration_effective(pool: &MySqlPool) -> anyhow::Result<(bool, &'static str)> {
  if let Some(v) = env_registration_override() {
    return Ok((v, "env"));
  }
  let value: Option<String> =
    sqlx::query_scalar("SELECT `value` FROM server_settings WHERE `key` = 'allow_registration'")
      .fetch_optional(pool)
      .await?
      .flatten();
  match value {
    Some(v) => Ok((v != "0", "db")),
    None => Ok((true, "default")),
  }
}

async fn user_exists(pool: &MySqlPool, username: &str) -> anyhow::Result<Option<i64>> {
  Ok(
    sqlx::query_scalar("SELECT id FROM users WHERE username = ?")
      .bind(username)
      .fetch_optional(pool)
      .await?,
  )
}

async fn user_list(pool: &MySqlPool) -> anyhow::Result<()> {
  let rows = sqlx::query_as::<
    _,
    (
      i64,
      String,
      Option<String>,
      i8,
      Option<chrono::NaiveDateTime>,
    ),
  >("SELECT id, username, email, status, last_login_at FROM users ORDER BY id")
  .fetch_all(pool)
  .await?;
  if rows.is_empty() {
    println!("(无用户)");
    return Ok(());
  }
  println!(
    "{:>4}  {:<20} {:<24} {:<6} {}",
    "id", "username", "email", "状态", "最后登录"
  );
  for (id, username, email, status, last_login) in rows {
    println!(
      "{:>4}  {:<20} {:<24} {:<6} {}",
      id,
      username,
      email.unwrap_or_default(),
      if status == 1 { "正常" } else { "已禁用" },
      last_login
        .map(|t| t.format("%Y-%m-%d %H:%M").to_string())
        .unwrap_or_else(|| "从未".into()),
    );
  }
  Ok(())
}

async fn user_reset_password(
  pool: &MySqlPool,
  username: &str,
  password: &str,
) -> anyhow::Result<()> {
  if !(8..=72).contains(&password.len()) {
    bail!("密码须为 8-72 位,且同时包含字母和数字");
  }
  let has_letter = password.bytes().any(|b| b.is_ascii_alphabetic());
  let has_digit = password.bytes().any(|b| b.is_ascii_digit());
  if !has_letter || !has_digit {
    bail!("密码须同时包含字母和数字");
  }
  let Some(user_id) = user_exists(pool, username).await? else {
    bail!("用户不存在: {username}");
  };
  let hash = bcrypt::hash(password, 10).context("bcrypt hash failed")?;
  let now = chrono::Utc::now().naive_utc();
  let mut tx = pool.begin().await?;
  sqlx::query("UPDATE users SET password_hash = ?, updated_at = ? WHERE id = ?")
    .bind(&hash)
    .bind(now)
    .bind(user_id)
    .execute(&mut *tx)
    .await?;
  // 重置密码即踢下线:全部未撤销的刷新令牌作废
  sqlx::query(
    "UPDATE user_refresh_tokens SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL",
  )
  .bind(now)
  .bind(user_id)
  .execute(&mut *tx)
  .await?;
  tx.commit().await?;
  println!("已重置 {username} 的密码,并吊销其全部刷新令牌(已登录设备 access 过期后需重新登录)");
  Ok(())
}

async fn user_delete(pool: &MySqlPool, username: &str) -> anyhow::Result<()> {
  let Some(user_id) = user_exists(pool, username).await? else {
    bail!("用户不存在: {username}");
  };
  // FK 级联:devices / user_refresh_tokens / sync_items 随之删除
  let result = sqlx::query("DELETE FROM users WHERE id = ?")
    .bind(user_id)
    .execute(pool)
    .await?;
  println!(
    "已删除 {username}(id={user_id}),级联清理 {} 条关联数据",
    result.rows_affected()
  );
  Ok(())
}

async fn user_set_status(pool: &MySqlPool, username: &str, status: i8) -> anyhow::Result<()> {
  let Some(user_id) = user_exists(pool, username).await? else {
    bail!("用户不存在: {username}");
  };
  sqlx::query("UPDATE users SET status = ?, updated_at = ? WHERE id = ?")
    .bind(status)
    .bind(chrono::Utc::now().naive_utc())
    .bind(user_id)
    .execute(pool)
    .await?;
  if status == 0 {
    // 禁用即踢下线
    let now = chrono::Utc::now().naive_utc();
    sqlx::query(
      "UPDATE user_refresh_tokens SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL",
    )
    .bind(now)
    .bind(user_id)
    .execute(pool)
    .await?;
  }
  println!("已{} {username}", if status == 0 { "禁用" } else { "启用" });
  Ok(())
}

async fn registration_status(pool: &MySqlPool) -> anyhow::Result<()> {
  let (allowed, source) = registration_effective(pool).await?;
  let db_value: Option<String> =
    sqlx::query_scalar("SELECT `value` FROM server_settings WHERE `key` = 'allow_registration'")
      .fetch_optional(pool)
      .await?
      .flatten();
  println!(
    "注册当前{}(来源: {source};DB 值: {})",
    if allowed { "开放" } else { "关闭" },
    db_value.unwrap_or_else(|| "(未设置)".into()),
  );
  if env_registration_override().is_some() {
    println!("注意: DESIRE_API_ALLOW_REGISTRATION 环境变量已设置,优先于 DB 值。");
  }
  Ok(())
}

async fn registration_set(pool: &MySqlPool, allowed: bool) -> anyhow::Result<()> {
  if env_registration_override().is_some() {
    bail!("DESIRE_API_ALLOW_REGISTRATION 环境变量已设置,其优先级高于本命令——请先移除该变量");
  }
  let value = if allowed { "1" } else { "0" };
  sqlx::query(
    "INSERT INTO server_settings (`key`, `value`) VALUES ('allow_registration', ?) \
         ON DUPLICATE KEY UPDATE `value` = VALUES(`value`)",
  )
  .bind(value)
  .execute(pool)
  .await?;
  println!("注册已{}", if allowed { "开放" } else { "关闭" });
  Ok(())
}

async fn stats(pool: &MySqlPool) -> anyhow::Result<()> {
  let users: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM users")
    .fetch_one(pool)
    .await?;
  println!("用户数: {users}");
  let rows = sqlx::query_as::<_, (String, i64, i64)>(
        "SELECT domain, COUNT(*), SUM(deleted_at IS NOT NULL) FROM sync_items GROUP BY domain ORDER BY domain",
    )
    .fetch_all(pool)
    .await?;
  if rows.is_empty() {
    println!("同步数据: (空)");
    return Ok(());
  }
  println!("{:<20} {:>8} {:>10}", "domain", "rows", "tombstones");
  for (domain, rows_, tombstones) in rows {
    println!("{:<20} {:>8} {:>10}", domain, rows_, tombstones);
  }
  Ok(())
}
