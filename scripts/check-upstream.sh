#!/usr/bin/env bash
#
# check-upstream.sh — 对比「最新 Release」与上游 naoki66，判断有没有值得为它构建的东西
#
# 用法:
#   scripts/check-upstream.sh              # 默认：对比最新 Release 与 naoki66/master
#   scripts/check-upstream.sh --no-fetch   # 不联网（用本地已有引用）
#   scripts/check-upstream.sh --short      # 只输出一行结论（适合 cron/通知）
#   scripts/check-upstream.sh --tag 20261104-acbd046c   # 指定对比基线
#
# 输出三部分:
#   1. 上游在 Release 之后新增了什么（按 内核/包/配置/CI/文档 分类）
#   2. 本分支相对 Release 的功能性差异（也就是“下次构建会带上什么”）
#   3. 结论：是否需要构建
#
# 只做只读操作：fetch / log / show，不合并、不推送、不触发构建。
#
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1

REPO_DEFAULT="kaiwater/ImmortalWrt-for-Gemtek-brightspeed"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-naoki66}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-master}"
LOCAL_BRANCH="${LOCAL_BRANCH:-naoki66-base}"
REPO="${REPO:-$REPO_DEFAULT}"

DO_FETCH=1
SHORT=0
RELEASE_TAG=""

while [ $# -gt 0 ]; do
    case "$1" in
        --no-fetch) DO_FETCH=0 ;;
        --short)    SHORT=1 ;;
        --tag)      shift; RELEASE_TAG="${1:-}" ;;
        -h|--help)  sed -n '3,20p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo: $ROOT" >&2; exit 1; }

# ── 准备引用 ─────────────────────────────────────────────
if [ "$DO_FETCH" = 1 ]; then
    if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
        git remote add "$UPSTREAM_REMOTE" https://github.com/naoki66/ImmortalWrt-for-Gemtek-brightspeed.git
    fi
    git fetch -q "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH" 2>/dev/null || true
    git fetch -q --tags origin 2>/dev/null || true
fi

UPSTREAM_REF="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
if ! git rev-parse --verify -q "$UPSTREAM_REF" >/dev/null; then
    echo "找不到上游引用 $UPSTREAM_REF（先去掉 --no-fetch 试一次）" >&2
    exit 1
fi
git rev-parse --verify -q "$LOCAL_BRANCH" >/dev/null || LOCAL_BRANCH="origin/$LOCAL_BRANCH"

# ── 找最新 Release 对应的提交 ────────────────────────────
if [ -z "$RELEASE_TAG" ]; then
    if command -v gh >/dev/null 2>&1; then
        RELEASE_TAG=$(gh release view --repo "$REPO" --json tagName --jq '.tagName' 2>/dev/null || true)
    fi
fi
if [ -z "$RELEASE_TAG" ]; then
    RELEASE_TAG=$(git describe --tags --abbrev=0 --match '20*' 2>/dev/null || true)
fi
if [ -z "$RELEASE_TAG" ]; then
    echo "找不到 Release tag，可用 --tag 指定" >&2
    exit 1
fi
REL_SHA=$(git rev-parse --verify -q "$RELEASE_TAG^{commit}" || true)
[ -n "$REL_SHA" ] || { echo "tag $RELEASE_TAG 解析失败" >&2; exit 1; }

LOCAL_SHA=$(git rev-parse "$LOCAL_BRANCH")
UP_SHA=$(git rev-parse "$UPSTREAM_REF")

# ── 分类 ────────────────────────────────────────────────
classify() {
    local sha="$1" files
    files=$(git show --name-only --pretty=format: "$sha" 2>/dev/null | sed '/^$/d')
    if printf '%s\n' "$files" | grep -q '^target/linux/'; then echo "kernel"; return; fi
    if printf '%s\n' "$files" | grep -q '^package/';      then echo "packages"; return; fi
    if printf '%s\n' "$files" | grep -q '^custom/';       then echo "custom"; return; fi
    if printf '%s\n' "$files" | grep -q '^\.github/';     then echo "ci"; return; fi
    if printf '%s\n' "$files" | grep -qE '^(docs/|changelog/|README\.md|CHANGELOG\.md)'; then echo "docs"; return; fi
    echo "other"
}


relevant_files() {  # $1=sha $2=kind
    local sha="$1" kind="$2" files
    files=$(git show --name-only --pretty=format: "$sha" 2>/dev/null | sed '/^$/d')
    case "$kind" in
        kernel)   printf '%s\n' "$files" | grep '^target/linux/' ;;
        packages) printf '%s\n' "$files" | grep '^package/' ;;
        custom)   printf '%s\n' "$files" | grep '^custom/' ;;
        ci)       printf '%s\n' "$files" | grep '^\.github/' ;;
        docs)     printf '%s\n' "$files" | grep -E '^(docs/|changelog/|.*\.md)' ;;
        *)        printf '%s\n' "$files" ;;
    esac | head -3 | tr '\n' ' '
}

list_commits() {  # $1=range
    git log --format='%H|%h|%ad|%s' --date=short "$1" 2>/dev/null
}

