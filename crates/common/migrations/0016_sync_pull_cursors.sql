-- v0.7.20 通用 tombstone GC:设备拉取游标台账(2026-10-17)。
-- 拉取侧带 device 参数时把该设备的复合游标(updated_at,id)记进这里;
-- GC 只删"所有活跃设备都已越过 + 超过宽限期"的墓碑,防旧设备复活已删
-- 条目。cursor_id 为 NULL = 旧版 ts-only 客户端语义(视为已见该时刻全部
-- 行)。seen_at 用于活跃判定(180 天没拉过的设备不再挡 GC,其残留复活
-- 风险已在 sync_gc 模块头注释与文档里写明)。
CREATE TABLE IF NOT EXISTS `sync_pull_cursors` (
  `user_id` bigint NOT NULL,
  `domain` varchar(32) NOT NULL,
  `device_id` varchar(64) NOT NULL,
  `cursor_updated_at` datetime(6) DEFAULT NULL,
  `cursor_id` bigint DEFAULT NULL,
  `seen_at` datetime(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (`user_id`,`domain`,`device_id`),
  KEY `idx_sync_cursor_user` (`user_id`,`domain`,`seen_at`),
  CONSTRAINT `fk_sync_cursor_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
