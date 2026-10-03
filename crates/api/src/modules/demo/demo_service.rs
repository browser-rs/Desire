//! Demo 演示场的共享状态（购物车 / 订单 / IM 消息）——落 MySQL。
//! 部署是多实例 + nginx 轮询（无 sticky），进程内内存会让加购落在
//! A 实例、结算打到 B 实例，所以演示态也必须进共享存储。无鉴权、
//! 无敏感数据；客户端以 `X-Demo-Client` 头区分各自的购物车与订单
//! （页面在 localStorage 里生成 UUID）。金额一律整数分。

use chrono::NaiveDateTime;
use sqlx::MySqlPool;

use super::demo_model::{
  DemoAdminPost, DemoArticle, DemoArticlesPage, DemoBooking, DemoCartLine, DemoCartSnapshot,
  DemoForumComment, DemoForumPost, DemoImChannel, DemoImMessage, DemoMetric, DemoOrder,
  DemoProduct, DemoSlot, DemoSlotsResp, DemoStats, DemoWizardApp, LikeResult,
};
use crate::errors::AppError;

/// 固定演示目录。价格是演示数据，非真实在售商品（price 单位 = 分）。
pub fn products() -> Vec<DemoProduct> {
  vec![
    DemoProduct {
      sku: "kb-01".into(),
      name: "机械键盘".into(),
      price: 329.0,
      desc: "87 键热插拔，Gasket 结构".into(),
    },
    DemoProduct {
      sku: "mon-4k".into(),
      name: "4K 显示器".into(),
      price: 1999.0,
      desc: "27 英寸 IPS，Type-C 一线连".into(),
    },
    DemoProduct {
      sku: "chair-erg".into(),
      name: "人体工学椅".into(),
      price: 1299.9,
      desc: "可调腰靠与扶手，网布坐面".into(),
    },
    DemoProduct {
      sku: "mouse-02".into(),
      name: "无线鼠标".into(),
      price: 129.0,
      desc: "静音微动，双模连接".into(),
    },
    DemoProduct {
      sku: "desk-01".into(),
      name: "电动升降桌".into(),
      price: 2499.0,
      desc: "双电机，记忆高度档位".into(),
    },
    DemoProduct {
      sku: "hub-usb".into(),
      name: "USB-C 扩展坞".into(),
      price: 259.0,
      desc: "HDMI 4K + 千兆网口 + PD 100W".into(),
    },
    DemoProduct {
      sku: "lamp-01".into(),
      name: "屏幕挂灯".into(),
      price: 199.0,
      desc: "非对称前投光，色温可调".into(),
    },
    DemoProduct {
      sku: "ssd-1tb".into(),
      name: "1TB 移动固态硬盘".into(),
      price: 699.0,
      desc: "NVMe 盒子，10Gbps".into(),
    },
  ]
}

fn find_product(sku: &str) -> Option<DemoProduct> {
  products().into_iter().find(|p| p.sku == sku)
}

fn cents_to_yuan(cents: i64) -> f64 {
  (cents as f64) / 100.0
}

pub async fn cart_get(pool: &MySqlPool, client: &str) -> Result<DemoCartSnapshot, AppError> {
  let rows: Vec<(String, i32, i32)> = sqlx::query_as(
    "SELECT sku, qty, price_cents FROM demo_cart_items WHERE client_id = ? ORDER BY updated_at",
  )
  .bind(client)
  .fetch_all(pool)
  .await?;
  let items: Vec<DemoCartLine> = rows
    .into_iter()
    .map(|(sku, qty, price_cents)| {
      let name = find_product(&sku)
        .map(|p| p.name)
        .unwrap_or_else(|| sku.clone());
      DemoCartLine {
        subtotal: cents_to_yuan(price_cents as i64 * qty as i64),
        name,
        price: cents_to_yuan(price_cents as i64),
        qty: qty as u32,
        sku,
      }
    })
    .collect();
  Ok(DemoCartSnapshot {
    count: items.iter().map(|l| l.qty).sum(),
    total: (items.iter().map(|l| l.subtotal).sum::<f64>() * 100.0).round() / 100.0,
    items,
  })
}

