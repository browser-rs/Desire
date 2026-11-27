-- v0.8.81 批 1：按用户同步存储上限（payload 字节总和，含历史表）。
-- 之前只有"日写入 rows/bytes"配额，没有总量上限；单用户可以无限占用。
CREATE TABLE IF NOT EXISTS `sync_user_storage` (
  `user_id` bigint NOT NULL,
  `bytes` bigint NOT NULL DEFAULT 0,
  `updated_at` datetime(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (`user_id`),
  CONSTRAINT `fk_sync_user_storage_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

-- 回填现有数据（JSON 的字符表示字节数；NULL payload 不计）。
INSERT INTO `sync_user_storage` (`user_id`, `bytes`)
SELECT user_id, SUM(bytes) FROM (
  SELECT user_id, SUM(LENGTH(CAST(payload AS CHAR))) AS bytes
    FROM `sync_items` WHERE payload IS NOT NULL GROUP BY user_id
  UNION ALL
  SELECT user_id, SUM(LENGTH(CAST(payload AS CHAR))) AS bytes
    FROM `sync_history_items` WHERE payload IS NOT NULL GROUP BY user_id
) t
GROUP BY user_id
ON DUPLICATE KEY UPDATE bytes = VALUES(bytes);
