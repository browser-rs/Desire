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
//!   desire-admin sync gc [--dry-run]             # 通用墓碑 GC(全量用户)
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
    ["user", "create", username, password] => user_create(&pool, username, password, None).await?,
    ["user", "create", username, password, nickname] => {
      user_create(&pool, username, password, Some(nickname)).await?
    }
    ["user", "audit", username] => user_audit(&pool, username).await?,
    ["user", "usage", username] => user_usage(&pool, username).await?,
    ["user", "delete", username] => user_delete(&pool, username).await?,
    ["user", "disable", username] => user_set_status(&pool, username, 0).await?,
    ["user", "enable", username] => user_set_status(&pool, username, 1).await?,
    ["sync", "gc"] => sync_gc_cmd(&pool, false).await?,
    ["sync", "gc", "--dry-run"] => sync_gc_cmd(&pool, true).await?,
    ["device", "list", username] => device_list(&pool, username).await?,
    ["device", "revoke", username, device_id] => device_revoke(&pool, username, device_id).await?,
    ["remote", "inbox", username] => remote_inbox(&pool, username, false).await?,
    ["remote", "inbox", username, "--purge"] => remote_inbox(&pool, username, true).await?,
    ["remote", "stats", username] => remote_stats(&pool, username).await?,
    ["remote", "cleanup", username] => remote_cleanup(&pool, username, 30, false).await?,
    ["remote", "cleanup", username, "--days", days] => {
      let n: u64 = days
        .parse()
        .map_err(|_| anyhow::anyhow!("--days 需要数字"))?;
      remote_cleanup(&pool, username, n, false).await?
    }
    ["remote", "cleanup", username, "--apply"] => remote_cleanup(&pool, username, 30, true).await?,
    ["remote", "cleanup", username, "--days", days, "--apply"] => {
      let n: u64 = days
        .parse()
        .map_err(|_| anyhow::anyhow!("--days 需要数字"))?;
      remote_cleanup(&pool, username, n, true).await?
    }
    ["registration", "status"] => registration_status(&pool).await?,
    ["registration", "on"] => registration_set(&pool, true).await?,
    ["registration", "off"] => registration_set(&pool, false).await?,
    ["prune"] => prune(&pool, 90, false).await?,
    ["prune", "--days", days] => {
      let n: i64 = days
        .parse()
        .map_err(|_| anyhow::anyhow!("--days 需要数字"))?;
      prune(&pool, n, false).await?
    }
    ["prune", "--apply"] => prune(&pool, 90, true).await?,
    ["prune", "--days", days, "--apply"] => {
      let n: i64 = days
        .parse()
        .map_err(|_| anyhow::anyhow!("--days 需要数字"))?;
      prune(&pool, n, true).await?
    }
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
  user create <username> <password> [nickname]     # 管理员开号(绕过注册验证码)
  user audit <username>                            # 最近 50 条账号安全审计
  user usage <username>                            # 同步用量(今日/最近 7 天)
  user reset-password <username> <new-password>   # 重置并吊销全部刷新令牌
  user delete <username>                          # 级联删除账号及全部同步数据
  user disable <username>                         # 禁止登录,已有令牌全部失效
  user enable <username>
  registration status | on | off                  # 注册开关
  sync gc [--dry-run]                             # 通用墓碑 GC(按设备游标)
  remote inbox <username> [--purge]               # 看远端信箱(--purge 清未投递)
  remote stats <username>                         # 配对设备/在线状态/信箱计数
  remote cleanup <username> [--days N] [--apply]  # 清已投递信箱与过期配对(默认30天,dry-run)
  device list <username>                          # 该用户全部设备(含撤销态)
  device revoke <username> <device_id>            # 撤销设备(联动吊销其刷新令牌)
  prune [--days N] [--apply]                      # 修剪 growth_events/sync_usage/审计(默认90天,dry-run)
  stats                                           # 用户数 / 各域同步行数
";

async fn user_create(
  pool: &MySqlPool,
  username: &str,
  password: &str,
  nickname: Option<&str>,
) -> anyhow::Result<()> {
  let username = username.trim();
  if !desire_api::modules::auth::auth_service::is_valid_username(username) {
    bail!("invalid username (3-32 chars, letter first)");
  }
  if password.len() < 8 || password.len() > 72 {
    bail!("password must be 8-72 bytes");
  }
  if !password.chars().any(|c| c.is_ascii_alphabetic())
    || !password.chars().any(|c| c.is_ascii_digit())
  {
    bail!("password must contain letters and digits");
  }
  let hash = bcrypt::hash(password, 10)?;
  let nickname = nickname
    .unwrap_or(username)
    .chars()
    .take(64)
    .collect::<String>();
  let result = sqlx::query(
    "INSERT INTO users (username, password_hash, nickname, status) VALUES (?, ?, ?, 1)",
  )
  .bind(username)
  .bind(hash)
  .bind(nickname)
  .execute(pool)
  .await;
  match result {
    Ok(res) => println!("created user {username} (id {})", res.last_insert_id()),
    Err(error) if error.to_string().contains("Duplicate") => bail!("username already exists"),
    Err(error) => return Err(error.into()),
  }
  Ok(())
}