pub async fn cart_add(
  pool: &MySqlPool,
  client: &str,
  sku: &str,
  qty: u32,
) -> Result<DemoCartSnapshot, AppError> {
  let product =
    find_product(sku).ok_or_else(|| AppError::NotFound(format!("商品不存在: {sku}")))?;
  let qty = qty.clamp(1, 99);
  let price_cents = (product.price * 100.0).round() as i32;
  sqlx::query(
    "INSERT INTO demo_cart_items (client_id, sku, qty, price_cents) VALUES (?, ?, ?, ?)
     ON DUPLICATE KEY UPDATE qty = LEAST(99, qty + VALUES(qty)), price_cents = VALUES(price_cents)",
  )
  .bind(client)
  .bind(sku)
  .bind(qty as i32)
  .bind(price_cents)
  .execute(pool)
  .await?;
  cart_get(pool, client).await
}

pub async fn cart_remove(
  pool: &MySqlPool,
  client: &str,
  sku: &str,
) -> Result<DemoCartSnapshot, AppError> {
  let result = sqlx::query("DELETE FROM demo_cart_items WHERE client_id = ? AND sku = ?")
    .bind(client)
    .bind(sku)
    .execute(pool)
    .await?;
  if result.rows_affected() == 0 {
    return Err(AppError::NotFound(format!("购物车里没有商品: {sku}")));
  }
  cart_get(pool, client).await
}

/// 结算：事务内锁定购物车行 → 建订单 + 订单行 → 清空购物车。
/// FOR UPDATE 保证两实例并发结算同一购物车时不会双花。
pub async fn checkout(pool: &MySqlPool, client: &str) -> Result<DemoOrder, AppError> {
  let mut tx = pool.begin().await?;
  let rows: Vec<(String, i32, i32)> = sqlx::query_as(
    "SELECT sku, qty, price_cents FROM demo_cart_items WHERE client_id = ? FOR UPDATE",
  )
  .bind(client)
  .fetch_all(&mut *tx)
  .await?;
  if rows.is_empty() {
    return Err(AppError::Validation("购物车为空".into()));
  }
  let mut total_cents: i64 = 0;
  let mut count: u32 = 0;
  for (_, qty, price_cents) in &rows {
    total_cents += *price_cents as i64 * *qty as i64;
    count += *qty as u32;
  }
  let result = sqlx::query("INSERT INTO demo_orders (client_id, total_cents) VALUES (?, ?)")
    .bind(client)
    .bind(total_cents as i32)
    .execute(&mut *tx)
    .await?;
  let order_id = result.last_insert_id();
  for (sku, qty, price_cents) in &rows {
    let name = find_product(sku)
      .map(|p| p.name)
      .unwrap_or_else(|| sku.clone());
    sqlx::query(
      "INSERT INTO demo_order_items (order_id, sku, name, price_cents, qty) VALUES (?, ?, ?, ?, ?)",
    )
    .bind(order_id)
    .bind(sku)
    .bind(name)
    .bind(*price_cents)
    .bind(*qty)
    .execute(&mut *tx)
    .await?;
  }
  sqlx::query("DELETE FROM demo_cart_items WHERE client_id = ?")
    .bind(client)
    .execute(&mut *tx)
    .await?;
  tx.commit().await?;
  let created_at: (NaiveDateTime,) =
    sqlx::query_as("SELECT created_at FROM demo_orders WHERE id = ?")
      .bind(order_id)
      .fetch_one(pool)
      .await?;
  let items = rows
    .into_iter()
    .map(|(sku, qty, price_cents)| DemoCartLine {
      subtotal: cents_to_yuan(price_cents as i64 * qty as i64),
      name: find_product(&sku)
        .map(|p| p.name)
        .unwrap_or_else(|| sku.clone()),
      price: cents_to_yuan(price_cents as i64),
      qty: qty as u32,
      sku,
    })
    .collect();
  Ok(DemoOrder {
    id: format!("D-{order_id:06}"),
    items,
    count,
    total: cents_to_yuan(total_cents),
    created_at: created_at.0,
  })
}

pub async fn orders_get(pool: &MySqlPool, client: &str) -> Result<Vec<DemoOrder>, AppError> {
  let heads: Vec<(i64, i32, NaiveDateTime)> = sqlx::query_as(
    "SELECT id, total_cents, created_at FROM demo_orders WHERE client_id = ? ORDER BY id DESC LIMIT 20",
  )
  .bind(client)
  .fetch_all(pool)
  .await?;
  let mut orders = Vec::with_capacity(heads.len());
  for (id, total_cents, created_at) in heads {
    let rows: Vec<(String, String, i32, i32)> =
      sqlx::query_as("SELECT sku, name, price_cents, qty FROM demo_order_items WHERE order_id = ?")
        .bind(id)
        .fetch_all(pool)
        .await?;
    orders.push(DemoOrder {
      id: format!("D-{id:06}"),
      count: rows.iter().map(|(_, _, _, q)| *q as u32).sum(),
      total: cents_to_yuan(total_cents as i64),
      items: rows
        .into_iter()
        .map(|(sku, name, price_cents, qty)| DemoCartLine {
          subtotal: cents_to_yuan(price_cents as i64 * qty as i64),
          price: cents_to_yuan(price_cents as i64),
          qty: qty as u32,
          sku,
          name,
        })
        .collect(),
      created_at,
    });
  }
  Ok(orders)
}

