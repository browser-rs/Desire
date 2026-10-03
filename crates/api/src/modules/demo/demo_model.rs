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

// ── 论坛演示（发帖 / 点赞 / 评论） ────────────────────────

/// 帖子列表行（author 是 client 前 8 位短 id，演示没有用户体系）。
#[derive(Debug, Clone, Serialize)]
pub struct DemoForumPost {
  pub id: i64,
  pub author: String,
  pub mine: bool,
  pub title: String,
  pub content: String,
  pub likes: i64,
  pub liked_by_me: bool,
  pub comments: i64,
  pub created_at: NaiveDateTime,
}

#[derive(Debug, Clone, Serialize)]
pub struct DemoForumComment {
  pub id: i64,
  pub post_id: i64,
  pub author: String,
  pub mine: bool,
  pub content: String,
  pub created_at: NaiveDateTime,
}

#[derive(Debug, Deserialize)]
pub struct NewPostReq {
  pub title: String,
  pub content: String,
}

#[derive(Debug, Deserialize)]
pub struct NewCommentReq {
  pub content: String,
}

/// 点赞 toggle 的返回。
#[derive(Debug, Serialize)]
pub struct LikeResult {
  pub liked: bool,
  pub likes: i64,
}

// ── 预约演示 ──────────────────────────────────────────────

/// 一个时段：available 由服务端按当天已订情况现算（bool 字段演示）。
#[derive(Debug, Clone, Serialize)]
pub struct DemoSlot {
  pub time: String,
  pub available: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct DemoSlotsResp {
  pub date: String,
  pub slots: Vec<DemoSlot>,
}

#[derive(Debug, Clone, Serialize)]
pub struct DemoBooking {
  pub id: i64,
  pub date: String,
  pub slot: String,
  pub guest: String,
  pub created_at: NaiveDateTime,
}

#[derive(Debug, Deserialize)]
pub struct BookReq {
  pub date: String,
  pub slot: String,
  pub name: String,
}

#[derive(Debug, Deserialize)]
pub struct SlotsQuery {
  pub date: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct NewsQuery {
  pub page: Option<u32>,
}

// ── 审核台演示（论坛帖子治理） ────────────────────────────

/// 审核台帖子行：比访客视图多 hidden 位（含已隐藏帖）。
#[derive(Debug, Clone, Serialize)]
pub struct DemoAdminPost {
  pub id: i64,
  pub author: String,
  pub title: String,
  pub content: String,
  pub likes: i64,
  pub comments: i64,
  pub hidden: bool,
  pub created_at: NaiveDateTime,
}

#[derive(Debug, Deserialize)]
pub struct HideReq {
  pub hidden: bool,
}

// ── 入驻向导演示（SPA 分步提交） ──────────────────────────

#[derive(Debug, Clone, Serialize)]
pub struct DemoWizardApp {
  pub id: i64,
  pub shop: String,
  pub category: String,
  pub contact: String,
  pub phone: String,
  pub created_at: NaiveDateTime,
}

#[derive(Debug, Deserialize)]
pub struct WizardApplyReq {
  pub shop: String,
  pub category: String,
  pub contact: String,
  pub phone: String,
}

// ── 资讯演示（合成内容，无表） ────────────────────────────

#[derive(Debug, Clone, Serialize)]
pub struct DemoArticle {
  pub id: i64,
  pub title: String,
  pub category: String,
  pub summary: String,
  pub date: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct DemoArticlesPage {
  pub page: u32,
  pub total_pages: u32,
  pub items: Vec<DemoArticle>,
}

// ── 看板演示（聚合其他 demo 表） ──────────────────────────

#[derive(Debug, Serialize)]
pub struct DemoMetric {
  pub key: String,
  pub name: String,
  pub value: i64,
  pub unit: String,
}

#[derive(Debug, Serialize)]
pub struct DemoStats {
  pub metrics: Vec<DemoMetric>,
}
