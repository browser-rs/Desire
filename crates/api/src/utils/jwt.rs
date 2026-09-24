use chrono::{Duration, Utc};
use jsonwebtoken::{Algorithm, DecodingKey, EncodingKey, Header, Validation, decode, encode};
use serde::{Deserialize, Serialize};

use crate::errors::AppError;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Claims {
  pub sub: i64,
  pub exp: usize,
}

pub fn create_token(sub: i64, ttl: Duration, secret: &str) -> Result<String, AppError> {
  let exp = (Utc::now() + ttl).timestamp() as usize;
  let claims = Claims { sub, exp };
  encode(
    &Header::default(),
    &claims,
    &EncodingKey::from_secret(secret.as_bytes()),
  )
  .map_err(|e| AppError::Internal(format!("jwt encode failed: {e}")))
}

pub fn parse_token(token: &str, secret: &str) -> Result<Claims, AppError> {
  decode::<Claims>(
    token,
    &DecodingKey::from_secret(secret.as_bytes()),
    &Validation::new(Algorithm::HS256),
  )
  .map(|d| d.claims)
  .map_err(|_| AppError::Unauthorized("invalid or expired token".into()))
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn encode_decode_roundtrip() {
    let t = create_token(7, Duration::hours(1), "secret").unwrap();
    let c = parse_token(&t, "secret").unwrap();
    assert_eq!(c.sub, 7);
  }

  #[test]
  fn expired_token_is_rejected() {
    let t = create_token(7, Duration::seconds(-70), "secret").unwrap();
    assert!(matches!(
      parse_token(&t, "secret"),
      Err(AppError::Unauthorized(_))
    ));
  }
}
