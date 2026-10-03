//! Demo 商店的进程内内存态——不落库、重启即重置，刻意不进 MySQL。
//! 只服务 website/demo 的 DPP 演示：无鉴权、无敏感数据，所以用
//! OnceLock + 全局 Mutex，不动 AppState；客户端以 `X-Demo-Client`
//! 头区分各自的购物车与订单（页面在 localStorage 里生成 UUID）。

use std::collections::HashMap;
use std::sync::OnceLock;

use tokio::sync::Mutex;

use super::demo_model::{DemoCartLine, DemoCartSnapshot, DemoOrder, DemoProduct};
use crate::errors::AppError;

struct DemoStore {
  /// client id → 购物车行
  carts: HashMap<String, Vec<DemoCartLine>>,
  /// (client id, 订单)，新的在前
  orders: Vec<(String, DemoOrder)>,
  seq: u64,
}

fn store() -> &'static Mutex<DemoStore> {
  static STORE: OnceLock<Mutex<DemoStore>> = OnceLock::new();
  STORE.get_or_init(|| {
    Mutex::new(DemoStore {
      carts: HashMap::new(),
      orders: Vec::new(),
      seq: 0,
    })
  })
}

/// 固定演示目录。价格是演示数据，非真实在售商品。
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

fn snapshot(lines: &[DemoCartLine]) -> DemoCartSnapshot {
  DemoCartSnapshot {
    count: lines.iter().map(|l| l.qty).sum(),
    total: round2(lines.iter().map(|l| l.subtotal).sum()),
    items: lines.to_vec(),
  }
}

pub async fn cart_get(client: &str) -> DemoCartSnapshot {
  let st = store().lock().await;
  snapshot(st.carts.get(client).map(|v| v.as_slice()).unwrap_or(&[]))
}

pub async fn cart_add(client: &str, sku: &str, qty: u32) -> Result<DemoCartSnapshot, AppError> {
  let product =
    find_product(sku).ok_or_else(|| AppError::NotFound(format!("商品不存在: {sku}")))?;
  let qty = qty.clamp(1, 99);
  let mut st = store().lock().await;
  let lines = st.carts.entry(client.to_string()).or_default();
  if let Some(line) = lines.iter_mut().find(|l| l.sku == sku) {
    line.qty = (line.qty + qty).min(99);
    line.subtotal = round2(line.price * line.qty as f64);
  } else {
    lines.push(DemoCartLine {
      sku: product.sku,
      name: product.name,
      price: product.price,
      qty,
      subtotal: round2(product.price * qty as f64),
    });
  }
  Ok(snapshot(lines))
}

pub async fn cart_remove(client: &str, sku: &str) -> Result<DemoCartSnapshot, AppError> {
  let mut st = store().lock().await;
  let Some(lines) = st.carts.get_mut(client) else {
    return Err(AppError::NotFound("购物车里没有这个商品".into()));
  };
  let before = lines.len();
  lines.retain(|l| l.sku != sku);
  if lines.len() == before {
    return Err(AppError::NotFound(format!("购物车里没有商品: {sku}")));
  }
  Ok(snapshot(lines))
}

pub async fn checkout(client: &str) -> Result<DemoOrder, AppError> {
  let mut st = store().lock().await;
  let Some(lines) = st.carts.get_mut(client) else {
    return Err(AppError::Validation("购物车为空".into()));
  };
  if lines.is_empty() {
    return Err(AppError::Validation("购物车为空".into()));
  }
  let count: u32 = lines.iter().map(|l| l.qty).sum();
  let total = round2(lines.iter().map(|l| l.subtotal).sum());
  let items = std::mem::take(lines);
  st.seq += 1;
  let order = DemoOrder {
    id: format!("D-{:06}", st.seq),
    count,
    total,
    items,
    created_at: chrono::Utc::now(),
  };
  st.orders.insert(0, (client.to_string(), order.clone()));
  Ok(order)
}

pub async fn orders_get(client: &str) -> Vec<DemoOrder> {
  let st = store().lock().await;
  st.orders
    .iter()
    .filter(|(owner, _)| owner == client)
    .map(|(_, o)| o.clone())
    .collect()
}

fn round2(v: f64) -> f64 {
  (v * 100.0).round() / 100.0
}
