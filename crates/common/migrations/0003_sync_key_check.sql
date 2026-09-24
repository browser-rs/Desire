-- E2E 加密(2026-09-25):用户表加"密钥指纹"。客户端持有同步主密钥(永不上传),
-- 指纹 = HMAC-SHA256(主密钥, "fingerprint") 的 hex,用于新设备导入时校验
-- 密钥是否与服务器现有密文匹配。服务端只存指纹,无法反推密钥。
ALTER TABLE `users`
  ADD COLUMN `sync_key_check` char(64) DEFAULT NULL AFTER `password_hash`;
