-- v0.8.38 API 2.0（批四）：按用户/日/域的同步写入用量。
-- C1 配额的目标是挡住"异常客户端高频全量推"，不是给正常用户设卡：
-- 默认日额度见 configs（DESIRE_API_SYNC_DAILY_ROWS / _BYTES），
-- 超限返回 429 + Retry-After。行数与字节按 **提交的 applied 条目** 计，
-- 幂等重放也计（客户端行为可观测，且避免"重放不计费"被用来绕过）。
CREATE TABLE IF NOT EXISTS `sync_usage` (
  `user_id` bigint NOT NULL,
  `day` date NOT NULL,
  `domain` varchar(64) NOT NULL,
  `rows_written` bigint NOT NULL DEFAULT 0,
  `bytes_written` bigint NOT NULL DEFAULT 0,
  `updated_at` datetime(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (`user_id`,`day`,`domain`),
  KEY `idx_sync_usage_day` (`day`),
  CONSTRAINT `fk_sync_usage_user` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
