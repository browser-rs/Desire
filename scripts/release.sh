#!/bin/bash
# Desire 发版（2026-10-21 起：本地只准备版本并触发，云端构建成功才自动打 tag + 发布）。
#
#   scripts/release.sh 0.7.26     # 约 30 秒返回：冻结 CHANGELOG、同步版本号、单测、
#                                 # 提交推送、触发云端发布；构建通过后云端自动建 tag
#   scripts/release.sh --status   # 看最近几次 Release 工作流
#
# **发版必须成功**（铁律）：tag 由 GitHub Actions 在**双架构零警告构建 + 单测全部
# 通过之后**创建（`gh release create --target <已验证 SHA>`），构建失败则 tag 与
# Release 都不存在——不会留下一个"构建不过的版本"。发布 job 幂等：上传/网络失败
# 只需 `gh run rerun <id> --failed`，不用改代码、不用换 tag。
#
# **触发后开发不停**：命令只负责准备与调度，几秒返回；构建/发布在云端异步跑，
# 可以立刻继续开发（tag 指向的是已经验证过的那个提交 SHA，不受后续提交影响）。
#
# 触发前本地仍需验证（云端只保证"能构建、单测过"，不跑浏览器 E2E）：
#   • 动了浏览器/Agent 运行路径 → python3 tests/execution-e2e.py（约 15 分钟，全绿）
#   • 结构/视觉改动 → 按 AGENTS.md 的桥/快照手法走查
#
# 为什么构建放云端：仓库是公开仓库，Actions 标准 runner 免费且不计分钟（私有仓库
# 才有 2000 分钟/月 + macOS 10× 扣减——那是历史顾虑）。
#
# 工作流：.github/workflows/release.yml（workflow_dispatch = 构建后按需发布；
# push tag = 手动 tag 路径，同样幂等）。

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

V="${1:-}"
[ -n "$V" ] || { sed -n '2,20p' "$0" | sed 's/^# \?//'; exit 1; }
case "$V" in v*) die "版本号不要带 v 前缀：scripts/release.sh ${V#v}" ;; esac
[[ "$V" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "版本号格式应为 X.Y.Z：$V"
TAG="v$V"

[ "$(git branch --show-current)" = "main" ] || die "必须在 main 上发版"
[ -z "$(git status --porcelain)" ] || die "工作区必须干净——先提交或暂存当前变更"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then die "本地已有 tag $TAG"; fi
if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then die "远端已有 release $TAG"; fi

# ── 1. CHANGELOG 冻结 ────────────────────────────────────────
log "CHANGELOG"
# 空壳 [Unreleased]（旧脚本冻结后留下的）会让 verify 拒绝；发布场景直接移除。
# 下次加条目时 changelog.py add 会自动重建这个头。
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

# ── 5. 触发云端：构建通过 → 自动建 tag → 发布 ──────────────
log "触发云端发布（构建通过后才创建 tag）"
gh workflow run release.yml --repo "$GH_REPO" --ref main \
  -f version="$V" -F publish_on_success=true \
  || die "无法触发 release.yml（workflow 文件是否已推到 main？）"

# 确认调度的是本次提交（main 若在调度瞬间被推进，宁可取消也不发错内容）。
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
  # 调度可能解析到了更新的 main：取消这些 run（它们会带 publish_on_success=true），
  # 避免用错误 SHA 建 tag。然后让用户重跑本命令。
  for id in $(gh run list --repo "$GH_REPO" --workflow release.yml --limit 10 \
      --json databaseId,headSha,event \
      --jq ".[] | select(.event == \"workflow_dispatch\" and .headSha != \"$HEAD_SHA\") | .databaseId"); do
    gh run cancel "$id" --repo "$GH_REPO" >/dev/null 2>&1 || true
  done
  die "没有找到本次提交的云端运行（调度可能解析到了更新的 main）——已取消错位运行，请重跑本命令"
fi

log "已触发（本地可以继续开发）"
echo "run    : $RUN_URL"
echo "行为   : 双架构零警告构建 + 单测全部通过 → 自动创建 tag $TAG 并发布；"
echo "         任何一步失败 → 不产生 tag / Release（开发继续，修好重跑本命令）"
echo "进度   : gh run watch $RUN_ID"
echo "状态   : scripts/release.sh --status"
echo ""
echo "tag 指向：$(printf '%s' "$HEAD_SHA" | cut -c1-8)（后续提交不影响本次发布）"
