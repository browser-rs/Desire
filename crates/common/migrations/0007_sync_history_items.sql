-- 历史域专表：与 sync_items 同构（domain 列保留、恒为 'history'），独立成表。
-- 理由：历史是高频写入（每次访问一行）+ 大体量（每用户数百行起步）+ 客户端
-- 500 条滚动裁剪的日志型数据，与低频的关键小域（书签/设置/记忆）分开治理——
-- TTL 清理（90 天，见 sync_service::push）与未来容量策略互不影响，sync_items
-- 保持精瘦。引擎按 sync_model::table_for 路由，SQL 与通用域完全一致。
CREATE TABLE IF NOT EXISTS `sync_history_items` (
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
  UNIQUE KEY `uk_sync_history_item` (`user_id`,`domain`,`client_id`),
  KEY `idx_sync_history_pull` (`user_id`,`domain`,`updated_at`),
  CONSTRAINT `fk_sync_history_items_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
