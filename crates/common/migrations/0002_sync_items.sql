-- M1 同步引擎:通用"域 + 文档"同步表。服务端不解读 payload(域自定义 JSON),
-- 仲裁 = client_updated_at LWW(服务端只记收到时间 updated_at 做拉取游标)。
-- 删除 = tombstone:deleted_at 置位、payload 置 NULL(已删内容不留库)。
-- 适用域见 sync_model::DOMAINS(bookmarks/quickdials/reading_list/keyboard_shortcuts/settings);
-- 大体量/需服务端查询的域(如历史)将来另建专表,不进这里。
CREATE TABLE IF NOT EXISTS `sync_items` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `user_id` bigint NOT NULL,
  `domain` varchar(32) NOT NULL,
  `client_id` varchar(64) NOT NULL,
  `payload` json DEFAULT NULL,
  `client_updated_at` datetime(6) NOT NULL,
  `deleted_at` datetime(6) DEFAULT NULL,
  `created_at` datetime(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  `updated_at` datetime(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_sync_item` (`user_id`,`domain`,`client_id`),
  KEY `idx_sync_pull` (`user_id`,`domain`,`updated_at`),
  CONSTRAINT `fk_sync_items_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
