use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// 进程内滑动窗口限流器(登录爆破/注册滥用防护)。
/// 单实例部署够用;多实例部署需改用 redis 计数(当前架构为单实例)。
pub struct RateLimiter {
  hits: Mutex<HashMap<String, Vec<Instant>>>,
  /// 上次全局清扫时间；None = 尚未清过（首次 allow 即触发）。
  last_sweep: Mutex<Option<Instant>>,
}

impl Default for RateLimiter {
  fn default() -> Self {
    Self {
      hits: Mutex::default(),
      last_sweep: Mutex::new(None),
    }
  }
}

/// 全局清扫间隔。
const SWEEP_INTERVAL: Duration = Duration::from_secs(3600);

impl RateLimiter {
  /// 窗口内第 limit 次之后的请求返回 false。
  pub fn allow(&self, key: &str, limit: usize, window: Duration) -> bool {
    let now = Instant::now();
    let mut map = self.hits.lock().unwrap();
    // 定期清扫过期 key——否则公网上扫过无鉴权端点的每个 IP 永久占一条
    // map 项（内存慢泄漏，x-forwarded-for 链还会生成复合 key）。
    let needs_sweep = {
      let last = self.last_sweep.lock().unwrap();
      last.is_none_or(|t| now.duration_since(t) > SWEEP_INTERVAL)
    };
    if needs_sweep {
      *self.last_sweep.lock().unwrap() = Some(now);
      map.retain(|_, t| {
        t.retain(|ts| now.duration_since(*ts) < window);
        !t.is_empty()
      });
    }
    let hits = map.entry(key.to_string()).or_default();
    hits.retain(|t| now.duration_since(*t) < window);
    if hits.len() >= limit {
      return false;
    }
    hits.push(now);
    true
  }
}
