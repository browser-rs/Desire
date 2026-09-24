#!/bin/bash
# 纯逻辑单测：直接 swiftc 编译受测文件 + tests/main.swift，不依赖 Xcode 与应用 target。
# 新增受测文件：往 SOURCES 里加一行；新增用例：tests/main.swift 里加 check(...)。
# 运行：tests/run.sh（或 bash tests/run.sh）
set -e
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)/puretests"
SOURCES=(
  Desire/Features/Agent/AgentMessage.swift
  Desire/Features/Agent/AgentToolSchema.swift
  Desire/Features/Agent/Conversation.swift
  Desire/Features/Agent/ModelPrice.swift
  Desire/Features/Agent/AgentUsage.swift
  Desire/Features/Agent/UsageStats.swift
  Desire/Features/Agent/SecretRedactor.swift
  Desire/Features/Agent/ContextCompaction.swift
  Desire/Features/Agent/AgentTrace.swift
  Desire/Features/Bookmarks/Bookmark.swift
  Desire/Features/NewTab/QuickDial.swift
  Desire/Features/ReadingList/ReadingListItem.swift
  Desire/Features/Sync/SyncModels.swift
  Desire/Features/Sync/SyncCrypto.swift
  Desire/Features/Sync/SyncMerge.swift
  tests/main.swift
)
swiftc -o "$OUT" "${SOURCES[@]}"
"$OUT"