async fn user_audit(pool: &MySqlPool, username: &str) -> anyhow::Result<()> {
  let id = require_user(pool, username).await?;
  let rows: Vec<(i64, String, String, String, chrono::NaiveDateTime)> = sqlx::query_as(
    "SELECT id, event, detail, ip, created_at FROM audit_events      WHERE user_id = ? ORDER BY id DESC LIMIT 50",
  )
  .bind(id)
  .fetch_all(pool)
  .await?;
  if rows.is_empty() {
    println!("no audit events for {username}");
    return Ok(());
  }
  for (id, event, detail, ip, at) in rows {
    println!("{at}  #{id}  {event}  {detail}  {ip}");
  }
  Ok(())
}

async fn user_usage(pool: &MySqlPool, username: &str) -> anyhow::Result<()> {
  let id = require_user(pool, username).await?;
  let today: (i64, i64) = sqlx::query_as(
    "SELECT CAST(COALESCE(SUM(rows_written),0) AS SIGNED),             CAST(COALESCE(SUM(bytes_written),0) AS SIGNED)        FROM sync_usage WHERE user_id = ? AND day = CURDATE()",
  )
  .bind(id)
  .fetch_one(pool)
  .await?;
  println!("{username} today: {} rows / {} bytes", today.0, today.1);
  let days: Vec<(String, i64, i64)> = sqlx::query_as(
    "SELECT DATE_FORMAT(day, '%Y-%m-%d'), CAST(SUM(rows_written) AS SIGNED),             CAST(SUM(bytes_written) AS SIGNED)        FROM sync_usage WHERE user_id = ? AND day >= DATE_SUB(CURDATE(), INTERVAL 7 DAY)       GROUP BY day ORDER BY day DESC",
  )
  .bind(id)
  .fetch_all(pool)
  .await?;
  for (day, rows, bytes) in days {
    println!("  {day}: {rows} rows / {bytes} bytes");
  }
  Ok(())
}

async fn prune(pool: &MySqlPool, days: i64, apply: bool) -> anyhow::Result<()> {
  let days = days.clamp(1, 3650);
  // 各表时间列不同：sync_usage 只有 day/updated_at（无 created_at）。
  let targets = [
    ("growth_events", "created_at"),
    ("sync_usage", "day"),
    ("audit_events", "created_at"),
  ];
  for (table, time_column) in targets {
    let sql = format!("DELETE FROM {table} WHERE {time_column} < NOW() - INTERVAL ? DAY");
    if apply {
      let result = sqlx::query(sqlx::AssertSqlSafe(sql))
        .bind(days)
        .execute(pool)
        .await?;
      println!("{table}: removed {} row(s)", result.rows_affected());
    } else {
      let count: i64 = sqlx::query_scalar(sqlx::AssertSqlSafe(format!(
        "SELECT COUNT(*) FROM {table} WHERE {time_column} < NOW() - INTERVAL ? DAY"
      )))
      .bind(days)
      .fetch_one(pool)
      .await?;
      println!("{table}: {count} row(s) older than {days} days (dry-run)");
    }
  }
  Ok(())
}

async fn sync_gc_cmd(pool: &MySqlPool, dry_run: bool) -> anyhow::Result<()> {
  let reports = desire_api::modules::sync::sync_gc::gc_all_users(pool, dry_run).await?;
  let mut total = 0u64;
  for (user_id, report) in &reports {
    let sum: u64 = report.deleted.values().sum();
    total += sum;
    if sum > 0 || report.stale_cursors > 0 {
      println!(
        "user {user_id}: {} 条墓碑{} / 过期游标 {}",
        sum,
        if report.deleted.is_empty() {
          String::new()
        } else {
          format!("（{:?}）", report.deleted)
        },
        report.stale_cursors
      );
    }
  }
  println!(
    "{}: {} 个用户，合计 {} 条墓碑{}",
    if dry_run { "dry-run" } else { "gc" },
    reports.len(),
    total,
    if dry_run { "（未删除）" } else { "" }
  );
  Ok(())
}

/// 按用户名取 id（不存在即报错退出）。
async fn require_user(pool: &MySqlPool, username: &str) -> anyhow::Result<i64> {
  let id = user_exists(pool, username)
    .await?
    .with_context(|| format!("no such user: {username}"))?;
  Ok(id)
}

