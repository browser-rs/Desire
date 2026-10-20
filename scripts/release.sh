#!/bin/bash
# Desire 发版（2026-10-21 起：本地只准备版本 + 门控打 tag，构建/发布全部交给 GitHub）。
#
#   scripts/release.sh 0.7.26            # 准备 → 云端预发版构建（必须绿）→ 打 tag → 发布
#   scripts/release.sh 0.7.26 --from tag # 预发版已绿，只补打 tag（续跑）
#
# "发版必须成功"是铁律，机制如下：
#   1. 本地准备：冻结 CHANGELOG、同步版本号、跑纯逻辑单测、提交推送。
#   2. **云端预发版构建**：对同一个提交触发 release.yml 的 workflow_dispatch——与正式
#      发布完全相同的双架构零警告构建 + 单测，但不发布。**只有它绿了才打 tag**；
#      构建若有问题，tag 根本不存在，开发可以继续往前走。
#   3. 打 tag 后，正式发布工作流构建同一份字节并幂等发布（Release 已存在则复用、
#      资产 --clobber 覆盖、重跑可补完）——网络/上传失败 re-run 同一 tag 即可，
#      不需要改代码、不需要换 tag。
#
# 触发前本地仍需验证（云端的预发版只保证"能构建、单测过"）：
#   • 动了浏览器/Agent 运行路径 → python3 tests/execution-e2e.py（约 15 分钟，全绿）
#   • 视觉/交互改动 → 按 AGENTS.md 的桥/快照手法走查
#
# 为什么构建放云端：仓库是公开仓库，Actions 标准 runner 免费且不计分钟（私有仓库
# 才有 2000 分钟/月 + macOS 10× 扣减——那是历史顾虑）。预发版构建约 8–12 分钟，
# 云端异步跑，不占开发机；等它的时候可以继续开发。
#
# 进度：gh run list --workflow release.yml --limit 5
# 删除错误 tag（只在发布前）：git tag -d vX.Y.Z && git push origin :refs/tags/vX.Y.Z

set -euo pipefail

FROM="prepare"
V=""
for arg in "$@"; do
  case "$arg" in
    --from) FROM="tag" ;;   # 目前只支持 --from tag
    -*) printf '未知参数：%s\n' "$arg" >&2; exit 1 ;;
    *) if [ -z "$V" ]; then V="$arg"; else printf '多余参数：%s\n' "$arg" >&2; exit 1; fi ;;
  esac
done

log() { printf '\n\033[1;36m═══ %s ═══\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

[ -n "$V" ] || { sed -n '2,12p' "$0" | sed 's/^# \?//'; exit 1; }
case "$V" in v*) die "版本号不要带 v 前缀：scripts/release.sh ${V#v}" ;; esac
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本号格式应为 X.Y.Z：$V"
TAG="v$V"

REPO_ROOT="$(git rev-parse --show-toplevel)" || die "不在 git 仓库里"
cd "$REPO_ROOT"
[ "$(git branch --show-current)" = "main" ] || die "必须在 main 上发版"
[ -z "$(git status --porcelain)" ] || die "工作区必须干净——先提交或暂存当前变更"

