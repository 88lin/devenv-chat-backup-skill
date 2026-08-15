#!/bin/bash
# github-accel.sh - GitHub 全局加速方案
# 当直连 GitHub 失败/超时时，自动切换到 tvv.tw 镜像
# 
# 用法: source github-accel.sh
#   然后使用 gclone / gpull / gfetch / gpush 替代 git clone/pull/fetch/push
#   或者直接用 ggit <subcommand> ... 自动加速
#
# 镜像支持: https://tvv.tw/
#   git clone:  git clone https://tvv.tw/https://github.com/user/repo.git
#   raw 文件:   https://tvv.tw/https://raw.githubusercontent.com/...
#   release:    https://tvv.tw/https://github.com/.../releases/download/...

GITHUB_MIRROR="https://tvv.tw"
GITHUB_DIRECT_TIMEOUT=15   # 直连超时秒数（超时后切换镜像）
GITHUB_PUSH_RETRIES=3      # push 重试次数

# 检测 URL 是否为 GitHub URL
_gh_is_github_url() {
    case "$1" in
        *github.com*|*raw.githubusercontent.com*|*gist.githubusercontent.com*|*api.github.com*)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

# 给 GitHub URL 加上镜像前缀
_gh_mirror_url() {
    echo "${GITHUB_MIRROR}/$1"
}

# 从 git remote URL 中提取 GitHub URL（去掉可能已有的 token）
_gh_clean_url() {
    local url="$1"
    # 去掉 https://token@ 前缀中的 token
    url=$(echo "$url" | sed 's|https://[^@]*@github.com|https://github.com|')
    url=$(echo "$url" | sed 's|https://[^@]*@raw.githubusercontent.com|https://raw.githubusercontent.com|')
    echo "$url"
}