# ── 统计 ────────────────────────────────────────────────
NEW_COUNT=$(git rev-list --count "$REL_SHA..$UPSTREAM_REF" 2>/dev/null || echo 0)
MISSING=$(git rev-list --count "$LOCAL_BRANCH..$UPSTREAM_REF" 2>/dev/null || echo 0)
BEHIND_REL=$(git rev-list --count "$REL_SHA..$LOCAL_BRANCH" 2>/dev/null || echo 0)

# 上游新增按类别
n_kernel=0; n_packages=0; n_custom=0; n_ci=0; n_docs=0; n_other=0
UP_DETAIL=""
while IFS='|' read -r sha short date subj; do
    [ -n "${sha:-}" ] || continue
    kind=$(classify "$sha")
    case "$kind" in
        kernel)   n_kernel=$((n_kernel+1));   label="内核/DTS" ;;
        packages) n_packages=$((n_packages+1)); label="软件包" ;;
        custom)   n_custom=$((n_custom+1));   label="定制配置" ;;
        ci)       n_ci=$((n_ci+1));           label="CI" ;;
        docs)     n_docs=$((n_docs+1));       label="文档" ;;
        *)        n_other=$((n_other+1));     label="其它" ;;
    esac
    UP_DETAIL="${UP_DETAIL}[${label}] ${short} ${date} ${subj}
        $(relevant_files "$sha" "$kind")
"
done < <(list_commits "$REL_SHA..$UPSTREAM_REF")

# 分支相对 Release 的功能性差异
BR_DETAIL=""
b_kernel=0; b_packages=0; b_custom=0; b_ci=0; b_docs=0; b_other=0
while IFS='|' read -r sha short date subj; do
    [ -n "${sha:-}" ] || continue
    kind=$(classify "$sha")
    case "$kind" in
        kernel)   b_kernel=$((b_kernel+1));   label="内核/DTS" ;;
        packages) b_packages=$((b_packages+1)); label="软件包" ;;
        custom)   b_custom=$((b_custom+1));   label="定制配置" ;;
        ci)       b_ci=$((b_ci+1));           label="CI" ;;
        docs)     b_docs=$((b_docs+1));       label="文档" ;;
        *)        b_other=$((b_other+1));     label="其它" ;;
    esac
    # 只有功能性类别才展开细节
    case "$kind" in
        kernel|packages|custom)
            BR_DETAIL="${BR_DETAIL}[${label}] ${short} ${date} ${subj}
        $(relevant_files "$sha" "$kind")
"
            ;;
    esac
done < <(list_commits "$REL_SHA..$LOCAL_BRANCH")

# ── 结论 ────────────────────────────────────────────────
FUNC_NEW=$((n_kernel + n_packages + n_custom))
FUNC_BRANCH=$((b_kernel + b_packages + b_custom))

if [ "$SHORT" = 1 ]; then
    printf 'release=%s upstream_new=%s(功能 %s) branch_ahead=%s(功能 %s) missing=%s\n' \
        "$RELEASE_TAG" "$NEW_COUNT" "$FUNC_NEW" "$BEHIND_REL" "$FUNC_BRANCH" "$MISSING"
    exit 0
fi

case "$FUNC_NEW" in
    0) VERDICT="上游无功能性新增，无需为上游构建" ;;
    *) VERDICT="上游有 $FUNC_NEW 个功能性改动，建议评估构建" ;;
esac

cat <<EOF
============================================================
 上游 vs 最新 Release
============================================================
 仓库          $REPO
 本地分支      $LOCAL_BRANCH ($(git rev-parse --short "$LOCAL_SHA"))
 最新 Release  $RELEASE_TAG ($(git rev-parse --short "$REL_SHA"))
 上游          $UPSTREAM_REF ($(git rev-parse --short "$UP_SHA"))

 Release 之后上游新增: $NEW_COUNT 个
   内核/DTS $n_kernel | 软件包 $n_packages | 定制配置 $n_custom | CI $n_ci | 文档 $n_docs | 其它 $n_other
 分支相对 Release:     $BEHIND_REL 个（功能 $FUNC_BRANCH 个）
   内核/DTS $b_kernel | 软件包 $b_packages | 定制配置 $b_custom | CI $b_ci | 文档 $b_docs | 其它 $b_other
 上游还有未合入分支的: $MISSING 个

------------------------------------------------------------
【上游新增】
EOF

if [ "$NEW_COUNT" = 0 ]; then
    echo "  （无）"
else
    printf '%s' "$UP_DETAIL"
fi

cat <<EOF

------------------------------------------------------------
【下次构建会带上（分支相对 Release 的功能性变更）】
EOF

if [ "$FUNC_BRANCH" = 0 ]; then
    echo "  （无功能性变更；重建只会换版本号）"
else
    printf '%s' "$BR_DETAIL"
fi

cat <<EOF

------------------------------------------------------------
 结论: $VERDICT
EOF

if [ "$MISSING" != 0 ]; then
    echo " 注意: 上游还有 $MISSING 个提交未合入 $LOCAL_BRANCH（可先合并再构建）"
elif [ "$FUNC_NEW" != 0 ]; then
    echo " 说明: 上游新增已全部合入本分支，但可能尚未进入最新 Release 镜像"
fi
echo "============================================================"
