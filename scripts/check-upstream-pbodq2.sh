#!/usr/bin/env bash
#
# check-upstream-pbodq2.sh — pbodq2 线：上游 release tag vs 我们的 pbodq2-base
#
# 上游仓库 pbodq2/OpenWRT-W1700K-XR1710G 只发 tag（ubi2-YYYYMMDD），不发分支。
# 本脚本只读：gh api / git log，不 fetch、不合并、不构建。
#
# 基线 tag 记录在分支内的 PBODQ2_BASE 文件（两行：tag 和 sha），
# 这样脚本不依赖本地是否恰好有那个 tag 对象。
#
# 用法:
#   scripts/check-upstream-pbodq2.sh
#   scripts/check-upstream-pbodq2.sh --short
#
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1

PB_REPO="${PB_REPO:-pbodq2/OpenWRT-W1700K-XR1710G}"
PB_BRANCH="${PB_BRANCH:-pbodq2-base}"
FAN_REPO="${FAN_REPO:-OpenWRT-fanboy/OpenW1700k}"
FAN_BRANCH="${FAN_BRANCH:-ubi2}"
SHORT=0

while [ $# -gt 0 ]; do
    case "$1" in
        --short) SHORT=1 ;;
        --no-fetch) : ;;   # 兼容主脚本参数；本脚本不 fetch
        -h|--help) sed -n '3,18p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

git rev-parse --verify -q "$PB_BRANCH" >/dev/null || {
    echo "找不到分支 $PB_BRANCH" >&2; exit 1
}
BR_SHA=$(git rev-parse "$PB_BRANCH")
BR_SHORT=$(git rev-parse --short "$BR_SHA")

# ── 我们记录的基线 ──────────────────────────────────────
BASE_TAG=""; BASE_SHA=""
if git cat-file -e "$PB_BRANCH:PBODQ2_BASE" 2>/dev/null; then
    BASE_TAG=$(git show "$PB_BRANCH:PBODQ2_BASE" | sed -n '1p' | tr -d '[:space:]')
    BASE_SHA=$(git show "$PB_BRANCH:PBODQ2_BASE" | sed -n '2p' | tr -d '[:space:]')
fi
[ -n "$BASE_TAG" ] || BASE_TAG="unknown"

# ── 上游最新 release tag ────────────────────────────────
LATEST_TAG=""; LATEST_SHA=""
if command -v gh >/dev/null 2>&1; then
    LATEST_TAG=$(gh release view --repo "$PB_REPO" --json tagName --jq '.tagName' 2>/dev/null || true)
    if [ -z "$LATEST_TAG" ]; then
        LATEST_TAG=$(gh api "repos/$PB_REPO/releases/latest" --jq '.tag_name' 2>/dev/null || true)
    fi
    if [ -n "$LATEST_TAG" ]; then
        LATEST_SHA=$(gh api "repos/$PB_REPO/commits/$LATEST_TAG" --jq '.sha[0:8]' 2>/dev/null || true)
    fi
fi

if [ -z "$LATEST_TAG" ]; then
    echo "pbodq2: 无法获取上游最新 release（网络或 gh 认证问题）" >&2
    exit 0
fi

# ── 上游版本信息（内核 / mt76）──────────────────────────
ver_of() {  # $1=repo $2=ref -> "kernel=... mt76=..."
    local repo="$1" ref="$2" k v
    k=$(gh api "repos/$repo/contents/target/linux/generic/kernel-6.18?ref=$ref" \
            --jq '.content' 2>/dev/null | base64 -d 2>/dev/null \
            | sed -n 's/^LINUX_VERSION-6\.18 = //p' | head -1)
    v=$(gh api "repos/$repo/contents/package/kernel/mt76/Makefile?ref=$ref" \
            --jq '.content' 2>/dev/null | base64 -d 2>/dev/null \
            | sed -n 's/^PKG_SOURCE_DATE:=//p' | head -1)
    printf 'kernel=6.18%s mt76=%s' "${k:-?}" "${v:-?}"
}

BASE_VER=$(ver_of "$PB_REPO" "$BASE_TAG")
LATEST_VER=$(ver_of "$PB_REPO" "$LATEST_TAG")