# ============================================================
# gclone: git clone with mirror fallback
# 用法: gclone https://github.com/user/repo.git [target-dir]
# ============================================================
gclone() {
    local url=""
    local rest=()
    local found_url=0

    # 解析参数，找到 GitHub URL
    for arg in "$@"; do
        if [ $found_url -eq 0 ] && _gh_is_github_url "$arg"; then
            url="$arg"
            found_url=1
        else
            rest+=("$arg")
        fi
    done

    if [ -z "$url" ]; then
        git clone "$@"
        return $?
    fi

    # 尝试直连（短超时）
    printf "🔄 直连 GitHub (最多 %ss)...\n" "$GITHUB_DIRECT_TIMEOUT"
    timeout "$GITHUB_DIRECT_TIMEOUT" git clone "$url" "${rest[@]}" 2>&1
    local rc=$?
    if [ $rc -eq 0 ]; then
        return 0
    fi

    # 直连失败，切换镜像
    printf "⚠️  直连失败(rc=%s)，切换镜像 %s...\n" "$rc" "$GITHUB_MIRROR"
    local murl; murl=$(_gh_mirror_url "$url")
    git clone "$murl" "${rest[@]}" 2>&1
    local rc2=$?
    if [ $rc2 -eq 0 ]; then
        printf "✅ 镜像克隆成功\n"
        # 修复 remote URL：把镜像 URL 改回原始 GitHub URL（后续 push 不走镜像）
        local target=""
        if [ ${#rest[@]} -gt 0 ]; then
            target="${rest[0]}"
        else
            # 无 target dir 时，git 自动从 URL 推导目录名
            target=$(basename "$url" .git)
        fi
        [ -d "$target/.git" ] && git -C "$target" remote set-url origin "$url" 2>/dev/null
    else
        printf "❌ 镜像也失败(rc=%s)\n" "$rc2"
    fi
    return $rc2
}

# ============================================================
# gpull: git pull with mirror fallback
# 用法: gpull [remote] [branch]  (在 git 仓库目录内执行)
# ============================================================
gpull() {
    local remote="${1:-origin}"
    local branch="${2:-}"

    # 尝试直连
    timeout "$GITHUB_DIRECT_TIMEOUT" git pull "$@" 2>&1
    local rc=$?
    if [ $rc -eq 0 ]; then
        return 0
    fi

    # 直连失败，用镜像
    printf "⚠️  git pull 直连失败(rc=%s)，尝试镜像...\n" "$rc"
    local orig_url; orig_url=$(git remote get-url "$remote" 2>/dev/null)
    if [ -z "$orig_url" ]; then
        printf "❌ 找不到 remote '%s'\n" "$remote"
        return 1
    fi

    if _gh_is_github_url "$orig_url"; then
        local murl; murl=$(_gh_mirror_url "$(_gh_clean_url "$orig_url")")
        git remote set-url "$remote" "$murl" 2>/dev/null
        git pull "$@" 2>&1
        rc=$?
        # 恢复原始 URL
        git remote set-url "$remote" "$orig_url" 2>/dev/null
        if [ $rc -eq 0 ]; then
            printf "✅ 镜像 pull 成功\n"
        fi
        return $rc
    fi
    return $rc
}

# ============================================================
# gfetch: git fetch with mirror fallback
# 用法: gfetch [remote] [branch]
# ============================================================
gfetch() {
    local remote="${1:-origin}"

    timeout "$GITHUB_DIRECT_TIMEOUT" git fetch "$@" 2>&1
    local rc=$?
    if [ $rc -eq 0 ]; then
        return 0
    fi

    printf "⚠️  git fetch 直连失败(rc=%s)，尝试镜像...\n" "$rc"
    local orig_url; orig_url=$(git remote get-url "$remote" 2>/dev/null)
    if [ -z "$orig_url" ]; then
        return 1
    fi

    if _gh_is_github_url "$orig_url"; then
        local murl; murl=$(_gh_mirror_url "$(_gh_clean_url "$orig_url")")
        git remote set-url "$remote" "$murl" 2>/dev/null
        git fetch "$@" 2>&1
        rc=$?
        git remote set-url "$remote" "$orig_url" 2>/dev/null
        return $rc
    fi
    return $rc
}

# ============================================================
# gpush: git push with retry (镜像不支持 push，只能重试直连)
# 用法: gpush [remote] [branch]
# ============================================================
gpush() {
    local attempt=1
    while [ $attempt -le $GITHUB_PUSH_RETRIES ]; do
        printf "🔄 git push 尝试 %d/%d...\n" "$attempt" "$GITHUB_PUSH_RETRIES"
        timeout 60 git push "$@" 2>&1
        local rc=$?
        if [ $rc -eq 0 ]; then
            return 0
        fi
        printf "⚠️  push 失败(rc=%s)\n" "$rc"
        attempt=$((attempt + 1))
        [ $attempt -le $GITHUB_PUSH_RETRIES ] && sleep 3
    done
    printf "❌ push %d 次均失败\n" "$GITHUB_PUSH_RETRIES"
    return 1
}

# ============================================================
# graw: 下载 raw.githubusercontent.com 文件（带镜像回退）
# 用法: graw https://raw.githubusercontent.com/user/repo/branch/file.sh -o local.sh
#       graw https://raw.githubusercontent.com/user/repo/branch/file.sh  (输出到 stdout)
# ============================================================
graw() {
    local url="$1"
    local output=""
    shift

    while [ $# -gt 0 ]; do
        case "$1" in
            -o|--output) shift; output="$1" ;;
        esac
        shift
    done

    if [ -n "$output" ]; then
        timeout "$GITHUB_DIRECT_TIMEOUT" curl -fsSL "$url" -o "$output" 2>/dev/null
        if [ $? -eq 0 ] && [ -s "$output" ]; then
            return 0
        fi
        printf "⚠️  直连失败，切换镜像...\n" >&2
        local murl; murl=$(_gh_mirror_url "$url")
        curl -fsSL "$murl" -o "$output" 2>/dev/null
        return $?
    else
        timeout "$GITHUB_DIRECT_TIMEOUT" curl -fsSL "$url" 2>/dev/null
        if [ $? -eq 0 ]; then
            return 0
        fi
        local murl; murl=$(_gh_mirror_url "$url")
        curl -fsSL "$murl" 2>/dev/null
        return $?
    fi
}

# ============================================================
# ggit: 通用 git 命令加速器
# 用法: ggit clone ...  → 自动用 gclone
#       ggit pull ...   → 自动用 gpull
#       ggit push ...   → 自动用 gpush
#       ggit fetch ...  → 自动用 gfetch
#       ggit other ...  → 直接执行 git other ...
# ============================================================
ggit() {
    local subcmd="$1"
    shift
    case "$subcmd" in
        clone)  gclone "$@" ;;
        pull)   gpull "$@" ;;
        push)   gpush "$@" ;;
        fetch)  gfetch "$@" ;;
        *)      git "$subcmd" "$@" ;;
    esac
}
