-- E2E 密钥托管(密码派生 KEK 包裹 DEK):
-- kdf_salt      = PBKDF2 盐(base64,客户端生成,16 字节)
-- wrapped_dek   = JSON 信封 {v,kdf,iter,ct},ct = AES-GCM(DEK, KEK) 的 base64。
-- 两者均不可读出 DEK;用户换设备凭登录密码解包恢复,无需手工备份密钥。
ALTER TABLE `users`
  ADD COLUMN `kdf_salt` varchar(64) DEFAULT NULL AFTER `sync_key_check`,
  ADD COLUMN `wrapped_dek` text DEFAULT NULL AFTER `kdf_salt`;