// ── IM 演示（客服 / 招聘） ────────────────────────────────

pub fn im_channels() -> Vec<DemoImChannel> {
  vec![
    DemoImChannel {
      id: "support".into(),
      name: "客服小助".into(),
      desc: "退换货 / 发货 / 发票等常见问题".into(),
    },
    DemoImChannel {
      id: "hiring".into(),
      name: "招聘咨询".into(),
      desc: "留下姓名与方向，机器人会走一遍筛选脚本".into(),
    },
  ]
}

pub fn im_channel_ok(channel: &str) -> bool {
  im_channels().iter().any(|c| c.id == channel)
}

pub async fn im_messages(
  pool: &MySqlPool,
  client: &str,
  channel: &str,
  after_id: i64,
) -> Result<Vec<DemoImMessage>, AppError> {
  if !im_channel_ok(channel) {
    return Err(AppError::NotFound(format!("频道不存在: {channel}")));
  }
  // 会话按 (channel, client) 隔离：访客只看到自己的对话，招聘脚本
  // 的阶段推进也因此天然 per-visitor（0012 迁移）。
  let rows: Vec<(i64, String, String, NaiveDateTime)> = sqlx::query_as(
    "SELECT id, sender, content, created_at FROM demo_im_messages
     WHERE channel = ? AND client_id = ? AND id > ? ORDER BY id LIMIT 100",
  )
  .bind(channel)
  .bind(client)
  .bind(after_id)
  .fetch_all(pool)
  .await?;
  Ok(
    rows
      .into_iter()
      .map(|(id, sender, content, created_at)| DemoImMessage {
        id,
        channel: channel.to_string(),
        sender,
        content,
        created_at,
      })
      .collect(),
  )
}

/// 发一条访客消息：访客消息落库后，由服务端的确定性脚本机器人回一条。
/// 会话按 (channel, client_id) 隔离；机器人逻辑刻意无状态（招聘脚本
/// 按该访客的消息条数推进阶段）——多实例 + 无 sticky 部署下也天然正确。
pub async fn im_send(
  state: &crate::types::AppState,
  client: &str,
  channel: &str,
  content: &str,
) -> Result<Vec<DemoImMessage>, AppError> {
  let pool = &state.pool;
  if !im_channel_ok(channel) {
    return Err(AppError::NotFound(format!("频道不存在: {channel}")));
  }
  let content = content.trim();
  if content.is_empty() {
    return Err(AppError::Validation("消息不能为空".into()));
  }
  if content.len() > 500 {
    return Err(AppError::Validation("消息最长 500 字节".into()));
  }

  let mut tx = pool.begin().await?;
  let visitor_id = sqlx::query(
    "INSERT INTO demo_im_messages (channel, client_id, sender, content) VALUES (?, ?, 'visitor', ?)",
  )
  .bind(channel)
  .bind(client)
  .bind(content)
  .execute(&mut *tx)
  .await?
  .last_insert_id();
  let reply = bot_reply(&mut tx, client, channel, content).await?;
  let bot_id = sqlx::query(
    "INSERT INTO demo_im_messages (channel, client_id, sender, content) VALUES (?, ?, 'bot', ?)",
  )
  .bind(channel)
  .bind(client)
  .bind(&reply)
  .execute(&mut *tx)
  .await?
  .last_insert_id();
  tx.commit().await?;

  // 按插入 id 精确取回这一问一答（并发下也不会混入他人消息）
  let rows: Vec<(i64, String, String, NaiveDateTime)> = sqlx::query_as(
    "SELECT id, sender, content, created_at FROM demo_im_messages WHERE id IN (?, ?) ORDER BY id",
  )
  .bind(visitor_id)
  .bind(bot_id)
  .fetch_all(pool)
  .await?;
  let messages: Vec<DemoImMessage> = rows
    .into_iter()
    .map(|(id, sender, content, created_at)| DemoImMessage {
      id,
      channel: channel.to_string(),
      sender,
      content,
      created_at,
    })
    .collect();

  // express：Redis 可用就 PUBLISH 给该访客频道的 WS 订阅者（尽力而为；
  // 未配置 Redis = 纯轮询降级，是设计内状态）。演示数据非敏感，明文信封。
  im_notify(state, client, channel, &messages).await;

  Ok(messages)
}

