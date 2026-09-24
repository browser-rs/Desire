//! Redis 缓存基建(可选组件)。
//!
//! 定位:Redis 只是加速器,不是依赖 —— `DESIRE_REDIS_URL` 未配置(Option 为 None)
//! 或运行中连接失败,一律静默降级直连数据源,绝不因缓存层报错打挂业务。
//! 唯一要求是"缓存里的值必须可失效":写方更新后主动 DEL,
//! 读方以短 TTL 兜底,两层配合保证最终一致。

use redis::AsyncCommands;
use redis::aio::ConnectionManager;
use serde::{Serialize, de::DeserializeOwned};

pub type RedisConn = ConnectionManager;

/// 连接 Redis;失败返回 None(调用方降级)。ConnectionManager 自带断线重连。
pub async fn connect(url: &str) -> Option<ConnectionManager> {
  let client = match redis::Client::open(url) {
    Ok(c) => c,
    Err(e) => {
      tracing::error!("redis url invalid (running WITHOUT cache): {e}");
      return None;
    }
  };
  match ConnectionManager::new(client).await {
    Ok(conn) => Some(conn),
    Err(e) => {
      tracing::error!("redis connect failed (running WITHOUT cache): {e}");
      None
    }
  }
}

/// 读缓存;未配置 / 未命中 / 反序列化失败 / 连接错误 → None(降级读源)
pub async fn get_json<T: DeserializeOwned>(
  redis: &Option<ConnectionManager>,
  key: &str,
) -> Option<T> {
  let mut conn = redis.as_ref()?.clone();
  let raw: Option<String> = conn.get(key).await.ok()?;
  serde_json::from_str(&raw?).ok()
}

/// 写缓存(TTL 秒);未配置 / 失败只记 warn,不影响业务
pub async fn set_json(
  redis: &Option<ConnectionManager>,
  key: &str,
  value: &impl Serialize,
  ttl_secs: u64,
) {
  if let Some(conn) = redis {
    let body = match serde_json::to_string(value) {
      Ok(b) => b,
      Err(e) => {
        tracing::warn!("cache serialize {key}: {e}");
        return;
      }
    };
    let mut conn = conn.clone();
    let _: () = conn.set_ex(key, body, ttl_secs).await.unwrap_or_else(|e| {
      tracing::warn!("cache set {key}: {e}");
    });
  }
}

/// 删缓存(写方更新后失效);失败只记 warn,由读方 TTL 兜底
pub async fn del(redis: &Option<ConnectionManager>, key: &str) {
  if let Some(conn) = redis {
    let mut conn = conn.clone();
    let _: () = conn.del(key).await.unwrap_or_else(|e| {
      tracing::warn!("cache del {key}: {e}");
    });
  }
}
