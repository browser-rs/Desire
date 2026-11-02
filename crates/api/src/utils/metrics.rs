//! 轻量进程内指标（v0.8.38 C6）：不引 Prometheus 依赖，只暴露计数器/
//! 延迟总和，够回答"有没有流量、哪里报错、慢不慢"。
//!
//! 局限：多实例各自计数（聚合交给 Prometheus 抓取侧）；进程重启清零。
//! 这是有意的——引入完整 metrics 栈的复杂度与收益在单机部署阶段不成比例。

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

#[derive(Default)]
struct Metrics {
  requests: AtomicU64,
  errors: AtomicU64,
  duration_ms_sum: AtomicU64,
  by_route: Mutex<BTreeMap<String, u64>>,
  by_status: Mutex<BTreeMap<u16, u64>>,
}

static METRICS: OnceLock<Metrics> = OnceLock::new();

fn metrics() -> &'static Metrics {
  METRICS.get_or_init(Metrics::default)
}

/// 记录一次请求。route 用 MatchedPath（`/sync/{domain}`），避免把 id 带进
/// 标签造成基数爆炸。
pub fn record(route: &str, status: u16, duration_ms: u64) {
  let m = metrics();
  m.requests.fetch_add(1, Ordering::Relaxed);
  if status >= 500 {
    m.errors.fetch_add(1, Ordering::Relaxed);
  }
  m.duration_ms_sum.fetch_add(duration_ms, Ordering::Relaxed);
  if let Ok(mut map) = m.by_route.lock() {
    *map.entry(route.to_string()).or_insert(0) += 1;
  }
  if let Ok(mut map) = m.by_status.lock() {
    *map.entry(status).or_insert(0) += 1;
  }
}

/// Prometheus 文本格式（counter 无类型声明也合法，但写明更利于消费）。
pub fn render() -> String {
  let m = metrics();
  let mut out = String::new();
  out.push_str("# HELP desire_api_requests_total Total HTTP requests.\n");
  out.push_str("# TYPE desire_api_requests_total counter\n");
  out.push_str(&format!(
    "desire_api_requests_total {}\n",
    m.requests.load(Ordering::Relaxed)
  ));
  out.push_str("# TYPE desire_api_errors_total counter\n");
  out.push_str(&format!(
    "desire_api_errors_total {}\n",
    m.errors.load(Ordering::Relaxed)
  ));
  out.push_str("# TYPE desire_api_request_duration_ms_sum counter\n");
  out.push_str(&format!(
    "desire_api_request_duration_ms_sum {}\n",
    m.duration_ms_sum.load(Ordering::Relaxed)
  ));
  if let Ok(map) = m.by_route.lock() {
    for (route, count) in map.iter() {
      out.push_str(&format!(
        "desire_api_requests_by_route{{route=\"{}\"}} {}\n",
        escape(route),
        count
      ));
    }
  }
  if let Ok(map) = m.by_status.lock() {
    for (status, count) in map.iter() {
      out.push_str(&format!(
        "desire_api_requests_by_status{{status=\"{status}\"}} {count}\n"
      ));
    }
  }
  out
}

fn escape(value: &str) -> String {
  value.replace('\\', "\\\\").replace('"', "\\\"")
}

#[cfg(test)]
mod tests {
  use super::{record, render};

  #[test]
  fn records_and_renders() {
    record("/test/{id}", 200, 12);
    record("/test/{id}", 500, 30);
    let text = render();
    assert!(text.contains("desire_api_requests_total"));
    assert!(text.contains("route=\"/test/{id}\""));
    assert!(text.contains("status=\"500\""));
    assert!(text.contains("desire_api_errors_total"));
  }
}