# ── 上游默认分支（可能领先 tag，未发版）────────────────
DEF_BRANCH=""; DEF_SHA=""; DEF_DATE=""; DEF_AHEAD="?"; DEF_BEHIND="?"; DEF_COMMITS=""
if command -v gh >/dev/null 2>&1; then
    DEF_BRANCH=$(gh api "repos/$PB_REPO" --jq '.default_branch' 2>/dev/null || true)
    if [ -n "$DEF_BRANCH" ]; then
        DEF_META=$(gh api "repos/$PB_REPO/commits/$DEF_BRANCH" 2>/dev/null || true)
        DEF_SHA=$(printf '%s' "$DEF_META" | jq -r '.sha[0:8] // ""' 2>/dev/null)
        DEF_DATE=$(printf '%s' "$DEF_META" | jq -r '.commit.committer.date[0:10] // ""' 2>/dev/null)
        CMP2=$(gh api "repos/$PB_REPO/compare/$LATEST_TAG...$DEF_BRANCH" 2>/dev/null || true)
        if [ -n "$CMP2" ]; then
            DEF_AHEAD=$(printf '%s' "$CMP2" | jq -r '.ahead_by // "?"' 2>/dev/null)
            DEF_BEHIND=$(printf '%s' "$CMP2" | jq -r '.behind_by // "?"' 2>/dev/null)
            DEF_COMMITS=$(printf '%s' "$CMP2" | jq -r '.commits[]? | "  " + .sha[0:8] + " " + (.commit.message | split("\n")[0])' 2>/dev/null | head -20)
        fi
    fi
fi
DEF_VER=""
if [ -n "$DEF_BRANCH" ] && [ "${DEF_AHEAD:-0}" != "0" ]; then
    DEF_VER=$(ver_of "$PB_REPO" "$DEF_BRANCH")
fi