/// WS 下行频道名：`demo-im:{channel}:{client}`（会话 per-visitor）。
pub fn im_ws_channel(client: &str, channel: &str) -> String {
  format!("demo-im:{channel}:{client}")
}

async fn im_notify(
  state: &crate::types::AppState,
  client: &str,
  channel: &str,
  messages: &[DemoImMessage],
) {
  let Some(conn) = &state.redis else { return };
  let Ok(envelope) = serde_json::to_string(&serde_json::json!({
    "channel": channel,
    "messages": messages,
  })) else {
    return;
  };
  let _: Result<(), _> =
    redis::AsyncCommands::publish(&mut conn.clone(), im_ws_channel(client, channel), envelope)
      .await
      .inspect_err(|e| tracing::warn!("demo im express publish: {e}"));
}

/// 客服关键词 + 招聘无状态脚本（按访客消息条数推进）。
/// 必须在 im_send 的事务内读（吃 `&mut Transaction`）：用独立连接会
/// 拿到未含当前消息的 MVCC 快照，计数恒差一——第一条就撞进兜底文案。
async fn bot_reply(
  tx: &mut sqlx::Transaction<'_, sqlx::MySql>,
  client: &str,
  channel: &str,
  content: &str,
) -> Result<String, AppError> {
  if channel == "support" {
    let c = content.to_lowercase();
    if c.contains("退款") || c.contains("退货") {
      return Ok(
        "支持 7 天无理由退款：在「订单」页找到对应订单点「申请退款」，1-3 个工作日原路退回。"
          .into(),
      );
    }
    if c.contains("发货") || c.contains("物流") || c.contains("多久") {
      return Ok("工作日 24 小时内发货，顺丰包邮；下单后可在订单详情查看物流单号。".into());
    }
    if c.contains("发票") {
      return Ok("支持电子发票：订单完成后在订单详情页填写抬头即可开具。".into());
    }
    if c.contains("人工") {
      return Ok("已为您转接人工客服（演示环境）——当前排队 0 人，请描述您的问题。".into());
    }
    return Ok("您好，我是演示客服。可以问我：退款、发货时效、发票，或输入「人工」。".into());
  }

  // hiring：无状态脚本——该访客的第 N 条消息对应第 N 个阶段。
  let (visitor_count, first): (i64, Option<String>) = {
    let rows: Vec<(String,)> = sqlx::query_as(
      "SELECT content FROM demo_im_messages WHERE channel = 'hiring' AND client_id = ? AND sender = 'visitor' ORDER BY id",
    )
    .bind(client)
    .fetch_all(&mut **tx)
    .await?;
    let first = rows.first().map(|(c,)| c.clone());
    (rows.len() as i64, first)
  };
  let reply = match visitor_count {
    1 => "您好！很高兴认识您。方便告诉我您的姓名或昵称吗？".to_string(),
    2 => format!(
      "{}，你好！我们这次在看三个方向：后端 / iOS / 前端。你更感兴趣哪个？",
      first.unwrap_or_default()
    ),
    3 => "好的。这个方向你做了几年？最近一年主要在做什么类型的项目？".to_string(),
    4 => "收到！演示流程到此为止——真实场景里这里会把简历要点写入候选人库，并在 3 个工作日内联系你。还有什么想问的吗？".to_string(),
    _ => "（招聘演示脚本已结束）感谢参与，可以用左侧「客服小助」频道继续体验。".to_string(),
  };
  Ok(reply)
}

// ── 论坛演示（发帖 / 点赞 / 评论） ────────────────────────

/// 演示没有用户体系：作者显示 client 前 8 位短 id。
fn short_author(client: &str) -> String {
  client.chars().take(8).collect()
}

async fn forum_post_exists(pool: &MySqlPool, post_id: i64) -> Result<bool, AppError> {
  let row: Option<(i64,)> = sqlx::query_as("SELECT 1 FROM demo_forum_posts WHERE id = ?")
    .bind(post_id)
    .fetch_optional(pool)
    .await?;
  Ok(row.is_some())
}