/// C7（v0.8.44）：列出用户全部设备，撤销态标注。
async fn device_list(pool: &MySqlPool, username: &str) -> anyhow::Result<()> {
  let user_id = require_user(pool, username).await?;
  let rows = sqlx::query_as::<
    _,
    (
      String,
      String,
      String,
      String,
      chrono::NaiveDateTime,
      Option<chrono::NaiveDateTime>,
    ),
  >(
    "SELECT device_id, name, platform, ip, last_seen_at, revoked_at \
     FROM devices WHERE user_id = ? ORDER BY last_seen_at DESC",
  )
  .bind(user_id)
  .fetch_all(pool)
  .await?;
  if rows.is_empty() {
    println!("(无设备)");
    return Ok(());
  }
  println!(
    "{:<36} {:<18} {:<10} {:<16} {:<20} {}",
    "device_id", "name", "platform", "ip", "last_seen", "status"
  );
  for (device_id, name, platform, ip, last_seen, revoked) in rows {
    println!(
      "{:<36} {:<18} {:<10} {:<16} {:<20} {}",
      device_id,
      truncate(&name, 18),
      truncate(&platform, 10),
      truncate(&ip, 16),
      last_seen.format("%Y-%m-%d %H:%M"),
      if revoked.is_some() {
        "revoked"
      } else {
        "active"
      }
    );
  }
  Ok(())
}

/// 撤销设备：revoked_at 置位 + 该设备全部未过期刷新令牌吊销（与 API 的
/// 设备吊销联动语义一致：access ≤2h 自然过期）。
async fn device_revoke(pool: &MySqlPool, username: &str, device_id: &str) -> anyhow::Result<()> {
  let user_id = require_user(pool, username).await?;
  let result = sqlx::query(
    "UPDATE devices SET revoked_at = CURRENT_TIMESTAMP \
     WHERE user_id = ? AND device_id = ? AND revoked_at IS NULL",
  )
  .bind(user_id)
  .bind(device_id)
  .execute(pool)
  .await?;
  if result.rows_affected() == 0 {
    bail!("device not found or already revoked: {device_id}");
  }
  let tokens = sqlx::query(
    "UPDATE user_refresh_tokens SET revoked_at = CURRENT_TIMESTAMP \
     WHERE user_id = ? AND device_id = \
       (SELECT id FROM devices WHERE user_id = ? AND device_id = ?) \
       AND revoked_at IS NULL",
  )
  .bind(user_id)
  .bind(user_id)
  .bind(device_id)
  .execute(pool)
  .await?;
  sqlx::query(
    "UPDATE devices SET token_version = token_version + 1 WHERE user_id = ? AND device_id = ?",
  )
  .bind(user_id)
  .bind(device_id)
  .execute(pool)
  .await?;
  println!(
    "已撤销设备 {device_id}（联动吊销 {} 个刷新令牌，access token 立即失效）",
    tokens.rows_affected()
  );
  Ok(())
}

/// 远端信箱：最近 20 条（recipient/投递状态/时间摘要）；--purge 清未投递行。

/// remote stats（v0.8.65 批 3，C7 剩余）：配对设备/在线状态/信箱计数。
async fn remote_stats(pool: &MySqlPool, username: &str) -> anyhow::Result<()> {
  let user_id = require_user(pool, username).await?;
  let devices: Vec<(
    String,
    String,
    Option<chrono::NaiveDateTime>,
    Option<chrono::NaiveDateTime>,
    Option<chrono::NaiveDateTime>,
  )> = sqlx::query_as(
    "SELECT desktop_device_id, desktop_name, claimed_at, revoked_at, desktop_last_seen_at \
     FROM remote_pairings WHERE user_id = ? AND claimed_at IS NOT NULL \
     ORDER BY created_at DESC",
  )
  .bind(user_id)
  .fetch_all(pool)
  .await?;
  println!("配对设备 {} 台：", devices.len());
  let now = chrono::Utc::now().naive_utc();
  for (id, name, _claimed, revoked, last_seen) in &devices {
    let state = if revoked.is_some() {
      "已撤销"
    } else if let Some(seen) = last_seen {
      if (now - *seen).num_seconds() < 15 {
        "在线"
      } else {
        "离线"
      }
    } else {
      "未上报"
    };
    println!(
      "  {} {} [{}] 最近在线 {:?}",
      id,
      if name.is_empty() { "(未命名)" } else { name },
      state,
      last_seen
    );
  }
  let total: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM remote_inbox WHERE user_id = ?")
    .bind(user_id)
    .fetch_one(pool)
    .await?;
  let pending: i64 = sqlx::query_scalar(
    "SELECT COUNT(*) FROM remote_inbox WHERE user_id = ? AND delivered_at IS NULL",
  )
  .bind(user_id)
  .fetch_one(pool)
  .await?;
  let last: Option<chrono::NaiveDateTime> =
    sqlx::query_scalar("SELECT MAX(created_at) FROM remote_inbox WHERE user_id = ?")
      .bind(user_id)
      .fetch_one(pool)
      .await?;
  println!(
    "信箱：共 {} 条，未投递 {} 条，最近入箱 {:?}",
    total, pending, last
  );
  Ok(())
}

