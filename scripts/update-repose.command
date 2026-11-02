#!/bin/bash
# Standalone macOS updater; uses only tools shipped with macOS.
set -euo pipefail
umask 077

repo="codievilky/repose"
bundle_id="com.repose.localring"
app_name="Repose Ring.app"
local_package=""
local_checksum=""
install_parent=""
check_only=0
no_launch=0
work_dir=""
stage_dir=""
target=""
rollback_app=""
backup_app=""
new_moved=0
app_stopped=0
was_running=0
committed=0
lock_dir=""
lock_owned=0

fail() { printf '更新未完成：%s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'TEXT'
Repose Ring 一键安装 / 升级
直接运行：从 codievilky/repose 的最新 GitHub Release 下载并校验安装包。

可选参数（供离线使用和测试）：
  --package ZIP --checksum SHA256SUMS.txt
  --check-only          仅验证，不安装、不移除下载隔离、不启动应用
  --install-dir DIR     指定安装目录
  --backup-dir DIR      指定备份目录
  --no-launch           安装后不启动
TEXT
}

backup_root="${HOME}/Library/Application Support/Repose Ring/Backups"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --package|--checksum|--install-dir|--backup-dir)
            [[ $# -ge 2 ]] || fail "参数 $1 缺少值"
            case "$1" in
                --package) local_package="$2" ;;
                --checksum) local_checksum="$2" ;;
                --install-dir) install_parent="$2" ;;
                --backup-dir) backup_root="$2" ;;
            esac
            shift 2 ;;
        --check-only) check_only=1; shift ;;
        --no-launch) no_launch=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "未知参数：$1" ;;
    esac
done

cleanup() {
    local result=$?
    local recovery_ok=1
    trap - EXIT INT TERM HUP
    if [[ "$committed" -eq 0 ]]; then
        # Inspect the rollback path as well as flags: interruption can happen
        # between a successful rename and the next shell assignment.
        if [[ -d "$rollback_app" && -e "$target" ]] || [[ "$new_moved" -eq 1 && -d "$target" ]]; then
            /bin/mv "$target" "$stage_dir/Failed.app" || recovery_ok=0
        fi
        if [[ -d "$rollback_app" && "$recovery_ok" -eq 1 ]]; then
            /bin/mv "$rollback_app" "$target" || recovery_ok=0
            [[ "$recovery_ok" -ne 1 ]] || printf '已恢复原来的 Repose Ring。\n'
        fi
        if [[ "$recovery_ok" -eq 1 && "$app_stopped" -eq 1 && "$was_running" -eq 1 && "$no_launch" -eq 0 && -d "$target" ]]; then
            /usr/bin/open "$target" >/dev/null 2>&1 || true
        fi
    fi
    if [[ -n "$stage_dir" ]]; then
        if [[ "$recovery_ok" -eq 1 ]]; then /bin/rm -rf "$stage_dir"
        else printf '恢复未成功，请保留此目录：%s\n备份：%s\n' "$stage_dir" "$backup_app" >&2
        fi
    fi
    [[ -z "$work_dir" ]] || /bin/rm -rf "$work_dir"
    if [[ "$lock_owned" -eq 1 ]]; then /bin/rm -rf "$lock_dir"; fi
    if [[ "$result" -ne 0 ]]; then printf '原有偏好设置未修改。\n' >&2; fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

[[ "$(/usr/bin/uname -s)" == Darwin ]] || fail "此脚本仅适用于 macOS"
[[ "$(/usr/bin/uname -m)" == arm64 ]] || fail "当前预编译安装包仅支持 M 系列 Mac"
os_version="$(/usr/bin/sw_vers -productVersion)"
[[ "${os_version%%.*}" -ge 13 ]] || fail "需要 macOS 13 或更高版本"
work_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp/}repose-ring-update.XXXXXX")"

download() {
    /usr/bin/curl --fail --location --silent --show-error \
        --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 120 --retry 2 --retry-delay 1 \
        --user-agent 'Repose-Ring-Updater' "$1" --output "$2"
}

asset_url() {
    local wanted="$1" index=0 name url
    while name="$(/usr/bin/plutil -extract "assets.$index.name" raw -o - "$work_dir/release.json" 2>/dev/null)"; do
        if [[ "$name" == "$wanted" ]]; then
            url="$(/usr/bin/plutil -extract "assets.$index.browser_download_url" raw -o - "$work_dir/release.json")"
            [[ "$url" == "https://github.com/$repo/releases/download/$release_tag/$wanted" ]] || return 1
            printf '%s\n' "$url"
            return 0
        fi
        index=$((index + 1))
    done
    return 1
}

