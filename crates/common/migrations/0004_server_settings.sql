-- 服务端运维开关/元数据(kv)。首键 allow_registration(注册开关):
-- CLI(desire-admin)写,api 读;env DESIRE_API_ALLOW_REGISTRATION 显式设置时优先。
CREATE TABLE IF NOT EXISTS `server_settings` (
  `key` varchar(64) NOT NULL,
  `value` text NOT NULL,
  `updated_at` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
