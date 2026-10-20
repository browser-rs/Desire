#!/bin/bash
# Desire 发版（2026-10-21 定稿：云端用与本机完全相同的 Xcode 27.1 构建，全绿才建 tag）
#
#   scripts/release.sh 0.7.27             # 冻结版本 → 推送 → 触发云端；约 30 秒返回
#   scripts/release.sh 0.7.27 --build-only # 只跑构建自检（publish=false，不建 tag）
#   scripts/release.sh --status            # 看最近几次 Release 工作流
#
# 保证与不阻塞：
#   • CI 与本地同编译器：xcode-27 镜像 / Xcode 27.1 (27A9275) == 本机版本；
#     本地零警告构建与 CI 结论一致（2026-10-21 实测 26.6 的 18 条隔离警告已修）。
#   • tag 由云端在双架构零警告构建 + 单测全部通过后创建（gh release create --target
#     已验证的 SHA）——构建失败则 tag/Release 都不存在。
#   • 本地命令只做准备与调度，几秒返回；构建/上传在云端异步跑，开发继续。
#   • 发布 job 幂等：上传/网络失败只需 `gh run rerun <id> --failed`，不换 tag、不改代码。
#
# 触发前本地验证（发版构建同编译器，但仍建议）：
#   • bash tests/run.sh（脚本自带）
#   • 动了浏览器/Agent 运行路径 → python3 tests/execution-e2e.py（约 15 分钟，全绿）
#   • 结构/视觉改动 → 按 AGENTS.md 的桥/快照手法走查

set -euo pipefail

log() { printf '\n\033[1;36m═══ %s ═══\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

REPO_ROOT="$(git rev-parse --show-toplevel)" || die "不在 git 仓库里"
cd "$REPO_ROOT"
ORIGIN_URL=$(git remote get-url origin)
GH_REPO=$(printf '%s' "$ORIGIN_URL" | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##')
command -v gh >/dev/null || die "需要 gh CLI"
gh auth status >/dev/null 2>&1 || die "gh 未登录"

if [ "${1:-}" = "--status" ]; then
  gh run list --repo "$GH_REPO" --workflow release.yml --limit 8
  echo ""
  gh release list --repo "$GH_REPO" --limit 3
  exit 0
fi

V=""
BUILD_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --build-only) BUILD_ONLY=1 ;;
    -*) die "未知参数：$arg" ;;
    *) if [ -z "$V" ]; then V="$arg"; else die "多余参数：$arg"; fi ;;
  esac
done
[ -n "$V" ] || { sed -n '2,22p' "$0" | sed 's/^# \?//'; exit 1; }
case "$V" in v*) die "版本号不要带 v 前缀：scripts/release.sh ${V#v}" ;; esac
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本号格式应为 X.Y.Z：$V"
TAG="v$V"

[ "$(git branch --show-current)" = "main" ] || die "必须在 main 上发版"
[ -z "$(git status --porcelain)" ] || die "工作区必须干净——先提交或暂存当前变更"

if [ "$BUILD_ONLY" = 0 ]; then
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then die "本地已有 tag $TAG"; fi
  if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then die "远端已有 release $TAG"; fi
fi

# ── 1. CHANGELOG ────────────────────────────────────────────
log "CHANGELOG"
python3 - <<'PYCLEAN'
import re
p = "CHANGELOG.md"
s = open(p).read()
m = re.match(r"## \[Unreleased\]\s*\n+(?=## \[)", s)
if m:
    open(p, "w").write(s[m.end():])
    print("已移除空的 [Unreleased] 空壳")
PYCLEAN
python3 scripts/changelog.py verify || die "CHANGELOG 结构问题"

if grep -qF "## [$TAG]" CHANGELOG.md; then
  echo "已有 $TAG 段（续跑场景），跳过冻结"
else
  python3 - "$TAG" "$(date +%F)" <<'PYF' || die "自动冻结失败——[Unreleased] 里没有条目"
import re, sys
tag, today = sys.argv[1], sys.argv[2]
p = "CHANGELOG.md"
s = open(p).read()
m = re.search(r"(?m)^## \[Unreleased\]\s*$", s)
if not m:
    sys.exit(1)
head = m.end()
nxt = re.search(r"(?m)^## \[", s[head:])
end = head + nxt.start() if nxt else len(s)
if not re.search(r"(?m)^- ", s[head:end]):
    sys.exit(2)
s = s[:m.start()] + f"## [{tag}] - {today}" + s[head:]
open(p, "w").write(s)
print(f"已冻结 {tag}")
PYF
fi

