-- 增长归因（v0.8.3）：匿名事件。只存事件/来源/战役/内容/路径/版本与时间，
-- **不存 IP、Cookie、UA、设备指纹或任何用户标识**；用于匿名聚合漏斗。
CREATE TABLE IF NOT EXISTS growth_events (
  id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  event VARCHAR(32) NOT NULL,
  source VARCHAR(64) NOT NULL DEFAULT '',
  medium VARCHAR(32) NOT NULL DEFAULT '',
  campaign VARCHAR(64) NOT NULL DEFAULT '',
  content VARCHAR(64) NOT NULL DEFAULT '',
  path VARCHAR(255) NOT NULL DEFAULT '',
  app_version VARCHAR(32) NOT NULL DEFAULT '',
  day DATE NOT NULL,
  occurred_at DATETIME(6) NOT NULL,
  created_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (id),
  KEY idx_growth_day_event (day, event),
  KEY idx_growth_campaign (campaign, day),
  KEY idx_growth_source (source, day)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_unicode_ci;
