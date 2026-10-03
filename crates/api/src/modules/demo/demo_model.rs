use chrono::NaiveDateTime;
use serde::{Deserialize, Serialize};

/// 演示商品（目录固定在 demo_service 里，价格单位 = 分）。
#[derive(Debug, Clone, Serialize)]
pub struct DemoProduct {
  pub sku: String,
  pub name: String,
  pub price: f64,
  pub desc: String,
}

/// 购物车里的一行（price/subtotal 单位 = 分，序列化时转元）。
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
  pub created_at: NaiveDateTime,
}

#[derive(Debug, Deserialize)]
pub struct AddCartReq {
  pub sku: String,
  pub qty: Option<u32>,
}

/// IM 演示频道（客服 / 招聘）。
#[derive(Debug, Clone, Serialize)]
pub struct DemoImChannel {
  pub id: String,
  pub name: String,
  pub desc: String,
}

/// 一条 IM 消息。sender: visitor | bot。
#[derive(Debug, Clone, Serialize)]
pub struct DemoImMessage {
  pub id: i64,
  pub channel: String,
  pub sender: String,
  pub content: String,
  pub created_at: NaiveDateTime,
}

#[derive(Debug, Deserialize)]
pub struct ImSendReq {
  pub channel: String,
  pub content: String,
}

#[derive(Debug, Deserialize)]
pub struct ImQuery {
  pub channel: String,
  pub after_id: Option<i64>,
}
