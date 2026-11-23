#!/usr/bin/env bash
#
# upstream-report.sh — XR1710G 上游日报（一次调用，紧凑输出）
#
# 覆盖：
#   naoki66  master 头、最新 release、我们的分支领先多少
#   pbodq2   最新 release tag、默认分支、距离发版多少天
#   fanboy   ubi2 分支头、相对我们基线的 ahead、内核/mt76 版本
#   结论     是否需要动作（版本漂移 / 新 tag / 停更）
#
# 只读：gh api + git show，不 fetch、不合并、不构建。
# 用法: scripts/upstream-report.sh [--no-color]
#
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1

GH=${GH:-gh}
OUR_REPO="kaiwater/ImmortalWrt-for-Gemtek-brightspeed"
N_REPO="naoki66/ImmortalWrt-for-Gemtek-brightspeed"
PB_REPO="pbodq2/OpenWRT-W1700K-XR1710G"
FAN_REPO="OpenWRT-fanboy/OpenW1700k"
FAN_BRANCH="ubi2"
PB_BRANCH="pbodq2-base"
N_BRANCH="naoki66-base"

api() { $GH api "$@" 2>/dev/null; }
jqv() { jq -r "$1" 2>/dev/null; }

# ── 基线（我们钉住的 pbodq2 tag）────────────────────────
BASE_TAG=""; BASE_SHA=""
if git cat-file -e "$PB_BRANCH:PBODQ2_BASE" 2>/dev/null; then
    BASE_TAG=$(git show "$PB_BRANCH:PBODQ2_BASE" | sed -n '1p' | tr -d '[:space:]')
    BASE_SHA=$(git show "$PB_BRANCH:PBODQ2_BASE" | sed -n '2p' | tr -d '[:space:]')
fi

kernel_at() {  # repo ref -> 6.18.NN
    api "repos/$1/contents/target/linux/generic/kernel-6.18?ref=$2" \
        | jqv '.content' | base64 -d 2>/dev/null \
        | sed -n 's/^LINUX_VERSION-6\.18 = //p' | head -1
}
mt76_at() {    # repo ref -> source date
    api "repos/$1/contents/package/kernel/mt76/Makefile?ref=$2" \
        | jqv '.content' | base64 -d 2>/dev/null \
        | sed -n 's/^PKG_SOURCE_DATE:=//p' | head -1
}
commit_meta() {  # repo ref -> "sha date"
    api "repos/$1/commits/$2" | jq -r '.sha[0:8] + " " + .commit.committer.date[0:10]' 2>/dev/null
}
rel_meta() {     # repo -> "tag date"
    api "repos/$1/releases/latest" | jq -r '.tag_name + " " + .published_at[0:10]' 2>/dev/null
}
days_since() {   # YYYY-MM-DD -> N
    [ -n "${1:-}" ] || { echo "?"; return; }
    python3 - "$1" <<'PY' 2>/dev/null || echo "?"
import sys, datetime
d = datetime.date.fromisoformat(sys.argv[1])
print((datetime.date.today() - d).days)
PY
}

N_HEAD=$(commit_meta "$N_REPO" master)
N_REL=$(rel_meta "$OUR_REPO")
PB_REL=$(rel_meta "$PB_REPO")
PB_DEF_BRANCH=$(api "repos/$PB_REPO" | jqv '.default_branch')
PB_DEF_HEAD=$(commit_meta "$PB_REPO" "${PB_DEF_BRANCH:-ubi2_mod}")
FAN_HEAD=$(commit_meta "$FAN_REPO" "$FAN_BRANCH")

BASE_K=$(kernel_at "$PB_REPO" "$BASE_TAG")
BASE_M=$(mt76_at "$PB_REPO" "$BASE_TAG")
FAN_K=$(kernel_at "$FAN_REPO" "$FAN_BRANCH")
FAN_M=$(mt76_at "$FAN_REPO" "$FAN_BRANCH")

FAN_CMP=$(api "repos/$PB_REPO/compare/$BASE_SHA...OpenWRT-fanboy:$FAN_BRANCH")
FAN_AHEAD=$(printf '%s' "$FAN_CMP" | jq -r '.ahead_by // "?"' 2>/dev/null)
FAN_BEHIND=$(printf '%s' "$FAN_CMP" | jq -r '.behind_by // "?"' 2>/dev/null)

