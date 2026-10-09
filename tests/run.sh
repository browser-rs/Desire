#!/bin/bash
# 纯逻辑单测：直接 swiftc 编译受测文件 + tests/main.swift，不依赖 Xcode 与应用 target。
# 新增受测文件：往 SOURCES 里加一行；新增用例：tests/main.swift 里加 check(...)。
# 运行：tests/run.sh（或 bash tests/run.sh）
set -e
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)/puretests"
SOURCES=(
  apps/macos/Desire/Features/Agent/AgentMessage.swift
  apps/macos/Desire/Features/Agent/AgentGuard.swift
  apps/macos/Desire/Features/Agent/HeartbeatDecision.swift
  apps/macos/Desire/Features/Agent/SkillAuthoring.swift
  apps/macos/Desire/Features/Agent/ConversationRecall.swift
  apps/macos/Desire/Features/Agent/AgentMode.swift
  apps/macos/Desire/Features/Agent/SkillScanner.swift
  apps/macos/Desire/Features/Agent/Memory/MemoryKB.swift
  apps/macos/Desire/Features/Notifications/NotificationPolicy.swift
  apps/macos/Desire/Features/Agent/AgentToolSchema.swift
  apps/macos/Desire/Features/Agent/PageProtocol/DesireProtocol.swift
  apps/macos/Desire/Features/Agent/PageEventPolicy.swift
  apps/macos/Desire/App/Log.swift
  apps/macos/Desire/Features/Agent/AgentPlanStep.swift
  apps/macos/Desire/App/JSString.swift
  apps/macos/Desire/Features/History/HistoryEntry.swift
  apps/macos/Desire/Features/Agent/RoutingDecision.swift
  apps/macos/Desire/Features/Agent/Conversation.swift
  apps/macos/Desire/Features/Agent/ModelPrice.swift
  apps/macos/Desire/Features/Agent/AgentUsage.swift
  apps/macos/Desire/Features/Agent/UsageStats.swift
  apps/macos/Desire/Features/Agent/SecretRedactor.swift
  apps/macos/Desire/Features/Whiteboard/WhiteboardSpec.swift
  apps/macos/Desire/Features/Whiteboard/WhiteboardHTMLExport.swift apps/macos/Desire/Features/Agent/ContextCompaction.swift
  apps/macos/Desire/Features/Agent/AgentTrace.swift
  apps/macos/Desire/App/FilePathing.swift
  apps/macos/Desire/Features/Agent/AgentTextSanitizer.swift
  apps/macos/Desire/Features/Bookmarks/Bookmark.swift
  apps/macos/Desire/Features/Browsing/MediaResource.swift
  apps/macos/Desire/Features/Downloads/BatchMedia.swift
  apps/macos/Desire/Features/PageWatch/PageWatchDiff.swift
  apps/macos/Desire/Features/NewTab/QuickDial.swift
  apps/macos/Desire/Features/UserScripts/PluginResources.swift
  apps/macos/Desire/Features/UserScripts/DNRRule.swift
  apps/macos/Desire/Features/UserScripts/DNRConverter.swift
  apps/macos/Desire/Features/UserScripts/PluginI18N.swift
  apps/macos/Desire/Features/ReadingList/ReadingListItem.swift
  apps/macos/Desire/Features/Agent/AgentQuickTemplate.swift
  apps/macos/Desire/Features/Sync/SyncModels.swift
  apps/macos/Desire/Features/Agent/Memory/MemoryModels.swift
  apps/macos/Desire/Features/Agent/Memory/MemoryRetrieval.swift
  apps/macos/Desire/Features/Sync/SyncCrypto.swift
  apps/macos/Desire/Features/Sync/SyncMerge.swift
  apps/macos/Desire/Features/Sync/WhiteboardSync.swift
  apps/macos/Desire/Features/Agent/BallCapability.swift
  apps/macos/Desire/Features/Whiteboard/WhiteboardExtract.swift
  apps/macos/Desire/Features/Whiteboard/WhiteboardTemplates.swift
  tests/main.swift
)
swiftc -o "$OUT" "${SOURCES[@]}"
"$OUT"
