use sha2::{Digest, Sha256};
use uuid::Uuid;

pub fn generate() -> String {
  Uuid::new_v4().simple().to_string()
}

pub fn hash_token(token: &str) -> String {
  hex::encode(Sha256::digest(token.as_bytes()))
}

#[cfg(test)]
mod tests {
  use super::*;

  #[test]
  fn generate_produces_unique_values() {
    let a = generate();
    let b = generate();
    assert_ne!(a, b);
    assert_eq!(a.len(), 32);
  }

  #[test]
  fn hash_is_deterministic() {
    assert_eq!(hash_token("abc"), hash_token("abc"));
    assert_eq!(hash_token("abc").len(), 64);
    assert_ne!(hash_token("abc"), hash_token("abd"));
  }
}
