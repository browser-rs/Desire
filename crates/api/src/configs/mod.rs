use anyhow::{Context, bail};
use chrono::Duration;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Env {
  Dev,
  Prod,
}

impl Env {
  pub fn from_str(s: &str) -> anyhow::Result<Self> {
    match s {
      "dev" => Ok(Env::Dev),
      "prod" => Ok(Env::Prod),
      other => bail!("invalid DESIRE_ENV '{other}', expected 'dev' or 'prod'"),
    }
  }
}

#[derive(Debug, Clone)]
pub struct Config {
  pub env: Env,
  pub database_url: String,
  pub jwt_secret: String,
  pub access_token_ttl: Duration,
  pub refresh_token_ttl: Duration,
  pub bind_addr: String,
  /// Redis 地址(缓存加速);空 = 不启用,业务直连 DB。
  /// 例 redis://:password@127.0.0.1:6379/0
  pub redis_url: String,
  /// 是否开放注册(公网部署建议建完自己的账号后关掉)。
  pub allow_registration: bool,
}

fn env_or(key: &str, default: &str) -> String {
  std::env::var(key).unwrap_or_else(|_| default.to_string())
}

impl Config {
  pub fn from_env() -> anyhow::Result<Self> {
    let env = Env::from_str(&env_or("DESIRE_ENV", "dev"))?;
    let database_url = std::env::var("DATABASE_URL")
      .context("DATABASE_URL env var is required (e.g. mysql://user:pass@host:3306/desire)")?;
    let jwt_secret = env_or("DESIRE_API_JWT_SECRET", "api-dev-secret");
    // 生产环境禁止使用已知默认密钥:漏配时任何人可伪造任意用户 token,必须启动即失败
    if env == Env::Prod && jwt_secret == "api-dev-secret" {
      bail!("DESIRE_API_JWT_SECRET must be set to a real secret when DESIRE_ENV=prod");
    }
    Ok(Config {
      env,
      database_url,
      jwt_secret,
      access_token_ttl: Duration::seconds(
        env_or("DESIRE_API_ACCESS_TTL", "7200")
          .parse()
          .unwrap_or(7200),
      ),
      refresh_token_ttl: Duration::seconds(
        env_or("DESIRE_API_REFRESH_TTL", "1209600")
          .parse()
          .unwrap_or(1209600),
      ),
      bind_addr: env_or("DESIRE_API_BIND_ADDR", "0.0.0.0:18090"),
      redis_url: env_or("DESIRE_REDIS_URL", ""),
      allow_registration: matches!(
        env_or("DESIRE_API_ALLOW_REGISTRATION", "1")
          .to_lowercase()
          .as_str(),
        "1" | "true" | "yes"
      ),
    })
  }
}

#[cfg(test)]
mod tests {
  use super::{Config, Env};
  use std::sync::Mutex;

  static ENV_LOCK: Mutex<()> = Mutex::new(());

  #[test]
  fn from_env_dev_defaults() {
    let _guard = ENV_LOCK.lock().unwrap();
    unsafe {
      std::env::remove_var("DESIRE_ENV");
      std::env::set_var("DATABASE_URL", "mysql://root:root@127.0.0.1:3306/desire");
      std::env::set_var("DESIRE_API_JWT_SECRET", "s3cret");
    }
    let c = Config::from_env().unwrap();
    assert_eq!(c.env, Env::Dev);
    assert_eq!(c.database_url, "mysql://root:root@127.0.0.1:3306/desire");
    assert_eq!(c.jwt_secret, "s3cret");
    assert_eq!(c.bind_addr, "0.0.0.0:18090");
    unsafe {
      std::env::remove_var("DATABASE_URL");
      std::env::remove_var("DESIRE_API_JWT_SECRET");
    }
  }

  #[test]
  fn invalid_env_rejected() {
    let _guard = ENV_LOCK.lock().unwrap();
    unsafe {
      std::env::set_var("DESIRE_ENV", "staging");
      std::env::set_var("DATABASE_URL", "mysql://root:root@127.0.0.1:3306/desire");
    }
    assert!(Config::from_env().is_err());
    unsafe {
      std::env::remove_var("DESIRE_ENV");
      std::env::remove_var("DATABASE_URL");
    }
  }

  #[test]
  fn prod_rejects_default_jwt_secret() {
    let _guard = ENV_LOCK.lock().unwrap();
    unsafe {
      std::env::set_var("DESIRE_ENV", "prod");
      std::env::set_var("DATABASE_URL", "mysql://root:root@127.0.0.1:3306/desire");
      std::env::remove_var("DESIRE_API_JWT_SECRET");
    }
    let err = Config::from_env().unwrap_err().to_string();
    assert!(err.contains("DESIRE_API_JWT_SECRET"));
    unsafe {
      std::env::set_var("DESIRE_API_JWT_SECRET", "real-secret");
    }
    assert!(Config::from_env().is_ok());
    unsafe {
      std::env::remove_var("DESIRE_ENV");
      std::env::remove_var("DATABASE_URL");
      std::env::remove_var("DESIRE_API_JWT_SECRET");
    }
  }
}