# ── 2. 版本号（幂等：续跑不重复加构建号）──────────────────
log "版本号 → $V"
PBX="apps/macos/Desire.xcodeproj/project.pbxproj"
CURRENT_VERSION=$(grep -m1 "MARKETING_VERSION = " "$PBX" | grep -o '[0-9.]\+')
CURRENT_BUILD=$(grep -m1 "CURRENT_PROJECT_VERSION = " "$PBX" | grep -o '[0-9]\+')
[ -n "$CURRENT_BUILD" ] || die "读不到 CURRENT_PROJECT_VERSION"
if [ "$CURRENT_VERSION" = "$V" ]; then
  NEXT_BUILD="$CURRENT_BUILD"
  echo "构建号保持 ${NEXT_BUILD}（续跑）"
else
  NEXT_BUILD=$((CURRENT_BUILD + 1))
  sed -i '' "s/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = $V;/g" "$PBX"
  sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = ${NEXT_BUILD};/g" "$PBX"
  echo "构建号 → ${NEXT_BUILD}"
fi
grep -q "MARKETING_VERSION = $V;" "$PBX" || die "pbxproj 版本号替换失败"

if [ -f website/index.html ]; then
  sed -i '' "s/\"softwareVersion\": \"[0-9.]*\"/\"softwareVersion\": \"$V\"/; \
              s/下载 Desire <span class=\"ver\">v[0-9.]*<\/span>/下载 Desire <span class=\"ver\">v$V<\/span>/; \
              s/当前版本 <b>v[0-9.]*<\/b>/当前版本 <b>v$V<\/b>/; \
              s/Desire-v[0-9.]*-macos-arm64\.zip，双击解压即可。/Desire-v$V-macos-arm64.zip，双击解压即可。/" website/index.html
  echo "website 版本号已同步"
fi

# ── 3. 纯逻辑单测（40 秒）──────────────────────────────────
log "纯逻辑单测"
bash tests/run.sh || die "单测未过——别把本地 40 秒能发现的问题带进发版"

# ── 4. 提交 + 推送 ─────────────────────────────────────────
log "提交并推送"
git add -- CHANGELOG.md website/index.html "$PBX"
UNEXPECTED=$(git diff --cached --name-only | while IFS= read -r p; do
  if [[ "$p" != "CHANGELOG.md" && "$p" != "website/index.html" && "$p" != "$PBX" ]]; then
    printf '%s\n' "$p"
  fi
done)
[ -z "$UNEXPECTED" ] || die "staging 出现未允许文件：$UNEXPECTED"
git diff --cached --quiet || git commit -m "release(v$V): v$V — freeze changelog and bump version (${NEXT_BUILD})"
git push origin main
HEAD_SHA=$(git rev-parse HEAD)

# ── 5. 触发云端 ────────────────────────────────────────────
log "触发云端发版（构建全绿后才建 tag）"
gh workflow run release.yml --repo "$GH_REPO" --ref main \
  -f version="$V" -F publish="$([ "$BUILD_ONLY" = 1 ] && echo false || echo true)" \
  || die "无法触发 release.yml（workflow 文件是否已推到 main？）"

RUN_ID=""
RUN_URL=""
for _ in $(seq 1 30); do
  MATCH=$(gh run list --repo "$GH_REPO" --workflow release.yml --limit 20 \
    --json databaseId,headSha,event,url \
    --jq ".[] | select(.event == \"workflow_dispatch\" and .headSha == \"$HEAD_SHA\") | [.databaseId, .url] | @tsv" \
    | sort -nr | head -1)
  if [ -n "$MATCH" ]; then
    RUN_ID=$(printf '%s' "$MATCH" | cut -f1)
    RUN_URL=$(printf '%s' "$MATCH" | cut -f2)
    break
  fi
  sleep 2
done

if [ -z "$RUN_ID" ]; then
  for id in $(gh run list --repo "$GH_REPO" --workflow release.yml --limit 10 \
      --json databaseId,headSha,event \
      --jq ".[] | select(.event == \"workflow_dispatch\" and .headSha != \"$HEAD_SHA\") | .databaseId"); do
    gh run cancel "$id" --repo "$GH_REPO" >/dev/null 2>&1 || true
  done
  die "没有找到本次提交的云端运行（调度可能解析到了更新的 main）——已取消错位运行，请重跑本命令"
fi

log "已触发（本地可以继续开发）"
echo "run    : $RUN_URL"
if [ "$BUILD_ONLY" = 1 ]; then
  echo "模式   : 仅构建自检（publish=false，不会建 tag）"
else
  echo "模式   : 双架构零警告构建 + 单测全绿 → 自动创建 tag $TAG 并发布；失败则无 tag"
fi
echo "进度   : gh run watch $RUN_ID"
echo "状态   : scripts/release.sh --status"
echo "tag 指向：$(printf '%s' "$HEAD_SHA" | cut -c1-8)（后续提交不影响本次发布）"
