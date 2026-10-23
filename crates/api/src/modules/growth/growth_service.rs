use std::collections::HashMap;

use chrono::{Duration, NaiveDate, NaiveDateTime, Utc};
use sqlx::MySqlPool;

use crate::errors::AppError;

use super::growth_model::{
  GrowthBreakdown, GrowthBucket, GrowthDay, GrowthEventReq, GrowthSummary,
};

pub const ALLOWED_EVENTS: &[&str] = &["page_view", "download_click", "first_launch"];
const MAX_DAYS: u32 = 180;

pub fn validate_event(event: &str) -> Result<(), AppError> {
  if ALLOWED_EVENTS.contains(&event) {
    Ok(())
  } else {
    Err(AppError::Validation(format!(
      "unknown growth event '{event}' (allowed: {})",
      ALLOWED_EVENTS.join(", ")
    )))
  }
}

fn clean(value: &str, max: usize) -> String {
  value.trim().chars().take(max).collect()
}

pub async fn record_event(pool: &MySqlPool, req: GrowthEventReq) -> Result<(), AppError> {
  validate_event(&req.event)?;
  let now = Utc::now().naive_utc();
  let day = now.date();
  sqlx::query(
    "INSERT INTO growth_events \
     (event, source, medium, campaign, content, path, app_version, day, occurred_at) \
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
  )
  .bind(&req.event)
  .bind(clean(&req.source, 64))
  .bind(clean(&req.medium, 32))
  .bind(clean(&req.campaign, 64))
  .bind(clean(&req.content, 64))
  .bind(clean(&req.path, 255))
  .bind(clean(&req.app_version, 32))
  .bind(day)
  .bind(now)
  .execute(pool)
  .await?;
  Ok(())
}

fn add(bucket: &mut GrowthBucket, event: &str, count: i64) {
  match event {
    "page_view" => bucket.page_view += count,
    "download_click" => bucket.download_click += count,
    "first_launch" => bucket.first_launch += count,
    _ => {}
  }
}

fn total(bucket: &GrowthBucket) -> i64 {
  bucket.page_view + bucket.download_click + bucket.first_launch
}

pub async fn summary(pool: &MySqlPool, days: u32) -> Result<GrowthSummary, AppError> {
  let days = days.clamp(1, MAX_DAYS);
  let since = Utc::now().date_naive() - Duration::days((days - 1) as i64);

  let totals_rows: Vec<(String, i64)> =
    sqlx::query_as("SELECT event, COUNT(*) FROM growth_events WHERE day >= ? GROUP BY event")
      .bind(since)
      .fetch_all(pool)
      .await?;
  let mut totals = GrowthBucket::default();
  for (event, count) in &totals_rows {
    add(&mut totals, event, *count);
  }

  let daily_rows: Vec<(NaiveDate, String, i64)> = sqlx::query_as(
    "SELECT day, event, COUNT(*) FROM growth_events \
     WHERE day >= ? GROUP BY day, event ORDER BY day",
  )
  .bind(since)
  .fetch_all(pool)
  .await?;
  let mut daily_map: HashMap<NaiveDate, GrowthBucket> = HashMap::new();
  for (day, event, count) in daily_rows {
    add(daily_map.entry(day).or_default(), &event, count);
  }
  let mut daily: Vec<GrowthDay> = daily_map
    .into_iter()
    .map(|(day, bucket)| GrowthDay {
      day,
      page_view: bucket.page_view,
      download_click: bucket.download_click,
      first_launch: bucket.first_launch,
    })
    .collect();
  daily.sort_by_key(|d| d.day);

  let campaigns = breakdown(pool, "campaign", since).await?;
  let sources = breakdown(pool, "source", since).await?;

  let last_event_at: Option<NaiveDateTime> =
    sqlx::query_scalar("SELECT MAX(occurred_at) FROM growth_events WHERE day >= ?")
      .bind(since)
      .fetch_one(pool)
      .await?;

  Ok(GrowthSummary {
    days,
    totals,
    daily,
    campaigns,
    sources,
    last_event_at,
  })
}

async fn breakdown(
  pool: &MySqlPool,
  column: &str,
  since: NaiveDate,
) -> Result<Vec<GrowthBreakdown>, AppError> {
  // 列名来自本文件的字面量（不是用户输入）；sqlx 不允许动态列名绑定，
  // 用两条固定 SQL 避免拼接面。
  let rows: Vec<(String, String, i64)> = if column == "campaign" {
    sqlx::query_as(
      "SELECT campaign, event, COUNT(*) FROM growth_events \
       WHERE day >= ? AND campaign <> '' GROUP BY campaign, event",
    )
    .bind(since)
    .fetch_all(pool)
    .await?
  } else {
    sqlx::query_as(
      "SELECT source, event, COUNT(*) FROM growth_events \
       WHERE day >= ? AND source <> '' GROUP BY source, event",
    )
    .bind(since)
    .fetch_all(pool)
    .await?
  };
  let mut map: HashMap<String, GrowthBucket> = HashMap::new();
  for (key, event, count) in rows {
    add(map.entry(key).or_default(), &event, count);
  }
  let mut out: Vec<GrowthBreakdown> = map
    .into_iter()
    .map(|(key, bucket)| GrowthBreakdown {
      key,
      page_view: bucket.page_view,
      download_click: bucket.download_click,
      first_launch: bucket.first_launch,
    })
    .collect();
  out.sort_by(|a, b| {
    let ta = GrowthBucket {
      page_view: a.page_view,
      download_click: a.download_click,
      first_launch: a.first_launch,
    };
    let tb = GrowthBucket {
      page_view: b.page_view,
      download_click: b.download_click,
      first_launch: b.first_launch,
    };
    total(&tb).cmp(&total(&ta)).then_with(|| a.key.cmp(&b.key))
  });
  out.truncate(20);
  Ok(out)
}

#[cfg(test)]
mod tests {
  use super::{GrowthBucket, add, total, validate_event};

  #[test]
  fn event_whitelist() {
    assert!(validate_event("page_view").is_ok());
    assert!(validate_event("download_click").is_ok());
    assert!(validate_event("first_launch").is_ok());
    assert!(validate_event("purchase").is_err());
  }

  #[test]
  fn bucket_adds() {
    let mut bucket = GrowthBucket::default();
    add(&mut bucket, "page_view", 3);
    add(&mut bucket, "download_click", 2);
    add(&mut bucket, "first_launch", 1);
    add(&mut bucket, "unknown", 99);
    assert_eq!(bucket.page_view, 3);
    assert_eq!(bucket.download_click, 2);
    assert_eq!(bucket.first_launch, 1);
    assert_eq!(total(&bucket), 6);
  }
}
