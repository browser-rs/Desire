use chrono::{Duration, Utc};
use jsonwebtoken::{Algorithm, DecodingKey, EncodingKey, Header, Validation, decode, encode};
use serde::{Deserialize, Serialize};

use crate::errors::AppError;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Claims {
  pub sub: i64,
  pub exp: usize,
  /// 用户级 token 版本（改密/全设备吊销即 +1，旧 access token 立刻失效）。
  #[serde(default)]
  pub ver: i64,
  /// 签发的设备行 id（无设备绑定的旧 token = None）。
  #[serde(default, skip_serializing_if = "Option::is_none")]
  pub dev: Option<i64>,
  /// 设备级 token 版本（logout/单设备吊销即 +1）。
  #[serde(default)]
  pub dver: i64,
}

pub fn create_token(
  sub: i64,
  ver: i64,
  dev: Option<i64>,
  dver: i64,
  ttl: Duration,
  secret: &str,
) -> Result<String, AppError> {
  let exp = (Utc::now() + ttl).timestamp() as usize;
  let claims = Claims {
    sub,
    exp,
    ver,
    dev,
    dver,
  };
  // jsonwebtoken 12：from_secret 返回 Result（空 secret 报 InvalidKeyFormat）。
  let key = EncodingKey::from_secret(secret.as_bytes())
    .map_err(|e| AppError::Internal(format!("jwt key build failed: {e}")))?;
  encode(&Header::default(), &claims, &key)
    .map_err(|e| AppError::Internal(format!("jwt encode failed: {e}")))
}

pub fn parse_token(token: &str, secret: &str) -> Result<Claims, AppError> {
  let key = DecodingKey::from_secret(secret.as_bytes())
    .map_err(|_| AppError::Unauthorized("invalid or expired token".into()))?;
  decode::<Claims>(token, &key, &Validation::new(Algorithm::HS256))
    .map(|d| d.claims)
    .map_err(|_| AppError::Unauthorized("invalid or expired token".into()))
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn encode_decode_roundtrip() {
    let t = create_token(7, 3, Some(9), 2, Duration::hours(1), "secret").unwrap();
    let c = parse_token(&t, "secret").unwrap();
    assert_eq!(c.sub, 7);
    assert_eq!(c.ver, 3);
    assert_eq!(c.dev, Some(9));
    assert_eq!(c.dver, 2);
  }

  #[test]
  fn expired_token_is_rejected() {
    let t = create_token(7, 0, None, 0, Duration::seconds(-70), "secret").unwrap();
    assert!(matches!(
      parse_token(&t, "secret"),
      Err(AppError::Unauthorized(_))
    ));
  }
}