if [[ -n "$local_package" || -n "$local_checksum" ]]; then
    [[ -f "$local_package" && -f "$local_checksum" ]] || fail "离线安装需要同时提供安装包和校验文件"
    package_name="$(/usr/bin/basename "$local_package")"
    [[ "$package_name" =~ ^Repose-Ring-([0-9]+\.[0-9]+\.[0-9]+-ring\.[0-9]+)-AppleSilicon\.zip$ ]] || fail "安装包文件名不符合本项目格式"
    version="${BASH_REMATCH[1]}"
    /bin/cp "$local_package" "$work_dir/$package_name"
    /bin/cp "$local_checksum" "$work_dir/SHA256SUMS.txt"
else
    printf '1/4 获取 %s 最新版本…\n' "$repo"
    download "https://api.github.com/repos/$repo/releases/latest" "$work_dir/release.json" || fail "无法获取 GitHub Release"
    release_tag="$(/usr/bin/plutil -extract tag_name raw -o - "$work_dir/release.json")"
    [[ "$release_tag" =~ ^v([0-9]+\.[0-9]+\.[0-9]+-ring\.[0-9]+)$ ]] || fail "Release 标签格式异常"
    version="${BASH_REMATCH[1]}"
    package_name="Repose-Ring-$version-AppleSilicon.zip"
    package_url="$(asset_url "$package_name")" || fail "最新 Release 中没有匹配的 Apple Silicon 安装包"
    checksum_url="$(asset_url SHA256SUMS.txt)" || fail "最新 Release 缺少校验文件"
    download "$package_url" "$work_dir/$package_name" || fail "安装包下载失败"
    download "$checksum_url" "$work_dir/SHA256SUMS.txt" || fail "校验文件下载失败"
fi

printf '2/4 校验 %s 的完整性、签名与应用身份…\n' "$version"
# Do not execute filenames or arbitrary commands from the checksum manifest.
expected="$(/usr/bin/awk -v wanted="$package_name" '
    NF == 2 { name=$2; sub(/^\*/, "", name); if (name == wanted) { count++; hash=$1 } }
    END { if (count == 1) print hash; else exit 1 }
' "$work_dir/SHA256SUMS.txt")" || fail "校验文件缺少唯一匹配条目"
[[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] || fail "SHA-256 格式错误"
actual="$(/usr/bin/shasum -a 256 "$work_dir/$package_name" | /usr/bin/awk '{print $1}')"
[[ "$(printf '%s' "$expected" | /usr/bin/tr 'A-F' 'a-f')" == "$actual" ]] || fail "SHA-256 不匹配；应用未被替换"

/usr/bin/unzip -Z -1 "$work_dir/$package_name" > "$work_dir/members.txt" || fail "无法读取压缩包"
/usr/bin/awk '
    /^\// || /(^|\/)\.\.(\/|$)/ { exit 1 }
    $0 != "Repose Ring.app" && index($0, "Repose Ring.app/") != 1 { exit 1 }
' "$work_dir/members.txt" || fail "压缩包包含非预期路径"
/usr/bin/ditto -x -k "$work_dir/$package_name" "$work_dir/unpacked" || fail "解压失败"
candidate="$work_dir/unpacked/$app_name"
[[ -d "$candidate" && ! -L "$candidate" ]] || fail "没有找到有效的 Repose Ring.app"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$candidate/Contents/Info.plist")" == "$bundle_id" ]] || fail "应用标识不匹配"
[[ "$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$candidate/Contents/Info.plist")" == Repose ]] || fail "可执行文件标识不匹配"
[[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$candidate/Contents/Info.plist")" == "$version" ]] || fail "版本与安装包名称不一致"
new_build="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$candidate/Contents/Info.plist")"
[[ "$new_build" =~ ^[0-9]+$ ]] || fail "构建版本号格式错误"
/usr/bin/lipo -verify_arch arm64 "$candidate/Contents/MacOS/Repose" || fail "安装包不支持当前架构"
/usr/bin/codesign --verify --deep --strict "$candidate" || fail "代码签名校验失败"
if [[ "$check_only" -eq 1 ]]; then printf '验证通过；未安装、未改变下载隔离或安全设置。\n'; exit 0; fi

if [[ -z "$install_parent" ]]; then
    if [[ -e "/Applications/$app_name" || -w /Applications ]]; then install_parent=/Applications
    else install_parent="${HOME}/Applications"
    fi
