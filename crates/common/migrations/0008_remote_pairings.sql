-- 远程控制（M0）：手机 App 经本服务中继控制家里的浏览器 Agent。
-- 两条铁律落在 schema 上：
-- ① 配对码只存 SHA-256（8 位一次性码，10 分钟有效，认领后失效）；
-- ② 控制信道的业务载荷是端到端密文（密钥材料走二维码，不经服务器），
--    离线留言存的也是密文——服务器只能路由，读不了内容。
CREATE TABLE IF NOT EXISTS `remote_pairings` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `user_id` bigint NOT NULL,
  `desktop_device_id` varchar(64) NOT NULL,
  `desktop_name` varchar(120) NOT NULL DEFAULT '',
  `code_hash` varchar(64) NOT NULL,
  `controller_name` varchar(120) NOT NULL DEFAULT '',
  `claimed_at` datetime(6) DEFAULT NULL,
  `revoked_at` datetime(6) DEFAULT NULL,
  `expires_at` datetime(6) NOT NULL,
  `created_at` datetime(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (`id`),
  KEY `idx_pairing_code` (`code_hash`),
  KEY `idx_pairing_user` (`user_id`,`desktop_device_id`),
  CONSTRAINT `fk_remote_pairings_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS `remote_inbox` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `user_id` bigint NOT NULL,
  `desktop_device_id` varchar(64) NOT NULL,
  `payload` mediumtext NOT NULL,
  `created_at` datetime(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  `delivered_at` datetime(6) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_inbox_pending` (`user_id`,`desktop_device_id`,`delivered_at`),
  CONSTRAINT `fk_remote_inbox_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
