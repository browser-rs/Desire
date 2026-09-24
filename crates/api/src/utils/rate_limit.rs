use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// 进程内滑动窗口限流器(登录爆破/注册滥用防护)。
/// 单实例部署够用;多实例部署需改用 redis 计数(当前架构为单实例)。
#[derive(Default)]
pub struct RateLimiter {
  hits: Mutex<HashMap<String, Vec<Instant>>>,
}

impl RateLimiter {
  /// 窗口内第 limit 次之后的请求返回 false。
  pub fn allow(&self, key: &str, limit: usize, window: Duration) -> bool {
    let now = Instant::now();
    let mut map = self.hits.lock().unwrap();
    let hits = map.entry(key.to_string()).or_default();
    hits.retain(|t| now.duration_since(*t) < window);
    if hits.len() >= limit {
      return false;
    }
    hits.push(now);
    true
  }
}
