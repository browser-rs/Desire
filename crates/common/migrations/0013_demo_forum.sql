-- 论坛演示（website/demo/forum）：发帖 / 点赞 / 评论。
-- 与其他 demo 态同原则：多实例共享 MySQL，金额外的计数用行数现算
-- （点赞不存计数列，COUNT 行数 = 天然一致）；点赞按 (post, client)
-- 唯一去重，重复点赞是 toggle（INSERT/DELETE）。
CREATE TABLE IF NOT EXISTS `demo_forum_posts` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `client_id` varchar(64) NOT NULL,
  `title` varchar(120) NOT NULL,
  `content` varchar(2000) NOT NULL,
  `created_at` datetime(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (`id`),
  KEY `idx_demo_forum_post` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS `demo_forum_likes` (
  `post_id` bigint NOT NULL,
  `client_id` varchar(64) NOT NULL,
  `created_at` datetime(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (`post_id`,`client_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS `demo_forum_comments` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `post_id` bigint NOT NULL,
  `client_id` varchar(64) NOT NULL,
  `content` varchar(500) NOT NULL,
  `created_at` datetime(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (`id`),
  KEY `idx_demo_forum_comment` (`post_id`,`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
