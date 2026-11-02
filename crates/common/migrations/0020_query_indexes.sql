-- v0.8.38 API 2.0（批五 C5）：查询索引审计。
-- 1) 同步增量拉取按 (user_id, domain, updated_at, id) 做复合游标（v0.7.25 起
--    服务端支持 since_id）；旧索引没有 id，末列排序/同刻翻页仍要回表排序。
-- 2) remote_inbox 的 take（user+device+recipient+delivered_at 后按 id 排序）
--    与 TTL 清理（created_at）缺覆盖索引。
ALTER TABLE `sync_items`
  DROP KEY `idx_sync_pull`,
  ADD KEY `idx_sync_pull_cursor` (`user_id`, `domain`, `updated_at`, `id`);

ALTER TABLE `sync_history_items`
  ADD KEY `idx_sync_history_pull_cursor` (`user_id`, `domain`, `updated_at`, `id`);

ALTER TABLE `remote_inbox`
  ADD KEY `idx_inbox_device_id` (`user_id`, `desktop_device_id`, `id`),
  ADD KEY `idx_inbox_created` (`created_at`);
