-- 扫码登录（照 Trove login_tickets 设计）：桌面端生成二维码，手机 App 扫码
-- 后在手机上确认，桌面轮询领走 token 对。
-- status: 0=待扫码 1=已扫码待确认 2=已确认(含 token，一次性消费) 3=过期
-- token/refresh_token 在 confirm 时写入、被桌面领走时原子清空——
-- 防止"看到二维码的任何人都能从轮询端点领走 token"（Trove 踩过的坑）。
CREATE TABLE IF NOT EXISTS `auth_qr_logins` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `ticket` varchar(64) NOT NULL,
  `status` tinyint NOT NULL DEFAULT '0',
  `desktop_device_id` varchar(64) NOT NULL,
  `desktop_name` varchar(120) NOT NULL DEFAULT '',
  `user_id` bigint DEFAULT NULL,
  `token` text,
  `refresh_token` text,
  `expires_at` datetime NOT NULL,
  `created_at` datetime(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (`id`),
  UNIQUE KEY `ticket` (`ticket`),
  KEY `idx_qr_expires` (`expires_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
