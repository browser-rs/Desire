-- 注册验证码(E2E 之外的另一个基础防护):一次性,5 分钟过期。
-- api 顺手清理过期行;量小(仅注册场景)。
CREATE TABLE IF NOT EXISTS `registration_captchas` (
  `id` char(36) NOT NULL,
  `code` varchar(8) NOT NULL,
  `used` tinyint NOT NULL DEFAULT '0',
  `created_at` datetime(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  `expires_at` datetime(6) NOT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_regcap_expiry` (`expires_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
