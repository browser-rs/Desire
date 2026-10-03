-- 预约演示（website/demo/booking）：按时段预约，演示 date/bool 类型
-- 字段与"唯一约束冲突 = 409"的双订保护。与其他 demo 态同原则落共享库。
CREATE TABLE IF NOT EXISTS `demo_bookings` (
  `id` bigint NOT NULL AUTO_INCREMENT,
  `client_id` varchar(64) NOT NULL,
  `booking_date` date NOT NULL,
  `slot` varchar(8) NOT NULL,
  `guest_name` varchar(64) NOT NULL,
  `created_at` datetime(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6),
  PRIMARY KEY (`id`),
  UNIQUE KEY `uk_demo_booking_slot` (`booking_date`,`slot`),
  KEY `idx_demo_booking_client` (`client_id`,`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;