pub async fn forum_posts(pool: &MySqlPool, client: &str) -> Result<Vec<DemoForumPost>, AppError> {
  // 访客视图：已隐藏帖不出现（审核台走 admin_posts 看全量）。
  let heads: Vec<(i64, String, String, String, NaiveDateTime)> = sqlx::query_as(
    "SELECT id, client_id, title, content, created_at FROM demo_forum_posts
     WHERE hidden = 0 ORDER BY id DESC LIMIT 50",
  )
  .fetch_all(pool)
  .await?;
  let mut posts = Vec::with_capacity(heads.len());
  for (id, owner, title, content, created_at) in heads {
    let (likes,): (i64,) =
      sqlx::query_as("SELECT COUNT(*) FROM demo_forum_likes WHERE post_id = ?")
        .bind(id)
        .fetch_one(pool)
        .await?;
    let (comments,): (i64,) =
      sqlx::query_as("SELECT COUNT(*) FROM demo_forum_comments WHERE post_id = ?")
        .bind(id)
        .fetch_one(pool)
        .await?;
    let liked: Option<(i64,)> =
      sqlx::query_as("SELECT 1 FROM demo_forum_likes WHERE post_id = ? AND client_id = ?")
        .bind(id)
        .bind(client)
        .fetch_optional(pool)
        .await?;
    posts.push(DemoForumPost {
      mine: owner == client,
      author: short_author(&owner),
      likes,
      comments,
      liked_by_me: liked.is_some(),
      id,
      title,
      content,
      created_at,
    });
  }
  Ok(posts)
}

pub async fn forum_create_post(
  pool: &MySqlPool,
  client: &str,
  title: &str,
  content: &str,
) -> Result<DemoForumPost, AppError> {
  let title = title.trim();
  let content = content.trim();
  if title.is_empty() || title.len() > 120 {
    return Err(AppError::Validation("标题须为 1-120 字节".into()));
  }
  if content.is_empty() || content.len() > 2000 {
    return Err(AppError::Validation("正文须为 1-2000 字节".into()));
  }
  let result =
    sqlx::query("INSERT INTO demo_forum_posts (client_id, title, content) VALUES (?, ?, ?)")
      .bind(client)
      .bind(title)
      .bind(content)
      .execute(pool)
      .await?;
  let id = result.last_insert_id() as i64;
  let created_at: (NaiveDateTime,) =
    sqlx::query_as("SELECT created_at FROM demo_forum_posts WHERE id = ?")
      .bind(id)
      .fetch_one(pool)
      .await?;
  Ok(DemoForumPost {
    author: short_author(client),
    mine: true,
    likes: 0,
    liked_by_me: false,
    comments: 0,
    id,
    title: title.to_string(),
    content: content.to_string(),
    created_at: created_at.0,
  })
}

