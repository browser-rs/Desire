-- DPP 演示场（website/demo）的共享状态：购物车 / 订单 / IM 消息。
-- 部署是多实例 + nginx 轮询（无 sticky），演示态必须落共享存储——
-- 进程内内存会让加购落在 A 实例、结算打到 B 实例。无鉴权无敏感
-- 数据，仅协议演示用；商品目录仍留在代码里（静态常量）。
-- 金额一律整数「分」（演示目录没有小数需求，也避开 DECIMAL 解码依赖）。
CREATE TABLE IF NOT EXISTS `demo_cart_items` (
  `client_id` varchar(64) NOT NULL,
  `sku` varchar(32) NOT NULL,
  `qty` int NOT NULL,
  `price_cents` int NOT NULL,
  `updated_at` datetime(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6),
  PRIMARY KEY (`client_id`,`sku`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS `demo_orders` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `client_id` varchar(64) NOT NULL,
  `total_cents` int NOT NULL,
  `created_at` datetime(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (`id`),
  KEY `idx_demo_order_client` (`client_id`,`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS `demo_order_items` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `order_id` bigint NOT NULL,
  `sku` varchar(32) NOT NULL,
  `name` varchar(64) NOT NULL,
  `price_cents` int NOT NULL,
  `qty` int NOT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_demo_order_item` (`order_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS `demo_im_messages` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `channel` varchar(32) NOT NULL,
  `sender` varchar(16) NOT NULL,
  `content` varchar(500) NOT NULL,
  `created_at` datetime(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (`id`),
  KEY `idx_demo_im_channel` (`channel`,`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
