use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// 演示商品（目录固定在 demo_service 里，随进程内存在）。
#[derive(Debug, Clone, Serialize)]
pub struct DemoProduct {
  pub sku: String,
  pub name: String,
  pub price: f64,
  pub desc: String,
}

/// 购物车里的一行。
#[derive(Debug, Clone, Serialize)]
pub struct DemoCartLine {
  pub sku: String,
  pub name: String,
  pub price: f64,
  pub qty: u32,
  pub subtotal: f64,
}

/// 购物车快照（count/total 由服务端现算，页面与智能体都直接可读）。
#[derive(Debug, Clone, Serialize)]
pub struct DemoCartSnapshot {
  pub items: Vec<DemoCartLine>,
  pub count: u32,
  pub total: f64,
}

/// 一笔演示订单。
#[derive(Debug, Clone, Serialize)]
pub struct DemoOrder {
  pub id: String,
  pub items: Vec<DemoCartLine>,
  pub count: u32,
  pub total: f64,
  pub created_at: DateTime<Utc>,
}

#[derive(Debug, Deserialize)]
pub struct AddCartReq {
  pub sku: String,
  pub qty: Option<u32>,
}
