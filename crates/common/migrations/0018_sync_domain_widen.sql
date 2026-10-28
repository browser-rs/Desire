-- v0.8.18 多档案同步（方案 A）：域键支持 `bookmarks@<profileUUID>` 后缀形态
-- （基础域 32 字符 + '@' + 36 字符 uuid = 46，放宽到 64 留余量）。
-- 纯列宽放宽，数据不动；is_valid_domain 已在应用层校验 charset。
ALTER TABLE `sync_items` MODIFY COLUMN `domain` varchar(64) NOT NULL;

ALTER TABLE `sync_pull_cursors` MODIFY COLUMN `domain` varchar(64) NOT NULL;