ORIGIN_URL=$(git remote get-url origin)
GH_REPO=$(printf '%s' "$ORIGIN_URL" | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##')
command -v gh >/dev/null || die "需要 gh CLI"
gh auth status >/dev/null 2>&1 || die "gh 未登录"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then die "本地已有 tag $TAG"; fi
if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then die "远端已有 release $TAG"; fi

# ── 预发版构建的定位与等待 ──────────────────────────────────
find_preflight_run() {
  # 输出：<databaseId>\t<headSha>\t<status>\t<conclusion>\t<url>
  gh run list --repo "$GH_REPO" --workflow release.yml --limit 20 \
    --json databaseId,headSha,event,status,conclusion,url \
    --jq '.[] | select(.event == "workflow_dispatch") | [.databaseId, .headSha, .status, (.conclusion // ""), .url] | @tsv'
}

wait_for_preflight() {
  local head_sha="$1" run_line="" run_id="" deadline start elapsed status conclusion url last_status=""
  start=$(date +%s); deadline=$((start + 60))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    run_line=$(find_preflight_run | awk -F '\t' -v sha="$head_sha" '$2 == sha { print; exit }')
    [ -n "$run_line" ] && break
    sleep 3
  done
  [ -n "$run_line" ] || die "没有找到这次预发版构建的 workflow run（调度失败？）"
  run_id=$(printf '%s' "$run_line" | cut -f1)
  echo "预发版构建：$run_id"
  url=$(printf '%s' "$run_line" | cut -f5)
  deadline=$(( $(date +%s) + 2700 ))
  while :; do
    elapsed=$(( $(date +%s) - start ))
    run_line=$(gh run view "$run_id" --repo "$GH_REPO" --json status,conclusion,url \
      --jq '[.status, (.conclusion // ""), .url] | @tsv' 2>/dev/null || true)
    if [ -n "$run_line" ]; then
      status=$(printf '%s' "$run_line" | cut -f1)
      conclusion=$(printf '%s' "$run_line" | cut -f2)
      url=$(printf '%s' "$run_line" | cut -f3)
      if [ "$status" != "$last_status" ]; then
        printf '  状态：%s（已等 %ss）\n' "$status" "$elapsed"
        last_status="$status"
      fi
      [ "$status" = "completed" ] && break
    fi
    [ "$(date +%s)" -lt "$deadline" ] || die "预发版构建超时（45 分钟）：$url"
    sleep 15
  done
  if [ "$conclusion" != "success" ]; then
    die "预发版构建未通过（$conclusion）——tag 未创建，可继续开发；修复后重跑本命令。
  $url"
  fi
  echo "预发版构建通过（$url）——与 tag 将要指向的提交完全一致。"
}

# ── --from tag：只补 tag（要求该提交已有成功的预发版构建）────────
if [ "$FROM" = "tag" ]; then
  log "补打 tag $TAG"
  HEAD_SHA=$(git rev-parse HEAD)
  run_line=$(find_preflight_run | awk -F '\t' -v sha="$HEAD_SHA" '$2 == sha && $3 == "completed" && $4 == "success" { print; exit }')
  [ -n "$run_line" ] || die "HEAD（$(printf '%s' "$HEAD_SHA" | cut -c1-8)）没有成功的预发版构建——先跑完整命令"
  grep -qF "## [$TAG]" CHANGELOG.md || die "CHANGELOG 缺少 $TAG 段"
  grep -q "MARKETING_VERSION = $V;" apps/macos/Desire.xcodeproj/project.pbxproj || die "版本号未同步到 $V"
  git tag "$TAG"
  git push origin "$TAG"
  log "已触发正式发布"
  echo "tag    : $TAG @ $(printf '%s' "$HEAD_SHA" | cut -c1-8)"
  echo "进度   : gh run list --workflow release.yml --limit 5"
  echo "发布页 : https://github.com/$GH_REPO/releases/tag/$TAG"
  exit 0
fi

# ── 1. CHANGELOG 冻结 ────────────────────────────────────────
log "CHANGELOG"
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
if "## [Unreleased]" not in s:
    s = "## [Unreleased]\n\n" + s
open(p, "w").write(s)
print(f"已冻结 {tag}，并补了新的 [Unreleased] 空壳")
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
  echo "构建号保持 $NEXT_BUILD（续跑）"
else
  NEXT_BUILD=$((CURRENT_BUILD + 1))
  sed -i '' "s/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = $V;/g" "$PBX"
  sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $NEXT_BUILD;/g" "$PBX"
  echo "构建号 → $NEXT_BUILD"
fi
grep -q "MARKETING_VERSION = $V;" "$PBX" || die "pbxproj 版本号替换失败"

if [ -f website/index.html ]; then
  sed -i '' "s/\"softwareVersion\": \"[0-9.]*\"/\"softwareVersion\": \"$V\"/; \
              s/下载 Desire <span class=\"ver\">v[0-9.]*<\/span>/下载 Desire <span class=\"ver\">v$V<\/span>/; \
              s/当前版本 <b>v[0-9.]*<\/b>/当前版本 <b>v$V<\/b>/; \
              s/Desire-v[0-9.]*-macos-arm64\.zip，双击解压即可。/Desire-v$V-macos-arm64.zip，双击解压即可。/" website/index.html
  echo "website 版本号已同步"
fi

# ── 3. 最便宜的真回归：纯逻辑单测 ──────────────────────────
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
git diff --cached --quiet || git commit -m "release(v$V): v$V — freeze changelog and bump version ($NEXT_BUILD)"
git push origin main
HEAD_SHA=$(git rev-parse HEAD)

# ── 5. 云端预发版构建（铁律闸门）───────────────────────────
log "云端预发版构建（双架构零警告 + 单测；不发布）"
gh workflow run release.yml --repo "$GH_REPO" --ref main -f version="$V" \
  || die "无法触发 release.yml（workflow 文件是否已推到 main？）"
wait_for_preflight "$HEAD_SHA"

# ── 6. 打 tag → 正式发布（云端异步）───────────────────────
log "打 tag 并触发正式发布"
git tag "$TAG"
git push origin "$TAG"

log "已触发云端发布"
echo "tag    : $TAG @ $(printf '%s' "$HEAD_SHA" | cut -c1-8)"
echo "进度   : gh run list --workflow release.yml --limit 5"
echo "发布页 : https://github.com/$GH_REPO/releases/tag/$TAG"
echo ""
echo "构建/上传在 GitHub Actions 上跑；发布失败只需 re-run 同一 tag 的工作流（幂等补完）。"
