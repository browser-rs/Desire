//! 可信客户端地址（v0.8.81 批 1）：默认只认 TCP 对端；只有显式
//! `DESIRE_API_TRUST_PROXY=true` 才读 `x-forwarded-for` 第一段。
//!
//! 结果写进内部请求头 `x-desire-client-ip`，业务侧（登录/注册/恢复限流、
//! 审计）只读它——不要再直接信任外部传入的 XFF。

use std::net::SocketAddr;

use axum::extract::{ConnectInfo, Request, State};
use axum::http::HeaderValue;
use axum::middleware::Next;
use axum::response::Response;

use crate::types::AppState;

pub const CLIENT_IP_HEADER: &str = "x-desire-client-ip";

pub async fn client_ip(State(state): State<AppState>, mut req: Request, next: Next) -> Response {
  // ConnectInfo 由 `into_make_service_with_connect_info` 塞进扩展；用 Option
  // 读取而不是提取器参数（提取器在 Router 层的 trait 约束里不成立）。
  let peer = req
    .extensions()
    .get::<ConnectInfo<SocketAddr>>()
    .map(|ConnectInfo(addr)| addr.ip().to_string())
    .unwrap_or_default();
  let forwarded = req
    .headers()
    .get("x-forwarded-for")
    .and_then(|value| value.to_str().ok())
    .and_then(|value| value.split(',').next())
    .map(str::trim)
    .filter(|value| !value.is_empty() && value.len() <= 45);
  let ip = if state.config.trust_proxy {
    forwarded.unwrap_or(&peer).to_string()
  } else {
    peer
  };
  // 先清外部伪造的同名头，再写入可信值。
  req.headers_mut().remove(CLIENT_IP_HEADER);
  if let Ok(value) = HeaderValue::from_str(&ip) {
    req.headers_mut().insert(CLIENT_IP_HEADER, value);
  }
  next.run(req).await
}

/// 业务侧统一读取入口：中间件写下的可信地址；测试/直调无中间件时回退 XFF。
pub fn trusted_client_ip(headers: &axum::http::HeaderMap) -> String {
  headers
    .get(CLIENT_IP_HEADER)
    .or_else(|| headers.get("x-forwarded-for"))
    .and_then(|value| value.to_str().ok())
    .map(|value| {
      value
        .split(',')
        .next()
        .unwrap_or("")
        .trim()
        .chars()
        .take(45)
        .collect()
    })
    .unwrap_or_default()
}

#[cfg(test)]
mod tests {
  use super::trusted_client_ip;
  use axum::http::{HeaderMap, HeaderValue};

  #[test]
  fn internal_header_wins_over_forwarded() {
    let mut headers = HeaderMap::new();
    headers.insert("x-desire-client-ip", HeaderValue::from_static("10.0.0.7"));
    headers.insert(
      "x-forwarded-for",
      HeaderValue::from_static("1.2.3.4, 5.6.7.8"),
    );
    assert_eq!(trusted_client_ip(&headers), "10.0.0.7");
  }

  #[test]
  fn falls_back_to_first_forwarded_for_legacy() {
    let mut headers = HeaderMap::new();
    headers.insert(
      "x-forwarded-for",
      HeaderValue::from_static("1.2.3.4, 5.6.7.8"),
    );
    assert_eq!(trusted_client_ip(&headers), "1.2.3.4");
  }
}