/// remote cleanup（v0.8.65 批 3）：清已投递信箱行（默认 30 天前）与过期未认领
/// 配对行。默认 dry-run（只报数），--apply 才删。
async fn remote_cleanup(
  pool: &MySqlPool,
  username: &str,
  days: u64,
  apply: bool,
) -> anyhow::Result<()> {
  let user_id = require_user(pool, username).await?;
  let cutoff = chrono::Utc::now().naive_utc() - chrono::Duration::days(days as i64);
  let inbox: i64 = sqlx::query_scalar(
    "SELECT COUNT(*) FROM remote_inbox WHERE user_id = ? AND delivered_at IS NOT NULL AND created_at < ?")
    .bind(user_id).bind(cutoff).fetch_one(pool).await?;
  let pairings: i64 = sqlx::query_scalar(
    "SELECT COUNT(*) FROM remote_pairings WHERE user_id = ? AND claimed_at IS NULL AND expires_at < ?")
    .bind(user_id).bind(cutoff).fetch_one(pool).await?;
  println!(
    "dry-run={} · 截止 {:?}：已投递信箱 {} 条，过期未认领配对 {} 行",
    !apply, cutoff, inbox, pairings
  );
  if !apply {
    println!("加 --apply 才真正删除。");
    return Ok(());
  }
  let r1 = sqlx::query(
    "DELETE FROM remote_inbox WHERE user_id = ? AND delivered_at IS NOT NULL AND created_at < ?",
  )
  .bind(user_id)
  .bind(cutoff)
  .execute(pool)
  .await?;
  let r2 = sqlx::query(
    "DELETE FROM remote_pairings WHERE user_id = ? AND claimed_at IS NULL AND expires_at < ?",
  )
  .bind(user_id)
  .bind(cutoff)
  .execute(pool)
  .await?;
  println!(
    "已删除：信箱 {} 条，配对 {} 行",
    r1.rows_affected(),
    r2.rows_affected()
  );
  Ok(())
}

async fn remote_inbox(pool: &MySqlPool, username: &str, purge: bool) -> anyhow::Result<()> {
  let user_id = require_user(pool, username).await?;
  if purge {
    let result = sqlx::query("DELETE FROM remote_inbox WHERE user_id = ? AND delivered_at IS NULL")
      .bind(user_id)
      .execute(pool)
      .await?;
    println!("已清除 {} 条未投递信箱行", result.rows_affected());
    return Ok(());
  }
  let pending: i64 = sqlx::query_scalar(
    "SELECT COUNT(*) FROM remote_inbox WHERE user_id = ? AND delivered_at IS NULL",
  )
  .bind(user_id)
  .fetch_one(pool)
  .await?;
  let rows = sqlx::query_as::<
    _,
    (
      i64,
      String,
      String,
      String,
      chrono::NaiveDateTime,
      Option<chrono::NaiveDateTime>,
    ),
  >(
    "SELECT id, recipient, desktop_device_id, LEFT(payload, 80), created_at, delivered_at \
     FROM remote_inbox WHERE user_id = ? ORDER BY id DESC LIMIT 20",
  )
  .bind(user_id)
  .fetch_all(pool)
  .await?;
  println!("未投递 {pending} 条；最近 {} 条：", rows.len());
  for (id, recipient, device, payload, created, delivered) in rows {
    let summary = payload.replace('\n', " ");
    println!(
      "#{id} [{recipient}] {} {} {} → {}",
      truncate(&device, 16),
      created.format("%m-%d %H:%M"),
      if delivered.is_some() {
        "delivered"
      } else {
        "pending"
      },
      truncate(&summary, 60)
    );
  }
  Ok(())
}

fn truncate(input: &str, max: usize) -> String {
  if input.chars().count() <= max {
    input.to_string()
  } else {
    input.chars().take(max).collect()
  }
}

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
  sqlx::query(
    "UPDATE users SET password_hash = ?, updated_at = ?, token_version = token_version + 1 WHERE id = ?",
  )
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
  sqlx::query(
    "UPDATE users SET status = ?, updated_at = ?, token_version = token_version + 1 WHERE id = ?",
  )
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
  // 历史域在专表 sync_history_items（0007），与通用表并表统计
  let rows = sqlx::query_as::<_, (String, i64, i64)>(
    "SELECT domain, COUNT(*), SUM(deleted_at IS NOT NULL) FROM (\
           SELECT domain, deleted_at FROM sync_items \
           UNION ALL SELECT domain, deleted_at FROM sync_history_items\
         ) t GROUP BY domain ORDER BY domain",
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
