#!/usr/bin/env bash
# Desire 发布流程（一键化）。
#
# 用法：
#   scripts/release.sh <版本号>            # 例：scripts/release.sh 0.3.15
#   scripts/release.sh <版本号> --from package   # 某一步失败后从该步重跑
#   scripts/release.sh <版本号> --ci local       # 不用 GitHub CI，本地全套验证
#   scripts/release.sh <版本号> --skip-ci-check  # 完全跳过 ci 阶段（急救用）
#   scripts/release.sh body v0.3.14        # 只打印该 tag 的 release 正文（调试用）
#
# 阶段：prep → build → ci → smoke → package → publish → verify
#   （build 在 ci 之前：ci 的 local 模式要拿构建产物跑评估套件）
#
# 流程固化的教训（每条都是真踩过的，别删）：
#   • Release 工作流必须在**推 tag 之前** disable——它由 v* tag 触发、会自己构建
#     发布，抢 Latest。publish 阶段第一步就是它，verify 结束再 enable。
#   • CI 必须绿才能打 tag：v0.3.14 是红着 CI 发出去的（评估套件坏了没人看）。
#   • **GitHub 额度烧完也要能发版**：macOS runner 按 10 倍扣分钟，额度用尽后
#     Actions 全灭。--ci auto（默认）找不到 HEAD 的 run 就回落到本地全套验证
#     （单测 + 评估套件），--ci local 强制本地；gh API 本身不走 Actions 分钟数，
#     推 tag / gh release create 永远可用。
#   • 冒烟必须从**非 DerivedData 路径**启动：Keychain 条目 ACL 对 adhoc 构建
#     认路径/cdhash，换路径才暴露"授权窗永不渲染 → 启动挂死"这类问题。
#   • gh 一律带 --repo（从 git remote 推导）——mankong/Desire 会 404。
#   • "零警告"只有 clean build 算数：build 阶段每次删掉 DerivedData 重建。
#   • 安装说明唯一真相 = scripts/install-note.template.md（CI 与本脚本共用）。

set -euo pipefail

V=""
FROM="prep"
SKIP_CI_CHECK=0
CI_MODE="auto"   # auto：GH CI 优先、不可用回落本地；gh：强依赖 GH CI；local：只用本地

usage() {
  sed -n '/^# 用法：/,/^#$/p' "$0" | sed 's/^# \?//'
  exit 1
}
log()  { printf '\n\033[1;36m═══ %s ═══\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --from) FROM="$2"; shift 2 ;;
    --skip-ci-check) SKIP_CI_CHECK=1; shift ;;
    --ci) CI_MODE="${2:-}"; shift 2 ;;
    body)  # body <tag>：只打印该 tag 的 release 正文
      [ $# -ge 2 ] || usage
      EXEC="body"; BODY_TAG="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) die "未知参数：$1" ;;
    *) if [ -z "$V" ]; then V="$1"; else die "多余参数：$1"; fi; shift ;;
  esac
done

REPO_ROOT="$(git rev-parse --show-toplevel)" || die "不在 git 仓库里"
cd "$REPO_ROOT"
[ "$(git branch --show-current)" = "main" ] || die "必须在 main 上打发布"
ORIGIN_URL=$(git remote get-url origin)
GH_REPO=$(printf '%s' "$ORIGIN_URL" | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##')
command -v gh >/dev/null || die "需要 gh CLI"
gh auth status >/dev/null 2>&1 || die "gh 未登录（gh auth status 查看详情）"

if [ -n "$CI_MODE" ] && [ "$CI_MODE" != "auto" ] && [ "$CI_MODE" != "gh" ] && [ "$CI_MODE" != "local" ]; then
  die "--ci 只接受 auto | gh | local"
fi
if [ "${EXEC:-}" != "body" ]; then
  [ -n "$V" ] || usage
  case "$V" in v*) die "版本号不要带 v 前缀（tag 会自己加）：scripts/release.sh ${V#v}" ;; esac
fi

TAG="v$V"
DD="/tmp/dd-release-$V"
SMOKE_DIR="/tmp/dd-release-smoke-$V"
ARTDIR="/tmp/desire-release-$V"
APP="$DD/Build/Products/Release/Desire.app"

# ── 通用小工具 ──────────────────────────────────────────────

