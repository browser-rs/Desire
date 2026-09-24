use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

/// 开放同步的域(白名单)。约定:
/// - bookmarks/quickdials/reading_list/keyboard_shortcuts:client_id = 客户端生成的
///   稳定 UUID,payload = 条目本体(含排序/父子关系等,服务端不解读);
/// - settings:client_id = 设置键名,payload = 值本体。
pub const DOMAINS: &[&str] = &[
  "bookmarks",
  "quickdials",
  "reading_list",
  "keyboard_shortcuts",
  "settings",
];

pub fn is_valid_domain(domain: &str) -> bool {
  DOMAINS.contains(&domain)
}

#[derive(Debug, Deserialize, ToSchema)]
pub struct SyncPushItem {
  /// 客户端侧稳定 ID(≤64 字符)
  pub client_id: String,
  /// 客户端本地最后修改时间(墙上时钟,LWW 仲裁依据;服务端时间不参与)
  pub client_updated_at: chrono::NaiveDateTime,
  /// true = 删除(tombstone):payload 落库时置 NULL
  #[serde(default)]
  pub deleted: bool,
  /// 域自定义 JSON,服务端不解读
  #[serde(default)]
  pub payload: Option<serde_json::Value>,
}

#[derive(Debug, Deserialize, ToSchema)]
pub struct SyncPushReq {
  /// 单批 ≤500 条
  pub items: Vec<SyncPushItem>,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct SyncItemDto {
  /// 服务端行 id——复合拉取游标的第二分量(客户端游标 = `updated_at|id`)
  pub id: i64,
  pub client_id: String,
  pub client_updated_at: chrono::NaiveDateTime,
  pub deleted: bool,
  /// tombstone 行不带 payload
  #[serde(skip_serializing_if = "Option::is_none")]
  pub payload: Option<serde_json::Value>,
  /// 服务端写入时间;拉取游标按它推进(严格大于)
  pub updated_at: chrono::NaiveDateTime,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct SyncPullResp {
  pub items: Vec<SyncItemDto>,
  pub server_time: chrono::NaiveDateTime,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct SyncPushResultItem {
  pub client_id: String,
  /// applied = 采纳本次推送;conflict = 服务端版本更新(item 给回胜出版本,客户端应采纳)
  pub status: String,
  #[serde(skip_serializing_if = "Option::is_none")]
  pub item: Option<SyncItemDto>,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct SyncPushResp {
  pub results: Vec<SyncPushResultItem>,
  pub server_time: chrono::NaiveDateTime,
}

/// 数据库行(payload 经 CAST(payload AS CHAR) 取出,sqlx 0.9 不能直接解 JSON 列)
#[derive(Debug, Clone, sqlx::FromRow)]
pub struct SyncRowRaw {
  pub id: i64,
  pub client_id: String,
  pub client_updated_at: chrono::NaiveDateTime,
  pub deleted_at: Option<chrono::NaiveDateTime>,
  pub payload_str: Option<String>,
  pub updated_at: chrono::NaiveDateTime,
}

impl SyncRowRaw {
  pub fn into_dto(self) -> Result<SyncItemDto, serde_json::Error> {
    let payload = match self.payload_str {
      None => None,
      Some(s) => Some(serde_json::from_str::<serde_json::Value>(&s)?),
    };
    Ok(SyncItemDto {
      id: self.id,
      client_id: self.client_id,
      client_updated_at: self.client_updated_at,
      deleted: self.deleted_at.is_some(),
      payload,
      updated_at: self.updated_at,
    })
  }
}

pub const MAX_PUSH_ITEMS: usize = 500;
/// 单条 payload 上限(JSON 字节数;书签/快拨等条目实际远小于此)
pub const MAX_PAYLOAD_BYTES: usize = 256 * 1024;
/// 拉取单批上限;客户端把游标推进到末条的 (updated_at, id)
pub const PULL_LIMIT: i64 = 1000;
