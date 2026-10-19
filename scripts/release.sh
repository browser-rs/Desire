#!/bin/bash
# Desire 发布流程（一键化）。2026-10-19 流程重组：闸门内置、默认本地验证、
# 快档核验——目标"顺畅发版、快速发版"（默认全程 ~15 分钟，不等 GitHub）。
#
# 用法：
#   scripts/release.sh <版本号>            # 默认：gates→prep→build→ci(local)→smoke→package→publish→verify(快档)
#   scripts/release.sh <版本号> --from package   # 某一步失败后从该步重跑
#   scripts/release.sh <版本号> --ci gh          # 强依赖远端 CI（抽查环境差异用，等 10-15 分钟）
#   scripts/release.sh <版本号> --ci auto        # 有 HEAD 的 run 就等，没有回落本地
#   scripts/release.sh <版本号> --verify-download # verify 走真实重下载（网络好时/抽检）
#   scripts/release.sh <版本号> --skip-e2e-stamp  # 应急：跳过套件戳校验（会大字警告）
#   scripts/release.sh <版本号> --no-x86_64       # 跳过 Intel 包（默认 arm64+x86_64 双产物）
#   scripts/release.sh body v0.7.24        # 只打印该 tag 的 release 正文（调试用）
#
# 阶段：gates → prep → build → ci → package → publish → verify
#   构建快路径（2026-10-20）：预检 --build 全绿会写 .git/desire-build-stamp；发版
#   时若同一份源码已有 clean 零警告构建 → 复用其 DerivedData 只做增量重链接
#   （版本号变化由增量拾取）——发版动作因此 ~8 分钟。删掉 .git/desire-build-stamp
#   即回退到 clean build。
#   （2026-10-20 精简：**删掉 smoke**——它与 verify 的"非 DerivedData 启动+桥探活"
#    完全冗余，verify 从打包产物启动覆盖面更全。ci 在套件戳覆盖 HEAD 时自动跳过；
#    prep 自动冻结 CHANGELOG；退出时自动把阶段耗时记入 docs/RELEASE-RETRO.md。）
#   gates（2026-10-19 立）：干净树/CHANGELOG 结构/纯逻辑单测/远端查重/**套件戳**。
#     教训（v0.7.24）：预检曾独立成脚本、靠人记得跑——修复提交后忘跑预检就直接
#     发版的洞。现在闸门内置为第一站，永远跑在**最终提交**上。
#   ci 默认 local：本地评估套件 +（crates/ 有改动时）cargo fmt/test——ci.yml 的
#     本地等价物，几分钟出结果；远端 CI 改为 --ci gh 抽查（macOS runner 排队 +
#     全量构建要 10-15 分钟，例行发版不值得等；环境差异抽查每隔几版做一次）。
#   verify 默认快档：GitHub 资产 digest（服务端对上传字节的 sha256）与本地
#     SHASUMS/大小**三方比对** + 本地包（字节等同）非 DerivedData 路径启动冒烟；
#     真实重下载在资产 CDN 抽风时会拖几十分钟，降级为 --verify-download。
#
# 流程固化的教训（每条都是真踩过的，别删）：
#   • Release 工作流必须在**推 tag 之前** disable——它由 v* tag 触发、会自己构建
#     发布，抢 Latest。publish 阶段第一步就是它，verify 结束再 enable。
#   • **禁用态的 workflow 按名字 enable 会 "could not find"**（2026-10-19 实测）
#     ——用文件名：gh workflow enable release.yml。
#   • CI 必须绿才能打 tag（v0.3.14 红着发出去的教训）——--ci gh/auto 模式适用；
#     本地模式下 gates+build+评估套件就是等价闸门。
#   • 冒烟必须从**非 DerivedData 路径**启动：Keychain 条目 ACL 对 adhoc 构建
#     认路径/cdhash，换路径才暴露"授权窗永不渲染 → 启动挂死"这类问题。
#   • gh 一律带 --repo（从 git remote 推导）——mankong/Desire 会 404。
#   • "零警告"只有 clean build 算数：build 阶段每次删掉 DerivedData 重建。
#   • Intel（x86_64）产物默认随版发布（v0.7.14 曾只有 arm64、用户报"有构建没
#     产物"）——release.sh 本地交叉编译（与 arm64 包同源同签名）。装了 Rosetta
#     的机器 verify 会对 Intel 包做启动冒烟；没装则只核架构（如实标注）。
#   • 安装说明唯一真相 = scripts/install-note.template.md（CI 与本脚本共用）。
#   • 套件戳 = .git/desire-e2e-stamp（tests/execution-e2e.py 全绿收尾时写）；
#     gates 校验"戳之后的提交只动了白名单（CHANGELOG/website/pbxproj）"——
#     代码修复后必须重跑套件，别拿旧戳发新版。