PB_TAG_AGE=$(days_since "$(printf '%s' "$PB_REL" | awk '{print $2}')")
N_REL_AGE=$(days_since "$(printf '%s' "$N_REL" | awk '{print $2}')")

# 我们的 naoki66-base 比最新 release 多多少提交
N_REL_TAG=$(printf '%s' "$N_REL" | awk '{print $1}')
N_AHEAD=$(api "repos/$OUR_REPO/compare/$N_REL_TAG...$N_BRANCH" | jq -r '.ahead_by // "?"' 2>/dev/null)
OVERLAY_N=$(git rev-list --count "$BASE_SHA..$PB_BRANCH" 2>/dev/null || echo "?")

# ── 结论 ────────────────────────────────────────────────
VERDICT="NO ACTION"
NOTES=""
if [ -n "$BASE_TAG" ] && [ -n "$(printf '%s' "$PB_REL" | awk '{print $1}')" ] \
   && [ "$(printf '%s' "$PB_REL" | awk '{print $1}')" != "$BASE_TAG" ]; then
    VERDICT="NEW PBODQ2 TAG"
    NOTES="$NOTES\n  - pbodq2 发了新 tag：$(printf '%s' "$PB_REL" | awk '{print $1}')（基线 $BASE_TAG），按 docs/upstream-pbodq2.md 评估迁移"
fi
if [ -n "${BASE_K:-}" ] && [ -n "${FAN_K:-}" ] && [ "$BASE_K" != "$FAN_K" ]; then
    [ "$VERDICT" = "NO ACTION" ] && VERDICT="VERSION DRIFT"
    NOTES="$NOTES\n  - 内核漂移：6.18$BASE_K -> 6.18$FAN_K（fanboy ubi2）"
fi
if [ -n "${BASE_M:-}" ] && [ -n "${FAN_M:-}" ] && [ "$BASE_M" != "$FAN_M" ]; then
    [ "$VERDICT" = "NO ACTION" ] && VERDICT="VERSION DRIFT"
    NOTES="$NOTES\n  - mt76 漂移：$BASE_M -> $FAN_M（fanboy ubi2）"
fi
if [ "${PB_TAG_AGE:-0}" != "?" ] && [ "${PB_TAG_AGE:-0}" -ge 30 ] 2>/dev/null; then
    [ "$VERDICT" = "NO ACTION" ] && VERDICT="PBODQ2 STALE"
    NOTES="$NOTES\n  - pbodq2 已 ${PB_TAG_AGE} 天未发版（阈值 30 天），考虑切 fanboy + 自有 XR1710G 覆盖"
fi

# ── 输出 ────────────────────────────────────────────────
printf '==== XR1710G 上游日报 %s ====\n\n' "$(date '+%Y-%m-%d %H:%M')"

N_HEAD_DATE=$(printf '%s' "${N_HEAD:-}" | awk '{print $2}')
N_HEAD_AGE=$(days_since "$N_HEAD_DATE")
printf 'naoki66   master %s（%s 天前）\n' "${N_HEAD:-?}" "${N_HEAD_AGE}"
printf '          release %s（%s 天）  分支 %s 领先 %s 个提交\n' \
    "${N_REL:-?}" "${N_REL_AGE}" "$N_BRANCH" "${N_AHEAD:-?}"

printf '\npbodq2    release %s（%s 天）  默认分支 %s %s\n' \
    "${PB_REL:-?}" "${PB_TAG_AGE}" "${PB_DEF_BRANCH:-?}" "${PB_DEF_HEAD:-?}"
printf '          我们钉在 %s (%s)，overlay %s 个提交\n' \
    "${BASE_TAG:-?}" "${BASE_SHA:0:8}" "$OVERLAY_N"

printf '\nfanboy    %s %s   ahead=%s behind=%s\n' \
    "$FAN_BRANCH" "${FAN_HEAD:-?}" "${FAN_AHEAD:-?}" "${FAN_BEHIND:-?}"
printf '          kernel 6.18%s（基线 6.18%s）  mt76 %s（基线 %s）\n' \
    "${FAN_K:-?}" "${BASE_K:-?}" "${FAN_M:-?}" "${BASE_M:-?}"

printf '\n结论: %s\n' "$VERDICT"
[ -n "$NOTES" ] && printf '%b\n' "$NOTES"
echo