/// 点赞 toggle：有则取消、无则加上（(post, client) 唯一）。
pub async fn forum_toggle_like(
  pool: &MySqlPool,
  client: &str,
  post_id: i64,
) -> Result<LikeResult, AppError> {
  if !forum_post_exists(pool, post_id).await? {
    return Err(AppError::NotFound(format!("帖子不存在: {post_id}")));
  }
  let existing: Option<(i64,)> =
    sqlx::query_as("SELECT 1 FROM demo_forum_likes WHERE post_id = ? AND client_id = ?")
      .bind(post_id)
      .bind(client)
      .fetch_optional(pool)
      .await?;
  if existing.is_some() {
    sqlx::query("DELETE FROM demo_forum_likes WHERE post_id = ? AND client_id = ?")
      .bind(post_id)
      .bind(client)
      .execute(pool)
      .await?;
  } else {
    sqlx::query("INSERT IGNORE INTO demo_forum_likes (post_id, client_id) VALUES (?, ?)")
      .bind(post_id)
      .bind(client)
      .execute(pool)
      .await?;
  }
  let (likes,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM demo_forum_likes WHERE post_id = ?")
    .bind(post_id)
    .fetch_one(pool)
    .await?;
  Ok(LikeResult {
    liked: existing.is_none(),
    likes,
  })
}

pub async fn forum_comments(
  pool: &MySqlPool,
  client: &str,
  post_id: i64,
) -> Result<Vec<DemoForumComment>, AppError> {
  if !forum_post_exists(pool, post_id).await? {
    return Err(AppError::NotFound(format!("帖子不存在: {post_id}")));
  }
  let rows: Vec<(i64, String, String, NaiveDateTime)> = sqlx::query_as(
    "SELECT id, client_id, content, created_at FROM demo_forum_comments WHERE post_id = ? ORDER BY id",
  )
  .bind(post_id)
  .fetch_all(pool)
  .await?;
  Ok(
    rows
      .into_iter()
      .map(|(id, owner, content, created_at)| DemoForumComment {
        mine: owner == client,
        author: short_author(&owner),
        id,
        post_id,
        content,
        created_at,
      })
      .collect(),
  )
}

pub async fn forum_comment(
  pool: &MySqlPool,
  client: &str,
  post_id: i64,
  content: &str,
) -> Result<DemoForumComment, AppError> {
  if !forum_post_exists(pool, post_id).await? {
    return Err(AppError::NotFound(format!("帖子不存在: {post_id}")));
  }
  let content = content.trim();
  if content.is_empty() || content.len() > 500 {
    return Err(AppError::Validation("评论须为 1-500 字节".into()));
  }
  let result =
    sqlx::query("INSERT INTO demo_forum_comments (post_id, client_id, content) VALUES (?, ?, ?)")
      .bind(post_id)
      .bind(client)
      .bind(content)
      .execute(pool)
      .await?;
  let id = result.last_insert_id() as i64;
  let created_at: (NaiveDateTime,) =
    sqlx::query_as("SELECT created_at FROM demo_forum_comments WHERE id = ?")
      .bind(id)
      .fetch_one(pool)
      .await?;
  Ok(DemoForumComment {
    author: short_author(client),
    mine: true,
    id,
    post_id,
    content: content.to_string(),
    created_at: created_at.0,
  })
}

// ── 预约演示（date/bool 字段 + 唯一约束 409 双订保护） ─────

/// 固定时段表（演示）。
pub const BOOKING_SLOTS: [&str; 6] = ["10:00", "11:00", "13:00", "14:00", "15:00", "16:00"];

fn valid_booking_date(date: &str) -> bool {
  // YYYY-MM-DD 且是真实日期
  let parts: Vec<&str> = date.split('-').collect();
  if parts.len() != 3 {
    return false;
  }
  let (Ok(y), Ok(m), Ok(d)) = (
    parts[0].parse::<i32>(),
    parts[1].parse::<u32>(),
    parts[2].parse::<u32>(),
  ) else {
    return false;
  };
  (1..=12).contains(&m) && (1..=31).contains(&d) && (2020..=2100).contains(&y)
}

pub async fn booking_slots(pool: &MySqlPool, date: &str) -> Result<DemoSlotsResp, AppError> {
  if !valid_booking_date(date) {
    return Err(AppError::Validation("日期格式须为 YYYY-MM-DD".into()));
  }
  let taken: Vec<(String,)> =
    sqlx::query_as("SELECT slot FROM demo_bookings WHERE booking_date = ?")
      .bind(date)
      .fetch_all(pool)
      .await?;
  let taken: Vec<String> = taken.into_iter().map(|(s,)| s).collect();
  Ok(DemoSlotsResp {
    date: date.to_string(),
    slots: BOOKING_SLOTS
      .iter()
      .map(|t| DemoSlot {
        time: t.to_string(),
        available: !taken.contains(&t.to_string()),
      })
      .collect(),
  })
}

/// 预约：唯一约束 (booking_date, slot) 兜底双订——sqlx 唯一键冲突
/// 自动映射 409（errors.rs 的 From<sqlx::Error>）。
pub async fn booking_book(
  pool: &MySqlPool,
  client: &str,
  date: &str,
  slot: &str,
  name: &str,
) -> Result<DemoBooking, AppError> {
  if !valid_booking_date(date) {
    return Err(AppError::Validation("日期格式须为 YYYY-MM-DD".into()));
  }
  if !BOOKING_SLOTS.contains(&slot) {
    return Err(AppError::Validation(format!("时段无效: {slot}")));
  }
  let name = name.trim();
  if name.is_empty() || name.len() > 64 {
    return Err(AppError::Validation("姓名须为 1-64 字节".into()));
  }
  sqlx::query(
    "INSERT INTO demo_bookings (client_id, booking_date, slot, guest_name) VALUES (?, ?, ?, ?)",
  )
  .bind(client)
  .bind(date)
  .bind(slot)
  .bind(name)
  .execute(pool)
  .await?;
  let (id, created_at): (i64, NaiveDateTime) =
    sqlx::query_as("SELECT id, created_at FROM demo_bookings WHERE booking_date = ? AND slot = ?")
      .bind(date)
      .bind(slot)
      .fetch_one(pool)
      .await?;
  Ok(DemoBooking {
    id,
    date: date.to_string(),
    slot: slot.to_string(),
    guest: name.to_string(),
    created_at,
  })
}

pub async fn bookings_mine(pool: &MySqlPool, client: &str) -> Result<Vec<DemoBooking>, AppError> {
  // DATE 列不能直接解到 String——SQL 里格式化成文本（YYYY-MM-DD）
  let rows: Vec<(i64, String, String, String, NaiveDateTime)> = sqlx::query_as(
    "SELECT id, DATE_FORMAT(booking_date, '%Y-%m-%d'), slot, guest_name, created_at
     FROM demo_bookings WHERE client_id = ? ORDER BY id DESC LIMIT 20",
  )
  .bind(client)
  .fetch_all(pool)
  .await?;
  Ok(
    rows
      .into_iter()
      .map(|(id, date, slot, guest, created_at)| DemoBooking {
        id,
        date,
        slot,
        guest,
        created_at,
      })
      .collect(),
  )
}

// ── 资讯演示（确定性合成，无表 → 分布式天然一致） ─────────

const NEWS_CATEGORIES: [&str; 4] = ["产品", "技术", "社区", "公告"];

pub fn news_page(page: u32) -> DemoArticlesPage {
  let per_page = 6u32;
  let total = 24u32;
  let total_pages = total.div_ceil(per_page);
  let page = page.clamp(1, total_pages);
  let start = (page - 1) * per_page;
  let base = chrono::Utc::now().date_naive();
  let items = (start..(start + per_page).min(total))
    .map(|i| {
      let idx = i as usize;
      let title = [
        "DPP 接入指南（示例第 {n} 篇）",
        "演示环境更新说明 {n}",
        "结构化读取最佳实践 {n}",
        "页面事件驱动实战 {n}",
        "动作声明与审批流 {n}",
        "站点级配置入门 {n}",
      ][idx % 6]
        .replace("{n}", &(i + 1).to_string());
      let summary = format!(
        "这是演示资讯的第 {} 篇——内容由服务端确定性合成，用于演示分页收集与 date 字段，不含真实新闻。",
        i + 1
      );
      DemoArticle {
        id: i as i64 + 1,
        title,
        category: NEWS_CATEGORIES[idx % 4].to_string(),
        summary,
        date: (base - chrono::Duration::days(i as i64)).to_string(),
      }
    })
    .collect();
  DemoArticlesPage {
    page,
    total_pages,
    items,
  }
}

// ── 看板演示（聚合其他 demo 表的行数/金额） ───────────────

pub async fn stats(pool: &MySqlPool) -> Result<DemoStats, AppError> {
  let (orders,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM demo_orders")
    .fetch_one(pool)
    .await?;
  // SUM 对 INT 返回 DECIMAL——CAST 成 SIGNED 才能解进 i64
  let (gmv_cents,): (i64,) =
    sqlx::query_as("SELECT CAST(COALESCE(SUM(total_cents), 0) AS SIGNED) FROM demo_orders")
      .fetch_one(pool)
      .await?;
  let (bookings,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM demo_bookings")
    .fetch_one(pool)
    .await?;
  let (messages,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM demo_im_messages")
    .fetch_one(pool)
    .await?;
  let (posts,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM demo_forum_posts")
    .fetch_one(pool)
    .await?;
  let (likes,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM demo_forum_likes")
    .fetch_one(pool)
    .await?;
  Ok(DemoStats {
    metrics: vec![
      DemoMetric {
        key: "orders".into(),
        name: "累计订单".into(),
        value: orders,
        unit: "单".into(),
      },
      DemoMetric {
        key: "gmv".into(),
        name: "演示流水".into(),
        value: gmv_cents,
        unit: "分".into(),
      },
      DemoMetric {
        key: "bookings".into(),
        name: "预约数".into(),
        value: bookings,
        unit: "个".into(),
      },
      DemoMetric {
        key: "im".into(),
        name: "IM 消息".into(),
        value: messages,
        unit: "条".into(),
      },
      DemoMetric {
        key: "posts".into(),
        name: "论坛帖子".into(),
        value: posts,
        unit: "篇".into(),
      },
      DemoMetric {
        key: "likes".into(),
        name: "获赞".into(),
        value: likes,
        unit: "次".into(),
      },
    ],
  })
}

// ── 审核台演示（论坛帖子治理） ────────────────────────────

/// 审核台：全量帖子（含已隐藏）+ 计数。
pub async fn admin_posts(pool: &MySqlPool) -> Result<Vec<DemoAdminPost>, AppError> {
  let heads: Vec<(i64, String, String, String, bool, NaiveDateTime)> = sqlx::query_as(
    "SELECT id, client_id, title, content, hidden, created_at FROM demo_forum_posts ORDER BY id DESC LIMIT 100",
  )
  .fetch_all(pool)
  .await?;
  let mut posts = Vec::with_capacity(heads.len());
  for (id, owner, title, content, hidden, created_at) in heads {
    let (likes,): (i64,) =
      sqlx::query_as("SELECT COUNT(*) FROM demo_forum_likes WHERE post_id = ?")
        .bind(id)
        .fetch_one(pool)
        .await?;
    let (comments,): (i64,) =
      sqlx::query_as("SELECT COUNT(*) FROM demo_forum_comments WHERE post_id = ?")
        .bind(id)
        .fetch_one(pool)
        .await?;
    posts.push(DemoAdminPost {
      author: short_author(&owner),
      likes,
      comments,
      hidden,
      id,
      title,
      content,
      created_at,
    });
  }
  Ok(posts)
}

/// 隐藏/恢复（0/1 位切换）。
pub async fn admin_set_hidden(
  pool: &MySqlPool,
  post_id: i64,
  hidden: bool,
) -> Result<(), AppError> {
  let result = sqlx::query("UPDATE demo_forum_posts SET hidden = ? WHERE id = ?")
    .bind(hidden)
    .bind(post_id)
    .execute(pool)
    .await?;
  if result.rows_affected() == 0 {
    return Err(AppError::NotFound(format!("帖子不存在: {post_id}")));
  }
  Ok(())
}

/// 删除：帖子 + 关联评论/点赞一并清（事务）。danger 动作的后端本体。
pub async fn admin_delete_post(pool: &MySqlPool, post_id: i64) -> Result<(), AppError> {
  let mut tx = pool.begin().await?;
  sqlx::query("DELETE FROM demo_forum_comments WHERE post_id = ?")
    .bind(post_id)
    .execute(&mut *tx)
    .await?;
  sqlx::query("DELETE FROM demo_forum_likes WHERE post_id = ?")
    .bind(post_id)
    .execute(&mut *tx)
    .await?;
  let result = sqlx::query("DELETE FROM demo_forum_posts WHERE id = ?")
    .bind(post_id)
    .execute(&mut *tx)
    .await?;
  if result.rows_affected() == 0 {
    return Err(AppError::NotFound(format!("帖子不存在: {post_id}")));
  }
  tx.commit().await?;
  Ok(())
}

// ── 入驻向导演示 ─────────────────────────────────────────

pub async fn wizard_apply(
  pool: &MySqlPool,
  client: &str,
  shop: &str,
  category: &str,
  contact: &str,
  phone: &str,
) -> Result<DemoWizardApp, AppError> {
  let (shop, category, contact, phone) =
    (shop.trim(), category.trim(), contact.trim(), phone.trim());
  if shop.is_empty() || shop.len() > 64 {
    return Err(AppError::Validation("店铺名须为 1-64 字节".into()));
  }
  if category.is_empty() || category.len() > 32 {
    return Err(AppError::Validation("类目须为 1-32 字节".into()));
  }
  if contact.is_empty() || contact.len() > 64 {
    return Err(AppError::Validation("联系人须为 1-64 字节".into()));
  }
  if phone.is_empty() || phone.len() > 32 {
    return Err(AppError::Validation("电话须为 1-32 字节".into()));
  }
  let result = sqlx::query(
    "INSERT INTO demo_wizard_applications (client_id, shop, category, contact, phone) VALUES (?, ?, ?, ?, ?)",
  )
  .bind(client)
  .bind(shop)
  .bind(category)
  .bind(contact)
  .bind(phone)
  .execute(pool)
  .await?;
  let id = result.last_insert_id() as i64;
  let (created_at,): (NaiveDateTime,) =
    sqlx::query_as("SELECT created_at FROM demo_wizard_applications WHERE id = ?")
      .bind(id)
      .fetch_one(pool)
      .await?;
  Ok(DemoWizardApp {
    contact: contact.to_string(),
    category: category.to_string(),
    phone: phone.to_string(),
    shop: shop.to_string(),
    id,
    created_at,
  })
}

pub async fn wizard_mine(pool: &MySqlPool, client: &str) -> Result<Vec<DemoWizardApp>, AppError> {
  let rows: Vec<(i64, String, String, String, String, NaiveDateTime)> = sqlx::query_as(
    "SELECT id, shop, category, contact, phone, created_at FROM demo_wizard_applications
     WHERE client_id = ? ORDER BY id DESC LIMIT 20",
  )
  .bind(client)
  .fetch_all(pool)
  .await?;
  Ok(
    rows
      .into_iter()
      .map(
        |(id, shop, category, contact, phone, created_at)| DemoWizardApp {
          contact,
          category,
          phone,
          shop,
          id,
          created_at,
        },
      )
      .collect(),
  )
}