set -euo pipefail

V=""
FROM="gates"
SKIP_CI_CHECK=0
CI_MODE="local"  # local（默认）：本地评估套件+cargo 闸门；auto：有 run 就等；gh：强依赖远端
WITH_X86=1       # 1 = build/package/verify 追加 Intel（x86_64）产物；--no-x86_64 关
VERIFY_DOWNLOAD=0  # 1 = verify 走真实重下载；默认快档（digest 三方 + 本地包冒烟）
SKIP_E2E_STAMP=0   # 1 = 跳过套件戳校验（应急；会大字警告）
FORCE_CI=0         # 1 = 即使套件戳覆盖 HEAD 也跑本地评估（--force-ci）

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
    --no-x86_64) WITH_X86=0; shift ;;
    --verify-download) VERIFY_DOWNLOAD=1; shift ;;
    --force-ci) FORCE_CI=1; shift ;;
    --skip-e2e-stamp) SKIP_E2E_STAMP=1; shift ;;
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
X86DD="/tmp/dd-release-$V-x86"
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

# 启动应用并等**主窗就绪**（/state tabs ≥ 1）。2026-10-20 实测：快速
# pkill -9 → open 后偶发"桥起来了但主窗不建"（SwiftUI 场景恢复竞态，与构建无关，
# 重开一次即恢复）——套件/eval/verify 都必须以主窗为准，否则窗口缺失也会假通过。
launch_wait_window() {  # <app 路径> <超时秒>
  local app="$1" timeout="${2:-40}" attempt=0 deadline n
  while [ "$attempt" -lt 2 ]; do
    deadline=$(( $(date +%s) + timeout ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
      n=$(curl -s -m 2 http://127.0.0.1:8799/state 2>/dev/null | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin).get("tabs",[])))
except Exception: print(0)' 2>/dev/null || echo 0)
      [ "${n:-0}" -ge 1 ] && return 0
      sleep 1
    done
    attempt=$((attempt+1))
    if [ "$attempt" -lt 2 ]; then
      echo "（启动后无主窗——重启一次）"
      pkill -9 -x Desire 2>/dev/null || true; sleep 3
      open "$app" --args --automation
    fi
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

assert_release_worktree_clean() {
  if [ -n "$(git status --porcelain)" ]; then
    die "发布前工作区必须干净；请先提交或暂存当前变更，发布脚本不会替你提交未知文件"
  fi
}

assert_no_secret_artifacts() {
  local path
  while IFS= read -r path; do
    case "$path" in
      .env|.env.*|*.key|*.pem|*.p12|*.mobileprovision|*.log|*.DS_Store|*/.DS_Store)
        die "检测到不应进入发布提交的文件：$path" ;;
    esac
  done < <(git ls-files --others --exclude-standard)
}

# ── 阶段 ────────────────────────────────────────────────────

# 套件戳校验（gates/ci 共用）：戳存在 + 其后提交只动白名单 → 0 并输出摘要；
# 1 = 无戳/戳无效；2 = 戳后有代码改动。白名单 = 不影响 app 行为/套件覆盖面的
# 文件（发版会动的 CHANGELOG/website/pbxproj + 不随 app 出货的 docs/scripts/
# tools/AGENTS）；tests/ 与 crates/ 与 app 源码不在名单（改它们必须重跑套件）。
STAMP_PATH=".git/desire-e2e-stamp"
stamp_summary() {
  [ -f "$STAMP_PATH" ] || return 1
  local sha meta changes
  sha=$(awk '{print $1}' "$STAMP_PATH")
  meta=$(awk '{print $2" 于 "$3}' "$STAMP_PATH")
  git cat-file -e "${sha}^{commit}" 2>/dev/null || return 1
  # 别用 case——macOS 自带 bash 3.2 在 $( ) 里解析 case 会炸（实测）。
  changes=$(git diff --name-only "${sha}..HEAD" | while IFS= read -r f; do
    if [[ "$f" != "CHANGELOG.md" && "$f" != website/* && "$f" != docs/* \
       && "$f" != scripts/* && "$f" != tools/* && "$f" != "AGENTS.md" \
       && "$f" != "apps/macos/Desire.xcodeproj/project.pbxproj" ]]; then
      printf '%s\n' "$f"
    fi
  done)
  [ -z "$changes" ] || return 2
  printf '%s %s' "$sha" "$meta"
  return 0
}

# 构建戳（2026-10-20）：tools/pre-release-check.sh --build 全绿后写
# .git/desire-build-stamp。release.sh 的 build 阶段据此判断"同一份源码已经过
# clean 零警告构建"——复用其 DerivedData 做**增量重链接**（版本号变化只需重链接），
# 不再重复 clean 构建。白名单同套件戳（pbxproj 在名单内：版本号变化靠增量拾取）。
BUILD_STAMP_PATH=".git/desire-build-stamp"
build_stamp_covers_head() {
  [ -f "$BUILD_STAMP_PATH" ] || return 1
  local sha changes
  sha=$(awk '{print $1}' "$BUILD_STAMP_PATH")
  git cat-file -e "${sha}^{commit}" 2>/dev/null || return 1
  changes=$(git diff --name-only "${sha}..HEAD" | while IFS= read -r f; do
    if [[ "$f" != "CHANGELOG.md" && "$f" != website/* && "$f" != docs/* \
       && "$f" != scripts/* && "$f" != tools/* && "$f" != "AGENTS.md" \
       && "$f" != "apps/macos/Desire.xcodeproj/project.pbxproj" ]]; then
      printf '%s\n' "$f"
    fi
  done)
  [ -z "$changes" ]
}

# prep 自动冻结（2026-10-20）：[Unreleased] 有条目就自动改名 vX.Y.Z（今天）并
# 提交——手工冻结这一步删掉，少一次人为顺序错误。
auto_freeze_changelog() {
  local today
  today=$(date +%F)
  if ! python3 - "$TAG" "$today" <<'PYF'
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
print(f"已自动冻结 {tag}（取 [Unreleased] 全段）")
PYF
  then die "自动冻结失败——CHANGELOG 里没有 [Unreleased] 条目，先写好发布说明"; fi
  git add CHANGELOG.md
  git commit -m "chore(release): freeze ${V} changelog section" >/dev/null
}

# ── 阶段计时 + 复盘自动入档（2026-10-20）──────────────
STAGE_TIMINGS=()
RETRO_DONE=0
finish_retro() {
  local outcome="$1" stamp t
  [ "${RETRO_DONE:-0}" = "1" ] && return 0
  RETRO_DONE=1
  [ -n "${V:-}" ] || return 0
  [ "${#STAGE_TIMINGS[@]}" -gt 0 ] || return 0
  [ -f docs/RELEASE-RETRO.md ] || return 0
  {
    printf '\n### v%s — %s（%s）\n\n' "$V" "$outcome" "$(date '+%Y-%m-%d %H:%M')"
    printf '| 阶段 | 耗时 |\n| --- | --- |\n'
    for t in ${STAGE_TIMINGS[@]+"${STAGE_TIMINGS[@]}"}; do
      printf '| %s | %s |\n' "${t%%:*}" "${t#*:}"
    done
    printf '\n（问题与反思待补。）\n'
  } >> docs/RELEASE-RETRO.md
  echo "阶段耗时已记入 docs/RELEASE-RETRO.md"
  git add docs/RELEASE-RETRO.md >/dev/null 2>&1 || true
  git commit -m "docs(release): retro timing v${V}" >/dev/null 2>&1 || true
  git push origin main >/dev/null 2>&1 || true
}
trap 'rc=$?; if [ "$rc" -ne 0 ] && [ -z "${EXEC:-}" ]; then finish_retro "失败（exit ${rc}）"; fi' EXIT

stage_gates() {
  log "gates：闸门（干净树 / 单测 / 结构 / 查重 / 套件戳）"
  assert_release_worktree_clean
  [ -f CHANGELOG.md ] || die "没有 CHANGELOG.md"
  python3 scripts/changelog.py verify || die "CHANGELOG 结构问题"

  echo "── 纯逻辑单测 ──"
  bash tests/run.sh || die "纯逻辑单测未过（本地 40 秒能发现的问题别带进发版）"

  if [ "${EXEC:-}" != "body" ]; then
    if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then die "本地已有 tag $TAG"; fi
    if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then die "远端已有 release $TAG"; fi
    echo "── 远端查重 ✓ 无 $TAG"
  fi

  if [ "$SKIP_E2E_STAMP" = 1 ]; then
    echo ""
    echo "⚠️  ⚠️  ⚠️  --skip-e2e-stamp：跳过了套件戳校验——本次发布没有"
    echo "⚠️  ⚠️  ⚠️  “这套代码跑过完整 E2E 套件”的机械证据。仅限应急！"
    echo ""
    return 0
  fi
  local summary
  if summary=$(stamp_summary); then
    echo "── 套件戳 ✓ ${summary}"
  else
    local rc=$?
    if [ "$rc" = 2 ]; then
      git diff --name-only "$(awk '{print $1}' "$STAMP_PATH")..HEAD" | head -5
      die "套件戳之后的提交动了代码（见上）——必须重跑完整套件再发版（别拿旧戳发新版）"
    fi
    die "没有可用的套件戳——先在干净树跑完整套件（python3 tests/execution-e2e.py），或应急 --skip-e2e-stamp"
  fi
}

stage_prep() {
  log "prep：冻结 CHANGELOG + 版本号，提交并推送"
  assert_release_worktree_clean
  assert_no_secret_artifacts
  [ -f CHANGELOG.md ] || die "没有 CHANGELOG.md"
  if ! grep -qF "## [$TAG]" CHANGELOG.md; then
    auto_freeze_changelog
  fi
  if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then die "本地已有 tag $TAG"; fi
  if gh release view "$TAG" --repo "$GH_REPO" >/dev/null 2>&1; then die "远端已有 release $TAG"; fi

  echo "发布脚本只允许提交 CHANGELOG、website/index.html 和 Xcode 版本文件。"
  printf '确认更新版本并推送？[y/N] '
  read -r answer || answer=""
  [ "$answer" = "y" ] || die "放弃"

  # CHANGELOG 结构闸门（2026-09-29 三次事故后立）：版本头唯一/顺序/无重复。
  python3 scripts/changelog.py verify

  # 产品页四处版本号同步（R4-11：此前发版靠手动改 website，漏改必错）。
  local website="website/index.html"
  if [ -f "$website" ]; then
    sed -i '' "s/\"softwareVersion\": \"[0-9.]*\"/\"softwareVersion\": \"$V\"/; \
                s/下载 Desire <span class=\"ver\">v[0-9.]*<\/span>/下载 Desire <span class=\"ver\">v$V<\/span>/; \
                s/当前版本 <b>v[0-9.]*<\/b>/当前版本 <b>v$V<\/b>/; \
                s/Desire-v[0-9.]*-macos-arm64\.zip，双击解压即可。/Desire-v$V-macos-arm64.zip，双击解压即可。/" "$website"
    echo "website 版本号已同步 → $V"
  fi

  # 版本号：MARKETING_VERSION = ${V}；CURRENT_PROJECT_VERSION = 旧值 + 1
  local pbx="apps/macos/Desire.xcodeproj/project.pbxproj"
  local current_build
  current_build=$(grep -m1 "CURRENT_PROJECT_VERSION = " "$pbx" | grep -o '[0-9]\+')
  [ -n "$current_build" ] || die "读不到 CURRENT_PROJECT_VERSION"
  local next_build=$((current_build + 1))
  sed -i '' "s/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = $V;/g" "$pbx"
  sed -i '' "s/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = $next_build;/g" "$pbx"
  grep -q "MARKETING_VERSION = $V;" "$pbx" || die "版本号替换失败"

  # 发版后的 Unreleased 空壳必须在同一个版本提交中落盘，不能在 commit 后
  # 修改却不提交，否则下一次发版会从未跟踪的工作树状态开始。
  python3 - <<'PYCH'
from pathlib import Path
p = Path("CHANGELOG.md")
s = p.read_text()
if "## [Unreleased]" not in s:
    p.write_text("## [Unreleased]\n\n" + s)
    print("已补空壳 [Unreleased] 段")
PYCH

  git add -- CHANGELOG.md website/index.html "$pbx"
  local unexpected
  unexpected=$(git diff --cached --name-only | while IFS= read -r path; do
    if [[ "$path" != "CHANGELOG.md" \
       && "$path" != "website/index.html" \
       && "$path" != "apps/macos/Desire.xcodeproj/project.pbxproj" ]]; then
      printf '%s\n' "$path"
    fi
  done)
  [ -z "$unexpected" ] || die "发布 staging 出现未允许文件：$unexpected"
  if ! git diff --cached --quiet; then
    git commit -m "release(v$V): v$V — freeze changelog and bump version ($next_build)"
  fi
  git push origin main
  echo "已推送 $(git rev-parse --short HEAD)，构建号 → $next_build"
}

# 本地等价验证（ci.yml 的本地版）：评估套件 +（crates/ 随版改动时）cargo 闸门。
# 纯逻辑单测已在 gates 阶段跑过，这里不重复。
run_local_suite() {
  local last_tag=""
  last_tag=$(git describe --tags --abbrev=0 2>/dev/null || true)
  if [ -n "$last_tag" ] && git diff --name-only "$last_tag..HEAD" | grep -q '^crates/'; then
    echo "── cargo fmt + test（crates/ 有改动）──"
    cargo fmt --check || die "cargo fmt 未过"
    cargo test --workspace || die "cargo test 未过"
  fi
  echo "── 本地评估套件 ──"
  pkill -9 -x Desire 2>/dev/null || true; sleep 2
  open "$APP" --args --automation
  launch_wait_window "$APP" 40 || die "启动后主窗未就绪（重开一次仍无）——${APP}"
  # 评估套件还需要**活的 Agent 会话**（主窗 ≠ 会话注册完成）。
  local session_ready=0
  for _ in $(seq 1 30); do
    if curl -s -m 2 http://127.0.0.1:8799/agent/windows 2>/dev/null | grep -q '"id"'; then
      session_ready=1; break
    fi
    sleep 1
  done
  [ "$session_ready" = 1 ] || die "Agent 会话未注册（窗口/场景未就绪）——重跑 $0 $V --from ci"
  python3 tests/agent-eval.py --cleanup || die "评估套件未过"
  app_quit
  echo "本地验证 ✓（gates 单测 + 评估套件）"
}

stage_ci() {
  log "ci：HEAD 质量闸门（模式：${CI_MODE}"
  if [ "$SKIP_CI_CHECK" = 1 ]; then echo "（--skip-ci-check：完全跳过）"; return 0; fi
  # 套件戳已覆盖 HEAD（含 189 项 UI 套件）→ 本地评估套件与之高度冗余，跳过。
  # （--force-ci 强制；--ci gh 仍走远端。）
  if [ "$CI_MODE" != "gh" ] && [ "$FORCE_CI" != 1 ]; then
    if stamp_summary >/dev/null 2>&1; then
      echo "── 套件戳已覆盖 HEAD（189 项 UI 套件）——跳过冗余本地评估（--force-ci 可强制）"
      return 0
    fi
  fi
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

warn_gate() {  # warn_gate <logfile> <label> —— 零警告闸门（路径在 warning: 之前，
               # 惯用 grep 匹配不到；只豁免 appintentsmetadataprocessor）
  if grep -E "warning:" "$1" | grep -v appintentsmetadataprocessor | head -5 | grep -q .; then
    grep -E "warning:" "$1" | grep -v appintentsmetadataprocessor | head -10
    die "$2 存在构建警告——修完再发（v0.3.12 带着 6 条警告发出去的教训）"
  fi
}

# 快路径：复用预检的 clean 构建（同一份源码、零警告已验证过）→ 只做增量重链接。
# 版本号变化（pbxproj）由增量构建拾取；产物版本仍强制核对。
stage_build_incremental() {
  log "build：复用预检 clean 构建（增量重链接；零警告已在预检阶段验证）"
  DD="/tmp/dd-precheck"
  X86DD="/tmp/dd-precheck-x86"
  APP="$DD/Build/Products/Release/Desire.app"
  local logfile="/tmp/dd-release-$V-build.log"
  xcodebuild -project apps/macos/Desire.xcodeproj -scheme Desire -configuration Release \
    -derivedDataPath "$DD" build 2>&1 | tee "$logfile" | grep -E "BUILD (SUCCEEDED|FAILED)" || true
  grep -q "BUILD SUCCEEDED" "$logfile" || die "增量构建失败，日志在 $logfile（急救：删 .git/desire-build-stamp 走 clean）"
  warn_gate "$logfile" "arm64（增量）"
  local ver
  ver=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
  [ "$ver" = "$V" ] || die "增量产物版本是 ${ver}，不是 ${V}（版本号未被增量拾取）"
  echo "构建 ✓ ${APP}（版本 ${ver}，增量）"
  if [ "$WITH_X86" = 1 ]; then
    local log86="/tmp/dd-release-$V-x86-build.log"
    xcodebuild -project apps/macos/Desire.xcodeproj -scheme Desire -configuration Release \
      -derivedDataPath "$X86DD" -destination 'platform=macOS' \
      ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO COMPILER_INDEX_STORE_ENABLE=NO \
      build 2>&1 | tee "$log86" | grep -E "BUILD (SUCCEEDED|FAILED)" || true
    grep -q "BUILD SUCCEEDED" "$log86" || die "x86_64 增量构建失败，日志在 ${log86}"
    warn_gate "$log86" "x86_64（增量）"
    local ver86
    ver86=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$X86DD/Build/Products/Release/Desire.app/Contents/Info.plist")
    [ "$ver86" = "$V" ] || die "x86 增量产物版本是 ${ver86}，不是 ${V}"
    echo "x86_64 构建 ✓（增量）"
  fi
}

stage_build() {
  if build_stamp_covers_head \
     && [ -d "/tmp/dd-precheck/Build/Products/Release/Desire.app" ] \
     && { [ "$WITH_X86" != 1 ] || [ -d "/tmp/dd-precheck-x86/Build/Products/Release/Desire.app" ]; }; then
    stage_build_incremental
    return 0
  fi
  log "build：clean Release 构建（零警告闸门）"
  rm -rf "$DD"
  local logfile="/tmp/dd-release-$V-build.log"
  xcodebuild -project apps/macos/Desire.xcodeproj -scheme Desire -configuration Release \
    -derivedDataPath "$DD" clean build 2>&1 | tee "$logfile" | grep -E "BUILD (SUCCEEDED|FAILED)" || true
  grep -q "BUILD SUCCEEDED" "$logfile" || die "构建失败，日志在 $logfile"
  warn_gate "$logfile" "arm64"
  local ver
  ver=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
  [ "$ver" = "$V" ] || die "构建产物版本是 ${ver}，不是 ${V}"
  echo "构建 ✓ ${APP}（版本 ${ver}）"

  if [ "$WITH_X86" = 1 ]; then
    echo "── x86_64 交叉构建（Intel 包）──"
    rm -rf "$X86DD"
    local log86="/tmp/dd-release-$V-x86-build.log"
    xcodebuild -project apps/macos/Desire.xcodeproj -scheme Desire -configuration Release \
      -derivedDataPath "$X86DD" -destination 'platform=macOS' \
      ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO COMPILER_INDEX_STORE_ENABLE=NO \
      clean build 2>&1 | tee "$log86" | grep -E "BUILD (SUCCEEDED|FAILED)" || true
    grep -q "BUILD SUCCEEDED" "$log86" || die "x86_64 构建失败，日志在 ${log86}（修完重跑；急救可 --from build --no-x86_64 先发 arm64）"
    warn_gate "$log86" "x86_64"
    local ver86
    ver86=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$X86DD/Build/Products/Release/Desire.app/Contents/Info.plist")
    [ "$ver86" = "$V" ] || die "x86_64 构建产物版本是 ${ver86}，不是 ${V}"
    echo "x86_64 构建 ✓"
  fi
}

stage_package() {
  log "package：打 zip + 校验和"
  rm -rf "$ARTDIR"; mkdir -p "$ARTDIR"
  ditto -c -k --keepParent "$APP" "$ARTDIR/Desire-$TAG-macos-arm64.zip"
  if [ "$WITH_X86" = 1 ]; then
    local app86="$X86DD/Build/Products/Release/Desire.app"
    [ -d "$app86" ] || die "x86_64 构建产物缺失（${app86}）——从 build 阶段重跑，或 --from package --no-x86_64"
    ditto -c -k --keepParent "$app86" "$ARTDIR/Desire-$TAG-macos-x86_64.zip"
  fi
  (cd "$ARTDIR" && shasum -a 256 Desire-*.zip > SHASUMS256.txt)
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
  local uploads=("$ARTDIR/Desire-$TAG-macos-arm64.zip" "$ARTDIR/SHASUMS256.txt")
  if [ "$WITH_X86" = 1 ]; then
    uploads=("$ARTDIR/Desire-$TAG-macos-arm64.zip" "$ARTDIR/Desire-$TAG-macos-x86_64.zip" "$ARTDIR/SHASUMS256.txt")
  fi
  gh release create "$TAG" \
    --repo "$GH_REPO" \
    --title "$TAG" \
    --notes-file /tmp/release-body.md \
    "${uploads[@]}"
  echo "Release 已创建：https://github.com/$GH_REPO/releases/tag/$TAG"
}

# verify 快档（2026-10-19 立）：GitHub 资产 digest 是**服务端对上传字节的
# sha256**——与本地 SHASUMS/文件大小三方比对，等价于"重新下载再校验"，且不
# 吃资产 CDN 的超时（近期多次拖 20+ 分钟最后还得手工收口）。本地包与远端字节
# 等同（digest 一致即证），冒烟照跑：非 DerivedData 路径启动 + 版本核对。
stage_verify_fast() {
  log "verify：digest 三方比对 + 本地包启动冒烟（快档；--verify-download 换真实重下载）"
  local digests="/tmp/release-verify-digests-$V.txt"
  gh api "repos/$GH_REPO/releases/tags/$TAG" \
    --jq '.assets[] | "\(.name)\t\(.size)\t\(.digest)"' > "$digests" \
    || die "读远端资产清单失败"
  (cd "$ARTDIR" && shasum -a 256 -c SHASUMS256.txt) || die "本地包校验和自检失败"
  if ! python3 - "$ARTDIR" "$digests" <<'PYV'
import hashlib, pathlib, sys
art, digest_file = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
ok = True
for line in digest_file.read_text().splitlines():
    parts = line.split("\t")
    if len(parts) != 3:
        print("✗ 远端资产行解析失败:", line); ok = False; continue
    name, size, digest = parts
    f = art / name
    if not f.exists():
        print(f"✗ 本地缺资产 {name}"); ok = False; continue
    data = f.read_bytes()
    if len(data) != int(size):
        print(f"✗ {name} 大小不符：本地 {len(data)} vs 远端 {size}"); ok = False; continue
    if "sha256:" + hashlib.sha256(data).hexdigest() != digest:
        print(f"✗ {name} sha256 不符"); ok = False; continue
    print(f"✓ {name}（{size} bytes，sha256 三方一致）")
sys.exit(0 if ok else 1)
PYV
  then die "资产 digest 三方比对失败——发布产物被替换？"; fi
  # 本地包（与远端字节等同）非 DerivedData 路径启动冒烟 + 版本核对。
  local vdir="/tmp/release-verify-$V"
  rm -rf "$vdir"; mkdir -p "$vdir"
  ditto -x -k "$ARTDIR/Desire-$TAG-macos-arm64.zip" "$vdir/app"
  local ver
  ver=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$vdir/app/Desire.app/Contents/Info.plist")
  [ "$ver" = "$V" ] || die "产物的版本是 ${ver}，不是 ${V}"
  pkill -9 -x Desire 2>/dev/null || true; sleep 2
  open "$vdir/app/Desire.app" --args --automation
  bridge_wait 30 || die "产物启动后桥无响应"
  launch_wait_window "$vdir/app/Desire.app" 40 || die "产物启动后主窗未就绪（重开一次仍无）"
  app_quit
  if [ "$WITH_X86" = 1 ] && [ -f "$ARTDIR/Desire-$TAG-macos-x86_64.zip" ]; then
    ditto -x -k "$ARTDIR/Desire-$TAG-macos-x86_64.zip" "$vdir/app86"
    local archs
    archs=$(lipo -archs "$vdir/app86/Desire.app/Contents/MacOS/Desire")
    [[ "$archs" == *x86_64* ]] || die "x86_64 包里不是 Intel 二进制：$archs"
    if arch -x86_64 /usr/bin/true 2>/dev/null; then
      pkill -9 -x Desire 2>/dev/null || true; sleep 2
      open "$vdir/app86/Desire.app" --args --automation
      bridge_wait 60 || die "x86_64 产物启动后桥无响应（Rosetta）"
      app_quit
      echo "x86_64 包 ✓（digest + 架构 + Rosetta 启动冒烟）"
    else
      echo "x86_64 包 ✓（digest + 架构；本机无 Rosetta，未启动冒烟）"
    fi
  fi
  gh workflow enable release.yml --repo "$GH_REPO"   # 按文件名（禁用态按名字 enable 会 could not find，实测）
  echo ""
  echo "✅ v$V 发布完成并验证（快档：digest 三方 + 本地包启动冒烟）；Release 工作流已恢复。"
}

stage_verify() {
  if [ "$VERIFY_DOWNLOAD" != 1 ]; then
    stage_verify_fast
    return 0
  fi
  log "verify（--verify-download）：从 release 重新下载 → 校验和 → 版本 → 启动"
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
  launch_wait_window "$vdir/app/Desire.app" 40 || die "下载产物启动后主窗未就绪"
  app_quit
  # x86_64 包：核对架构；release 机器装了 Rosetta 就顺带启动冒烟。
  local zip86="$vdir/Desire-$TAG-macos-x86_64.zip"
  if [ -f "$zip86" ]; then
    ditto -x -k "$zip86" "$vdir/app86"
    local archs
    archs=$(lipo -archs "$vdir/app86/Desire.app/Contents/MacOS/Desire")
    [[ "$archs" == *x86_64* ]] || die "x86_64 包里不是 Intel 二进制：$archs"
    if arch -x86_64 /usr/bin/true 2>/dev/null; then
      pkill -9 -x Desire 2>/dev/null || true; sleep 2
      open "$vdir/app86/Desire.app" --args --automation
      bridge_wait 60 || die "x86_64 下载产物启动后桥无响应（Rosetta）"
      app_quit
      echo "x86_64 包 ✓（校验和 + 架构 + Rosetta 启动冒烟）"
    else
      echo "x86_64 包 ✓（校验和 + 架构；本机无 Rosetta，未启动冒烟）"
    fi
  fi
  gh workflow enable release.yml --repo "$GH_REPO"
  echo ""
  echo "✅ v$V 发布完成并验证：Latest、校验和、版本、启动全过；Release 工作流已恢复。"
}

# ── 调试子命令：body <tag>（打印 release 正文，不发布任何东西）──
if [ "${EXEC:-}" = "body" ]; then
  assemble_body "$BODY_TAG" || die "CHANGELOG 里没有 $BODY_TAG 段"
  exit 0
fi

# ── 阶段调度 ────────────────────────────────────────────────

ORDER=(gates prep build ci package publish verify)
START=-1
for i in "${!ORDER[@]}"; do
  if [ "${ORDER[$i]}" = "$FROM" ]; then START=$i; fi
done
[ "$START" -ge 0 ] || die "--from 未知阶段: $FROM (可选: gates prep build ci package publish verify)"

for i in "${!ORDER[@]}"; do
  if [ "$i" -lt "$START" ]; then continue; fi
  _stage_name="${ORDER[$i]}"
  _t0=$(date +%s)
  "stage_${_stage_name}"
  STAGE_TIMINGS+=("${_stage_name}:$(( $(date +%s) - _t0 ))s")
done
finish_retro "成功"
