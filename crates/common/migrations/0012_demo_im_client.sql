-- IM 演示会话改为按访客隔离：招聘脚本的阶段推进、消息拉取都以
-- (channel, client_id) 为界——两个访客同时玩不会互相踩脚本。
-- 0011 里建表时漏了这个维度，按增量迁移纪律补列。
ALTER TABLE `demo_im_messages`
  ADD COLUMN `client_id` varchar(64) NOT NULL DEFAULT '' AFTER `channel`,
  ADD KEY `idx_demo_im_session` (`channel`,`client_id`,`id`);
