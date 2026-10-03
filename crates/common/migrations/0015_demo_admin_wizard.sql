-- 审核台演示：论坛帖子加 hidden 位（访客视图过滤，审核台可见/切换）；
-- 入驻向导演示：SPA 分步表单的最终提交落库。
ALTER TABLE `demo_forum_posts`
  ADD COLUMN `hidden` tinyint(1) NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS `demo_wizard_applications` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `client_id` varchar(64) NOT NULL,
  `shop` varchar(64) NOT NULL,
  `category` varchar(32) NOT NULL,
  `contact` varchar(64) NOT NULL,
  `phone` varchar(32) NOT NULL,
  `created_at` datetime(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (`id`),
  KEY `idx_demo_wizard_client` (`client_id`,`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
