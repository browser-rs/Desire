-- v0.8.80 API 运营面（批 7）：
-- 1) token 版本：用户级（改密/全设备吊销）与设备级（logout/单设备吊销）即时失效
--    access token，不再等 ≤2h 自然过期。
-- 2) 恢复码：忘记密码时用一次性恢复码重置（只存 bcrypt 哈希）。
-- 3) 审计事件：账号安全相关动作留痕（服务端可读；不含同步明文）。
-- 4) 原子日配额：单用户/日的计数行，push 在同一事务里 FOR UPDATE 预留。
ALTER TABLE `users`
  ADD COLUMN `token_version` bigint NOT NULL DEFAULT 0,
  ADD COLUMN `recovery_hash` varchar(255) NULL;

ALTER TABLE `devices`
  ADD COLUMN `token_version` bigint NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS `audit_events` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `user_id` bigint NULL,
  `event` varchar(64) NOT NULL,
  `detail` varchar(255) NOT NULL DEFAULT '',
  `ip` varchar(64) NOT NULL DEFAULT '',
  `created_at` datetime(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (`id`),
  KEY `idx_audit_user_time` (`user_id`, `created_at`),
  KEY `idx_audit_event_time` (`event`, `created_at`),
  CONSTRAINT `fk_audit_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- history@<profileUUID> 长度 45 > 32：0018 只加宽了 sync_items/游标，漏了历史表。
ALTER TABLE `sync_history_items` MODIFY COLUMN `domain` varchar(64) NOT NULL;

-- 把历史上误落 sync_items 的 history@<uuid> 迁到历史表（随后走 90 天 TTL/GC）。
INSERT IGNORE INTO `sync_history_items`
  (`user_id`,`domain`,`client_id`,`payload`,`client_updated_at`,`deleted_at`,`created_at`,`updated_at`)
SELECT `user_id`,`domain`,`client_id`,`payload`,`client_updated_at`,`deleted_at`,`created_at`,`updated_at`
  FROM `sync_items` WHERE `domain` LIKE 'history@%';
DELETE FROM `sync_items` WHERE `domain` LIKE 'history@%';

CREATE TABLE IF NOT EXISTS `sync_quota_daily` (
  `user_id` bigint NOT NULL,
  `day` date NOT NULL,
  `rows_written` bigint NOT NULL DEFAULT 0,
  `bytes_written` bigint NOT NULL DEFAULT 0,
  PRIMARY KEY (`user_id`,`day`),
  CONSTRAINT `fk_sync_quota_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
