use chrono::{NaiveDate, NaiveDateTime};
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

/// 匿名增长事件（POST /growth/event）。字段全部可空；服务端只做长度截断，
/// **不落 IP/Cookie/UA/设备标识**。
#[derive(Debug, Deserialize, ToSchema)]
pub struct GrowthEventReq {
  /// page_view | download_click | first_launch
  pub event: String,
  #[serde(default)]
  pub source: String,
  #[serde(default)]
  pub medium: String,
  #[serde(default)]
  pub campaign: String,
  #[serde(default)]
  pub content: String,
  #[serde(default)]
  pub path: String,
  #[serde(default)]
  pub app_version: String,
}

#[derive(Debug, Default, Serialize, ToSchema)]
pub struct GrowthBucket {
  pub page_view: i64,
  pub download_click: i64,
  pub first_launch: i64,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct GrowthDay {
  pub day: NaiveDate,
  pub page_view: i64,
  pub download_click: i64,
  pub first_launch: i64,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct GrowthBreakdown {
  /// 战役名或来源名（campaig / source 各自一列）
  pub key: String,
  pub page_view: i64,
  pub download_click: i64,
  pub first_launch: i64,
}

#[derive(Debug, Serialize, ToSchema)]
pub struct GrowthSummary {
  pub days: u32,
  pub totals: GrowthBucket,
  /// 只返回有事件的日期（客户端自行补零）。
  pub daily: Vec<GrowthDay>,
  pub campaigns: Vec<GrowthBreakdown>,
  pub sources: Vec<GrowthBreakdown>,
  /// 最近一条事件时间（用于"归因已配置/JWT 可读"的空态判断）。
  pub last_event_at: Option<NaiveDateTime>,
}