bridge_wait() {  # bridge_wait <超时秒>
  local deadline=$(( $(date +%s) + ${1:-30} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if curl -s -m 2 http://127.0.0.1:8799/state | grep -q '"selected"'; then return 0; fi
    sleep 1
  done
  return 1
}

app_quit() {
  osascript -e 'quit app "Desire"' >/dev/null 2>&1 || true
  sleep 2
  pkill -9 -x Desire 2>/dev/null || true
}

changelog_section() {  # changelog_section <tag> —— 与 release.yml 同一提取逻辑
  awk -v tag="[$1]" '
    index($0, "## " tag) == 1 { flag = 1; next }
    flag && index($0, "## [") == 1 { exit }
    flag { print }
  ' CHANGELOG.md
}

assemble_body() {  # assemble_body <tag> —— 正文 = CHANGELOG 段 + 安装说明
  local tag="$1"
  changelog_section "$tag" > /tmp/release-body.md
  [ -s /tmp/release-body.md ] || return 1
  sed "s|__TAG__|${tag}|g" scripts/install-note.template.md >> /tmp/release-body.md
  cat /tmp/release-body.md
}

# ── 阶段 ────────────────────────────────────────────────────

stage_prep() {
  log "prep：冻结 CHANGELOG + 版本号，提交并推送"
  [ -f CHANGELOG.md ] || die "没有 CHANGELOG.md"
  grep -qF "## [$TAG]" CHANGELOG.md || die "CHANGELOG.md 里没有 '## [$TAG]' 段——先写好发布说明再跑"
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then die "本地已有 tag $TAG"; fi
  if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then die "远端已有 release $TAG"; fi

  echo "将提交的变更："
  git status --short
  printf '确认提交以上全部变更并推送？[y/N] '
  read -r answer || answer=""
  [ "$answer" = "y" ] || die "放弃"

  # 版本号：MARKETING_VERSION = $V；CURRENT_PROJECT_VERSION = 旧值 + 1
  local pbx="Desire.xcodeproj/project.pbxproj"
  local current_build
  current_build=$(grep -m1 "CURRENT_PROJECT_VERSION = " "$pbx" | grep -o '[0-9]\+')
  [ -n "$current_build" ] || die "读不到 CURRENT_PROJECT_VERSION"
  local next_build=$((current_build + 1))
  sed -i '' "s/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = $V;/g" "$pbx"
  sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $next_build;/g" "$pbx"
  grep -q "MARKETING_VERSION = $V;" "$pbx" || die "版本号替换失败"

  git add -A
  if ! git diff --cached --quiet; then
    git commit -m "release(v$V): v$V — freeze changelog and bump version ($next_build)"
  fi
  git push origin main
  echo "已推送 $(git rev-parse --short HEAD)，构建号 → $next_build"
}

# GitHub CI 不可用（额度烧尽 / 工作流被关）时的本地等价验证：
# 单测 + 评估套件，正是 ci.yml 在远端跑的那两样。
run_local_suite() {
  bash tests/run.sh || die "本地单测未过"
  echo "── 本地评估套件 ──"
  pkill -9 -x Desire 2>/dev/null || true; sleep 2
  open "$APP" --args --automation
  bridge_wait 30 || die "桥没起来（${APP}"
  python3 tests/agent-eval.py --cleanup || die "评估套件未过"
  app_quit
  echo "本地全套验证 ✓（单测 + 评估 16 项）"
}

stage_ci() {
  log "ci：HEAD 质量闸门（模式：${CI_MODE}"
  if [ "$SKIP_CI_CHECK" = 1 ]; then echo "（--skip-ci-check：完全跳过）"; return 0; fi
  if [ "$CI_MODE" = "local" ]; then run_local_suite; return 0; fi

  local sha run=""
  sha=$(git rev-parse HEAD)
  for _ in $(seq 1 18); do   # 最多等 3 分钟让 run 出现
    run=$(gh run list --repo "$GH_REPO" --branch main --limit 20 \
            --json headSha,databaseId -q ".[] | select(.headSha==\"$sha\") | .databaseId" 2>/dev/null | head -1)
    if [ -n "$run" ]; then break; fi
    sleep 10
  done
  if [ -z "$run" ]; then
    if [ "$CI_MODE" = "gh" ]; then
      die "HEAD ($sha) 没有触发 CI（--ci gh 强依赖远端）。先确认推送成功，或改用 --ci local"
    fi
    echo "（HEAD 没有 CI run——GitHub Actions 大概率已不可用（额度烧尽/工作流被关）。"
    echo "  回落到本地全套验证。）"
    run_local_suite
    return 0
  fi
  echo "watching run $run"
  gh run watch "$run" --repo "$GH_REPO" --exit-status --interval 30 \
    || die "CI 未绿。红着不能发版（v0.3.14 的教训）。修完 push 重跑 $0 $V --from ci；若是额度烧尽导致 run 根本没跑起来，改用 --ci local"
}

stage_build() {
  log "build：clean Release 构建（零警告闸门）"
  rm -rf "$DD"
  local logfile="/tmp/dd-release-$V-build.log"
  xcodebuild -project Desire.xcodeproj -scheme Desire -configuration Release \
    -derivedDataPath "$DD" clean build 2>&1 | tee "$logfile" | grep -E "BUILD (SUCCEEDED|FAILED)" || true
  grep -q "BUILD SUCCEEDED" "$logfile" || die "构建失败，日志在 $logfile"
  # 路径在 warning: 之前，惯用 grep 匹配不到；只豁免 appintentsmetadataprocessor
  if grep -E "warning:" "$logfile" | grep -v appintentsmetadataprocessor | head -5 | grep -q .; then
    grep -E "warning:" "$logfile" | grep -v appintentsmetadataprocessor | head -10
    die "存在构建警告——修完再发（v0.3.12 带着 6 条警告发出去的教训）"
  fi
  local ver
  ver=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
  [ "$ver" = "$V" ] || die "构建产物版本是 ${ver}，不是 ${V}"
  echo "构建 ✓ ${APP}（版本 ${ver}）"
}

stage_smoke() {
  log "smoke：从非 DerivedData 路径启动 + 桥探活"
  rm -rf "$SMOKE_DIR"; mkdir -p "$SMOKE_DIR"
  ditto "$APP" "$SMOKE_DIR/Desire.app"
  pkill -9 -x Desire 2>/dev/null || true; sleep 2
  open "$SMOKE_DIR/Desire.app" --args --automation
  bridge_wait 30 || die "桥 30 秒内没起来（/state 无响应）——查 /usr/bin/log show --predicate 'process == \"Desire\"'"
  curl -s -m 5 http://127.0.0.1:8799/agent/stats | grep -q "conversations" || die "/agent/stats 异常"
  curl -s -m 5 http://127.0.0.1:8799/ai/profiles | grep -q "profiles" || die "/ai/profiles 异常"
  app_quit
  echo "冒烟 ✓（桥 + 统计 + 档案端点）"
}

stage_package() {
  log "package：打 zip + 校验和"
  rm -rf "$ARTDIR"; mkdir -p "$ARTDIR"
  ditto -c -k --keepParent "$APP" "$ARTDIR/Desire-$TAG-macos-arm64.zip"
  (cd "$ARTDIR" && shasum -a 256 "Desire-$TAG-macos-arm64.zip" > SHASUMS256.txt)
  cat "$ARTDIR/SHASUMS256.txt"
}

stage_publish() {
  log "publish：禁 Release 工作流（必须在 tag 前！）→ 推 tag → 建 Release"
  # 先做完所有可能失败的检查，最后才动工作流开关（--from publish 续跑时
  # prep 的查重没跑过，这里必须再查）。
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then die "本地已有 tag $TAG"; fi
  if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then die "远端已有 release $TAG"; fi
  gh workflow disable Release --repo "$GH_REPO" || die "禁用 Release 工作流失败"
  # 失败自动恢复：从这一刻起无论怎么退出，工作流都必须回到启用态。
  trap 'gh workflow enable Release --repo "$GH_REPO" >/dev/null 2>&1 || true' EXIT
  git tag "$TAG"
  git push origin "$TAG"
  assemble_body "$TAG" || die "CHANGELOG 里没有 $TAG 段？prep 应该已经拦住才对"
  gh release create "$TAG" \
    --repo "$GH_REPO" \
    --title "$TAG" \
    --notes-file /tmp/release-body.md \
    "$ARTDIR/Desire-$TAG-macos-arm64.zip" \
    "$ARTDIR/SHASUMS256.txt"
  echo "Release 已创建：https://github.com/$GH_REPO/releases/tag/$TAG"
}

stage_verify() {
  log "verify：从 release 重新下载 → 校验和 → 版本 → 启动（发版铁律）"
  local vdir="/tmp/release-verify-$V"
  rm -rf "$vdir"; mkdir -p "$vdir"
  gh release download "$TAG" --repo "$GH_REPO" --pattern "*.zip" --pattern "*.txt" --dir "$vdir" --clobber
  (cd "$vdir" && shasum -a 256 -c SHASUMS256.txt) || die "校验和不一致——发布产物被替换？"
  ditto -x -k "$vdir/Desire-$TAG-macos-arm64.zip" "$vdir/app"
  local ver
  ver=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$vdir/app/Desire.app/Contents/Info.plist")
  [ "$ver" = "$V" ] || die "下载产物的版本是 ${ver}，不是 ${V}"
  pkill -9 -x Desire 2>/dev/null || true; sleep 2
  open "$vdir/app/Desire.app" --args --automation
  bridge_wait 30 || die "下载产物启动后桥无响应"
  app_quit
  gh workflow enable Release --repo "$GH_REPO"
  echo ""
  echo "✅ v$V 发布完成并验证：Latest、校验和、版本、启动全过；Release 工作流已恢复。"
}

# ── 调试子命令：body <tag>（打印 release 正文，不发布任何东西）──
if [ "${EXEC:-}" = "body" ]; then
  assemble_body "$BODY_TAG" || die "CHANGELOG 里没有 $BODY_TAG 段"
  exit 0
fi

# ── 阶段调度 ────────────────────────────────────────────────

ORDER=(prep build ci smoke package publish verify)
START=-1
for i in "${!ORDER[@]}"; do
  if [ "${ORDER[$i]}" = "$FROM" ]; then START=$i; fi
done
[ "$START" -ge 0 ] || die "--from 未知阶段: $FROM (可选: prep ci build smoke package publish verify)"

for i in "${!ORDER[@]}"; do
  if [ "$i" -lt "$START" ]; then continue; fi
  "stage_${ORDER[$i]}"
done