fi
/bin/mkdir -p "$install_parent"
install_parent="$(cd "$install_parent" && pwd -P)"
target="$install_parent/$app_name"
[[ -w "$install_parent" ]] || fail "无法写入 $install_parent；请使用有安装权限的账号"
lock_dir="$install_parent/.Repose-Ring-update.lock"
/bin/mkdir "$lock_dir" 2>/dev/null || fail "已有更新任务或遗留的更新锁：$lock_dir"
lock_owned=1
printf '%s\n' "$$" > "$lock_dir/pid"
[[ ! -L "$target" ]] || fail "目标应用是符号链接；未替换"
if [[ -e "$target" ]]; then
    [[ -d "$target" && "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$target/Contents/Info.plist")" == "$bundle_id" ]] || fail "目标位置不是本项目应用；未替换"
    old_build="$(/usr/bin/plutil -extract CFBundleVersion raw -o - "$target/Contents/Info.plist")"
    [[ "$old_build" =~ ^[0-9]+$ ]] || fail "现有应用构建号异常；未替换"
    [[ "$old_build" -le "$new_build" ]] || fail "本机版本比此安装包更新；未降级"
fi

printf '3/4 暂存并只处理 Repose Ring 的下载隔离标记…\n'
stage_dir="$(/usr/bin/mktemp -d "$install_parent/.Repose-Ring-update.XXXXXX")"
staged="$stage_dir/$app_name"
rollback_app="$stage_dir/Previous.app"
/usr/bin/ditto "$candidate" "$staged"
/usr/bin/codesign --verify --deep --strict "$staged" || fail "暂存副本签名校验失败"
# No global Gatekeeper changes and no blanket removal of other attributes.
/usr/bin/xattr -dr com.apple.quarantine "$staged" 2>/dev/null || true
/usr/bin/xattr -lr "$staged" > "$work_dir/attributes.txt" || fail "无法检查下载隔离标记"
if /usr/bin/grep -q ': com\.apple\.quarantine:' "$work_dir/attributes.txt"; then fail "未能清除本应用的下载隔离标记"; fi
/usr/bin/codesign --verify --deep --strict "$staged" || fail "签名复核失败"

process_ids() {
    local snapshot
    snapshot="$(/bin/ps -axo pid=,comm=)" || return 1
    printf '%s\n' "$snapshot" | /usr/bin/awk -v wanted="$target/Contents/MacOS/Repose" '
        { pid=$1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); if ($0 == wanted) print pid }
    '
}

if [[ -d "$target" ]]; then
    /bin/mkdir -p "$backup_root"
    backup_dir="$(/usr/bin/mktemp -d "$backup_root/$(/bin/date +%Y%m%d-%H%M%S)-build$old_build.XXXXXX")"
    backup_app="$backup_dir/$app_name"
    /usr/bin/ditto "$target" "$backup_app" || fail "无法备份现有版本"
fi
running_ids="$(process_ids)" || fail "无法检查现有应用进程"
if [[ -n "$running_ids" ]]; then
    was_running=1
    app_stopped=1
    for pid in $running_ids; do kill -TERM "$pid" 2>/dev/null || true; done
    for attempt in {1..50}; do
        alive=0
        for pid in $running_ids; do if kill -0 "$pid" 2>/dev/null; then alive=1; fi; done
        [[ "$alive" -eq 1 ]] || break
        /bin/sleep 0.1
    done
    [[ "$alive" -eq 0 ]] || fail "应用未退出；已取消替换"
fi

printf '4/4 安装并启动…\n'
if [[ -d "$target" ]]; then /bin/mv "$target" "$rollback_app"; fi
/bin/mv "$staged" "$target"
new_moved=1
/usr/bin/codesign --verify --deep --strict "$target" || fail "安装后签名复核失败"
if [[ "$no_launch" -eq 0 ]]; then
    /usr/bin/open -n "$target" || fail "无法启动新版本"
    started=0
    for attempt in {1..50}; do
        if [[ -n "$(process_ids)" ]]; then started=1; break; fi
        /bin/sleep 0.1
    done
    [[ "$started" -eq 1 ]] || fail "新版本未正常运行"
fi
committed=1
printf '\n已安装 Repose Ring %s：%s\n现有偏好设置保留。\n' "$version" "$target"
[[ -z "$backup_app" ]] || printf '旧版备份：%s\n' "$backup_app"