# ── 更上游：fanboy 的 ubi2 分支 ────────────────────────
FAN_SHA=""; FAN_DATE=""; FAN_AHEAD="?"; FAN_BEHIND="?"; FAN_COMMITS=""; FAN_VER=""
if command -v gh >/dev/null 2>&1; then
    FAN_OWNER=${FAN_REPO%%/*}
    FAN_META=$(gh api "repos/$FAN_REPO/commits/$FAN_BRANCH" 2>/dev/null || true)
    FAN_SHA=$(printf '%s' "$FAN_META" | jq -r '.sha[0:8] // ""' 2>/dev/null)
    FAN_DATE=$(printf '%s' "$FAN_META" | jq -r '.commit.committer.date[0:10] // ""' 2>/dev/null)
    if [ -n "$FAN_SHA" ]; then
        FAN_VER=$(ver_of "$FAN_REPO" "$FAN_BRANCH")
        CMP3=$(gh api "repos/$PB_REPO/compare/$BASE_SHA...$FAN_OWNER:$FAN_BRANCH" 2>/dev/null || true)
        if [ -n "$CMP3" ]; then
            FAN_AHEAD=$(printf '%s' "$CMP3" | jq -r '.ahead_by // "?"' 2>/dev/null)
            FAN_BEHIND=$(printf '%s' "$CMP3" | jq -r '.behind_by // "?"' 2>/dev/null)
            FAN_COMMITS=$(printf '%s' "$CMP3" | jq -r '.commits[]? | "  " + .sha[0:8] + " " + (.commit.message | split("\n")[0])' 2>/dev/null | tail -10)
        fi
    fi
fi

# ── 上游 tag 之间的差异 ─────────────────────────────────
AHEAD="?"; BEHIND="?"; STATUS="?"
COMMITS=""
if [ -n "$BASE_TAG" ] && [ "$BASE_TAG" != "unknown" ] && [ "$BASE_TAG" != "$LATEST_TAG" ]; then
    CMP=$(gh api "repos/$PB_REPO/compare/$BASE_TAG...$LATEST_TAG" 2>/dev/null || true)
    if [ -n "$CMP" ]; then
        AHEAD=$(printf '%s' "$CMP" | jq -r '.ahead_by // "?"' 2>/dev/null)
        BEHIND=$(printf '%s' "$CMP" | jq -r '.behind_by // "?"' 2>/dev/null)
        STATUS=$(printf '%s' "$CMP" | jq -r '.status // "?"' 2>/dev/null)
        COMMITS=$(printf '%s' "$CMP" | jq -r '.commits[]? | "  " + .sha[0:8] + " " + (.commit.message | split("\n")[0])' 2>/dev/null | head -30)
    fi
fi

# ── 我们的 overlay（基线之后我们自己的提交）────────────
OVERLAY=""
if [ -n "$BASE_SHA" ] && git rev-parse --verify -q "$BASE_SHA" >/dev/null; then
    OVERLAY=$(git log --format='  %h %ad %s' --date=short "$BASE_SHA..$PB_BRANCH" 2>/dev/null)
fi
OVERLAY_N=$(printf '%s\n' "$OVERLAY" | sed '/^$/d' | wc -l | tr -d ' ')

if [ "$SHORT" = 1 ]; then
    printf 'pbodq2 branch=%s base=%s latest=%s tag_ahead=%s def_branch=%s def_ahead=%s fanboy=%s fan_ahead=%s overlay=%s\n' \
        "$BR_SHORT" "$BASE_TAG" "$LATEST_TAG" "$AHEAD" "${DEF_BRANCH:-?}" "${DEF_AHEAD:-?}" "${FAN_SHA:-?}" "${FAN_AHEAD:-?}" "$OVERLAY_N"
    exit 0
fi

cat <<EOF
============================================================
 pbodq2 线：上游 release tag vs 我们的 $PB_BRANCH
============================================================
 上游仓库      $PB_REPO
 我们的分支    $PB_BRANCH ($BR_SHORT)
 基线 tag      $BASE_TAG (${BASE_SHA:0:8})
 上游最新 tag  $LATEST_TAG (${LATEST_SHA:-?})
 基线版本      $BASE_VER
 最新版本      $LATEST_VER
 默认分支      ${DEF_BRANCH:-?} (${DEF_SHA:-?} ${DEF_DATE:-})
 fanboy 上游   $FAN_REPO $FAN_BRANCH (${FAN_SHA:-?} ${FAN_DATE:-})
               ${FAN_VER:-?} ; 相对基线 ahead=${FAN_AHEAD} behind=${FAN_BEHIND}
EOF

if [ "$BASE_TAG" = "$LATEST_TAG" ]; then
cat <<EOF

 基线即上游最新 tag，无需评估新版本。
 默认分支领先最新 tag: ${DEF_AHEAD} 个提交${DEF_VER:+（$DEF_VER）}
 fanboy ${FAN_BRANCH} 领先基线: ${FAN_AHEAD:-?} 个提交${FAN_VER:+（$FAN_VER）}
 我们的 overlay: $OVERLAY_N 个提交
EOF
    if [ -n "${FAN_COMMITS:-}" ] && [ "${FAN_AHEAD:-0}" != "0" ]; then
        echo " fanboy 最近提交:"
        printf '%s\n' "$FAN_COMMITS"
        echo
    fi
    [ -n "$OVERLAY" ] && printf '%s\n' "$OVERLAY"
else
cat <<EOF

 上游 tag 差异: ahead=$AHEAD behind=$BEHIND status=$STATUS
EOF
    if [ "$BASE_VER" != "$LATEST_VER" ]; then
        echo " ⚠ 内核/mt76 版本有变化：$BASE_VER -> $LATEST_VER"
    fi
cat <<EOF

【上游新 tag 的提交】
EOF
    if [ -n "$COMMITS" ]; then
        printf '%s\n' "$COMMITS"
    else
        echo "  （无法获取提交列表）"
    fi
cat <<EOF

【上游默认分支未发版的提交】
${DEF_COMMITS:-  （无）}

【fanboy $FAN_BRANCH 领先基线的提交（最近 10 条）】
${FAN_COMMITS:-  （无 / 无法获取）}

【我们的 overlay（$BASE_TAG 之后）】
EOF
    if [ -n "$OVERLAY" ]; then
        printf '%s\n' "$OVERLAY"
    else
        echo "  （无）"
    fi
cat <<EOF

------------------------------------------------------------
 结论: 上游有更新的 release tag（$LATEST_TAG），需要评估是否迁移；
       迁移步骤见 docs/upstream-pbodq2.md，迁移后更新分支里的 PBODQ2_BASE。
============================================================
EOF
fi
