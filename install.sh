#!/bin/sh

# Compatible with OpenWrt BusyBox ash, dash and bash; Bash is not required.
# Download to a file, then run interactively: sh /path/to/install.sh

APP_NAME="RMS"
SERVICE_NAME="rmservice"
INIT_SCRIPT_NAME="rms"

PATH_RMS="/root/rms"
PATH_EXEC="rms"
PATH_BIN="${PATH_RMS}/${PATH_EXEC}"
PATH_BIN_TMP="${PATH_RMS}/${PATH_EXEC}.tmp"
PATH_BIN_BAK="${PATH_RMS}/${PATH_EXEC}.bak"
PATH_NOHUP="${PATH_RMS}/nohup.out"
PATH_ERR="${PATH_RMS}/err.log"
DEFAULT_WEB_PORT="42703"

PROCESS_WAIT_INTERVAL="0.1"
PROCESS_WAIT_STEPS_PER_SECOND=10
PROCESS_WAIT_INTERVAL_SUPPORTED=""

ROUTE_1="https://github.com"
ROUTE_2="http://static.rustminersystem.com"

ROUTE_EXEC_1="/EvilGenius-dot/RMS/raw/main/x86_64-musl/rms"
ROUTE_EXEC_2="/EvilGenius-dot/RMS/raw/main/armv7-musleabihf/rms"
ROUTE_EXEC_3="/EvilGenius-dot/RMS/raw/main/aarch64-musl/rms"

TARGET_ROUTE=""
TARGET_ROUTE_EXEC=""

UNAME="$(uname -m)"
OS_ID="unknown"
OS_NAME="$(uname -s)"
INIT_SYSTEM="unknown"
IS_OPENWRT=false

RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
BOLD="\033[1m"
RESET="\033[0m"


# -----------------------------------------------------------------------------
# Common helpers
# -----------------------------------------------------------------------------

require_root() {
    if [ "$(id -u)" != "0" ]; then
        echo "请使用 ROOT 用户进行安装，输入 sudo -i 切换。"
        exit 1
    fi
}

is_systemd_available() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

detect_system() {
    local os_like=""

    IS_OPENWRT=false
    OS_ID="unknown"
    OS_NAME="$(uname -s)"

    if [ -r /etc/os-release ]; then
        OS_ID=$(sh -c '. /etc/os-release; printf "%s" "${ID:-unknown}"')
        OS_NAME=$(sh -c '. /etc/os-release; printf "%s" "${PRETTY_NAME:-${ID:-unknown}}"')
        os_like=$(sh -c '. /etc/os-release; printf "%s" "${ID_LIKE:-}"')
    fi

    case " $OS_ID $os_like " in
        *" openwrt "*|*" lede "*|*" istoreos "*) IS_OPENWRT=true ;;
    esac

    if [ -f /etc/openwrt_version ] || [ "$IS_OPENWRT" = true ]; then
        IS_OPENWRT=true
        INIT_SYSTEM="openwrt"
        if [ "$OS_ID" = "unknown" ]; then
            OS_ID="openwrt"
            OS_NAME="OpenWrt"
        fi
        return
    fi

    if is_systemd_available; then
        INIT_SYSTEM="systemd"
    elif [ -f /etc/rc.local ] || [ -d /etc ]; then
        INIT_SYSTEM="rc.local"
    else
        INIT_SYSTEM="direct"
    fi
}

check_dependencies() {
    local missing=""
    local cmd

    for cmd in id uname mkdir chmod touch rm mv cp cat grep sed sleep ps awk tr; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="${missing} ${cmd}"
        fi
    done

    if [ -n "$missing" ]; then
        echo "缺少必要命令:${missing}"
        return 1
    fi

    if [ "$IS_OPENWRT" = true ]; then
        if [ ! -r /etc/rc.common ] || [ ! -r /lib/functions/procd.sh ]; then
            echo "缺少 OpenWrt procd 服务组件：/etc/rc.common 或 /lib/functions/procd.sh。"
            return 1
        fi
    fi

    return 0
}

check_downloader() {
    if command -v wget >/dev/null 2>&1 || command -v curl >/dev/null 2>&1; then
        return 0
    fi

    echo "缺少下载工具：请先安装 wget 或 curl。"
    return 1
}

filter_result() {
    if [ "$1" -eq 0 ]; then
        echo ""
        return 0
    fi

    echo "!!!!!!!!!!!!!!!ERROR!!!!!!!!!!!!!!!!"
    echo "【${2}】失败。"

    if [ -z "$3" ]; then
        echo "!!!!!!!!!!!!!!!ERROR!!!!!!!!!!!!!!!!"
        exit 1
    fi

    echo ""
    return 1
}

ensure_runtime_files() {
    mkdir -p "$PATH_RMS" || return 1
    chmod 755 "$PATH_RMS" || return 1

    [ -f "$PATH_NOHUP" ] || touch "$PATH_NOHUP" || return 1
    [ -f "$PATH_ERR" ] || touch "$PATH_ERR" || return 1
    chmod 640 "$PATH_NOHUP" "$PATH_ERR" 2>/dev/null || true
}

safe_remove_install_dir() {
    if [ -z "$PATH_RMS" ] || [ "$PATH_RMS" = "/" ] || [ "$PATH_RMS" != "/root/rms" ]; then
        echo "检测到不安全的删除路径，已取消：$PATH_RMS"
        return 1
    fi

    rm -rf -- "$PATH_RMS"
}

ensure_line() {
    local file="$1"
    local line="$2"

    touch "$file" 2>/dev/null || return 1
    if grep -Fxq "$line" "$file" 2>/dev/null; then
        return 1
    fi

    echo "$line" >> "$file"
}


# -----------------------------------------------------------------------------
# Download and process helpers
# -----------------------------------------------------------------------------

download_file() {
    local url="$1"
    local output="$2"
    local result

    echo "下载源：$url"
    echo "保存为：$output"

    if command -v wget >/dev/null 2>&1; then
        if wget --help 2>&1 | grep -q -- "--show-progress"; then
            wget --show-progress --progress=bar:force:noscroll "$url" -O "$output"
        else
            wget "$url" -O "$output"
        fi
    else
        curl -fL --progress-bar "$url" -o "$output"
    fi

    result=$?
    if [ "$result" -eq 0 ]; then
        echo "下载完成"
    fi

    return "$result"
}

get_process_pids() {
    local process_name="$1"
    local comm_file
    local comm
    local pid

    # Match the kernel process name, never a substring in the command line.
    # In particular, /root/rms/install.sh must not match the RMS executable.
    if [ -d /proc/1 ]; then
        for comm_file in /proc/[0-9]*/comm; do
            [ -r "$comm_file" ] || continue
            IFS= read -r comm < "$comm_file" || continue
            [ "$comm" = "$process_name" ] || continue
            pid=${comm_file%/comm}
            printf '%s\n' "${pid##*/}"
        done
        return 0
    fi

    if command -v pgrep >/dev/null 2>&1; then
        pgrep -x "$process_name" 2>/dev/null
        return
    fi

    ps -A -o pid= -o comm= 2>/dev/null | awk -v name="$process_name" '
        { sub(/^.*\//, "", $2); if ($2 == name) print $1 }
    '
}

check_process() {
    local pids

    pids="$(get_process_pids "$1")"
    [ -n "$pids" ]
}

is_fast_process_wait_supported() {
    if [ -n "$PROCESS_WAIT_INTERVAL_SUPPORTED" ]; then
        [ "$PROCESS_WAIT_INTERVAL_SUPPORTED" = "1" ]
        return
    fi

    if sleep "$PROCESS_WAIT_INTERVAL" 2>/dev/null; then
        PROCESS_WAIT_INTERVAL_SUPPORTED="1"
        return 0
    fi

    PROCESS_WAIT_INTERVAL_SUPPORTED="0"
    return 1
}

wait_for_process_started() {
    local process_name="$1"
    local timeout="${2:-10}"
    local interval="1"
    local max_attempts="$timeout"
    local attempts=0

    if check_process "$process_name"; then
        return 0
    fi

    if is_fast_process_wait_supported; then
        interval="$PROCESS_WAIT_INTERVAL"
        max_attempts=$((timeout * PROCESS_WAIT_STEPS_PER_SECOND))
    fi

    while [ "$attempts" -lt "$max_attempts" ]; do
        if check_process "$process_name"; then
            return 0
        fi
        sleep "$interval"
        attempts=$((attempts + 1))
    done

    return 1
}

wait_for_process_stopped() {
    local process_name="$1"
    local timeout="${2:-10}"
    local interval="1"
    local max_attempts="$timeout"
    local attempts=0

    if ! check_process "$process_name"; then
        return 0
    fi

    if is_fast_process_wait_supported; then
        interval="$PROCESS_WAIT_INTERVAL"
        max_attempts=$((timeout * PROCESS_WAIT_STEPS_PER_SECOND))
    fi

    while [ "$attempts" -lt "$max_attempts" ]; do
        if ! check_process "$process_name"; then
            return 0
        fi
        sleep "$interval"
        attempts=$((attempts + 1))
    done

    return 1
}

kill_process() {
    local process_name="$1"
    local pids
    local pid

    pids="$(get_process_pids "$process_name")"
    if [ -z "$pids" ]; then
        echo "未发现 $process_name 进程。"
        return 0
    fi

    for pid in $pids; do
        echo "停止进程 $pid ..."
        kill -TERM "$pid" 2>/dev/null || true
    done

    if wait_for_process_stopped "$process_name" 10; then
        echo "$process_name 已停止。"
        return 0
    fi

    echo "进程未在超时时间内退出，尝试强制停止。"
    pids="$(get_process_pids "$process_name")"
    for pid in $pids; do
        kill -9 "$pid" 2>/dev/null || true
    done

    wait_for_process_stopped "$process_name" 5
}


# -----------------------------------------------------------------------------
# Service helpers
# -----------------------------------------------------------------------------

create_systemd_service() {
    ensure_runtime_files || return 1

    cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF || return 1
[Unit]
Description=${APP_NAME}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${PATH_RMS}/
ExecStart=/bin/sh -c 'exec "\$1" >> "\$2" 2>> "\$3"' sh "${PATH_BIN}" "${PATH_NOHUP}" "${PATH_ERR}"
Restart=always
RestartSec=3
LimitNOFILE=65535
TimeoutStopSec=5

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
}

create_openwrt_init() {
    ensure_runtime_files || return 1

    cat > "/etc/init.d/${INIT_SCRIPT_NAME}" <<EOF || return 1
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=99
STOP=10
WORK_DIR="${PATH_RMS}"
PROG="${PATH_BIN}"
NOHUP_LOG="${PATH_NOHUP}"
ERR_LOG="${PATH_ERR}"

start_service() {
    procd_open_instance
    procd_set_param command /bin/sh -c 'cd "\$1" && exec "\$2" >> "\$3" 2>> "\$4"' sh "\$WORK_DIR" "\$PROG" "\$NOHUP_LOG" "\$ERR_LOG"
    procd_set_param limits nofile="65535 65535"
    procd_set_param respawn
    procd_close_instance
}
EOF

    chmod +x "/etc/init.d/${INIT_SCRIPT_NAME}"
}

enable_rc_local_autostart() {
    if [ ! -f /etc/rc.local ]; then
        printf "%s\n\n%s\n" "#!/bin/sh" "exit 0" > /etc/rc.local
    fi

    if ! grep -q "$PATH_BIN" /etc/rc.local 2>/dev/null; then
        sed -i "/^exit 0/i ${PATH_BIN} >> ${PATH_NOHUP} 2>> ${PATH_ERR} &" /etc/rc.local 2>/dev/null || \
            echo "${PATH_BIN} >> ${PATH_NOHUP} 2>> ${PATH_ERR} &" >> /etc/rc.local
    fi

    chmod +x /etc/rc.local
}

disable_rc_local_autostart() {
    sed -i "/${PATH_EXEC}/d" /etc/rc.local 2>/dev/null || true
}

enable_autostart() {
    ensure_runtime_files || return 1

    if [ "$IS_OPENWRT" = true ]; then
        create_openwrt_init || return 1
        /etc/init.d/${INIT_SCRIPT_NAME} enable || return 1
        echo "已设置 OpenWrt 开机启动。"
    elif is_systemd_available; then
        create_systemd_service || return 1
        systemctl enable "${SERVICE_NAME}.service" || return 1
        echo "已设置 systemd 开机启动。"
    else
        enable_rc_local_autostart || return 1
        echo "已写入 /etc/rc.local 开机启动。"
    fi
}

disable_autostart() {
    echo "关闭开机启动..."

    if [ "$IS_OPENWRT" = true ]; then
        if [ -x "/etc/init.d/${INIT_SCRIPT_NAME}" ]; then
            /etc/init.d/${INIT_SCRIPT_NAME} disable 2>/dev/null || true
        fi
    elif is_systemd_available; then
        systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
    else
        disable_rc_local_autostart
    fi
}

remove_service_files() {
    if [ "$IS_OPENWRT" = true ]; then
        if [ -x "/etc/init.d/${INIT_SCRIPT_NAME}" ]; then
            /etc/init.d/${INIT_SCRIPT_NAME} stop 2>/dev/null || true
            /etc/init.d/${INIT_SCRIPT_NAME} disable 2>/dev/null || true
            rm -f -- "/etc/init.d/${INIT_SCRIPT_NAME}"
        fi
    elif is_systemd_available; then
        systemctl disable --now "${SERVICE_NAME}.service" 2>/dev/null || true
        rm -f -- "/etc/systemd/system/${SERVICE_NAME}.service"
        systemctl daemon-reload 2>/dev/null || true
    else
        disable_rc_local_autostart
    fi
}


# -----------------------------------------------------------------------------
# System tuning
# -----------------------------------------------------------------------------

disable_firewall() {
    echo "关闭防火墙"

    if [ "$IS_OPENWRT" = true ]; then
        echo "OpenWrt 环境跳过防火墙自动关闭，请按需自行放行端口 ${DEFAULT_WEB_PORT}。"
    elif [ "$OS_ID" = "ubuntu" ] && command -v ufw >/dev/null 2>&1; then
        ufw disable
    else
        case "$OS_ID" in
        centos|rhel|rocky|almalinux|fedora)
            if is_systemd_available; then
                systemctl stop firewalld 2>/dev/null || true
                systemctl disable firewalld 2>/dev/null || true
            fi
            ;;
        *)
            echo "未知或无需处理的操作系统，跳过防火墙自动关闭。"
            ;;
        esac
    fi
}

change_limit() {
    local changed="n"

    if [ "$IS_OPENWRT" = true ]; then
        echo "OpenWrt：RMS 的文件描述符上限由 procd 在启动服务时设置为 65535。"
        return 0
    fi

    echo "解除系统连接数限制"

    if [ -d /etc/security ]; then
        ensure_line /etc/security/limits.conf "root soft nofile 65535" && changed="y"
        ensure_line /etc/security/limits.conf "root hard nofile 65535" && changed="y"
        ensure_line /etc/security/limits.conf "* soft nofile 65535" && changed="y"
        ensure_line /etc/security/limits.conf "* hard nofile 65535" && changed="y"
    fi

    if [ -d /etc/systemd ]; then
        ensure_line /etc/systemd/user.conf "DefaultLimitNOFILE=65535" && changed="y"
        ensure_line /etc/systemd/system.conf "DefaultLimitNOFILE=65535" && changed="y"
    fi

    if [ -e /etc/sysctl.conf ] || [ "$IS_OPENWRT" != true ]; then
        ensure_line /etc/sysctl.conf "fs.file-max = 100000" && changed="y"
        command -v sysctl >/dev/null 2>&1 && sysctl -p >/dev/null 2>&1 || true
    fi

    if is_systemd_available; then
        systemctl daemon-reexec 2>/dev/null || true
    fi

    if [ "$changed" = "y" ]; then
        echo "连接数限制已检查/更新为 65535，部分配置需要重启服务器后生效。"
    else
        printf '%s' "当前连接数限制："
        ulimit -n
    fi
}


# -----------------------------------------------------------------------------
# RMS lifecycle
# -----------------------------------------------------------------------------

get_ip() {
    local ip_addr=""

    if command -v ip >/dev/null 2>&1; then
        ip_addr=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    fi

    if [ -z "$ip_addr" ] && command -v hostname >/dev/null 2>&1; then
        ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi

    echo "$ip_addr"
}

show_start_success() {
    local ip_addr

    ip_addr="$(get_ip)"
    [ -n "$ip_addr" ] || ip_addr="局域网IP"

    echo "|----------------------------------------------------------------|"
    echo "程序启动成功，访问地址：${ip_addr}:${DEFAULT_WEB_PORT}"
    echo "提示：如果需要公网访问，请同时检查云厂商/路由器防火墙。"
    echo "|----------------------------------------------------------------|"
}

start() {
    printf '%b\n' "${BLUE}启动程序...${RESET}"

    if [ ! -f "$PATH_BIN" ]; then
        echo "未找到 ${PATH_BIN}，请先选择安装。"
        return 1
    fi

    chmod 755 "$PATH_BIN" 2>/dev/null || true

    if check_process "$PATH_EXEC"; then
        echo "程序已经启动，请不要重复启动。"
        return 0
    fi

    ensure_runtime_files || return 1

    if [ "$IS_OPENWRT" = true ]; then
        enable_autostart || {
            echo "创建或启用 OpenWrt 服务失败。"
            return 1
        }
        /etc/init.d/${INIT_SCRIPT_NAME} start || {
            echo "提交 OpenWrt 服务启动请求失败，可运行 logread 查看系统日志。"
            return 1
        }
    elif is_systemd_available; then
        enable_autostart || return 1
        systemctl start "${SERVICE_NAME}.service" || return 1
    else
        enable_autostart || return 1
        nohup "$PATH_BIN" >> "$PATH_NOHUP" 2>> "$PATH_ERR" &
    fi

    if wait_for_process_started "$PATH_EXEC" 10; then
        show_start_success
    else
        echo "程序启动失败!!!"
        echo "可查看错误日志：$PATH_ERR"
        return 1
    fi
}

stop() {
    echo "停止程序..."

    if [ "$IS_OPENWRT" = true ]; then
        [ -x "/etc/init.d/${INIT_SCRIPT_NAME}" ] && /etc/init.d/${INIT_SCRIPT_NAME} stop 2>/dev/null || true
    elif is_systemd_available; then
        systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
    fi

    if check_process "$PATH_EXEC"; then
        kill_process "$PATH_EXEC"
    else
        echo "未发现 $PATH_EXEC 进程。"
    fi
}

restart() {
    stop
    start
}

install_app() {
    local download_url
    local choose

    if [ -z "$TARGET_ROUTE" ] || [ -z "$TARGET_ROUTE_EXEC" ]; then
        echo "下载线路或架构未选择，取消安装。"
        return 1
    fi

    echo "开始安装/更新 ${APP_NAME}"
    echo "当前 CPU 架构：${UNAME}"

    disable_firewall

    if check_process "$PATH_EXEC"; then
        echo "发现正在运行的 ${PATH_EXEC}，需要停止后才能继续安装。"
        echo "输入 1 停止正在运行的 ${PATH_EXEC} 并继续安装，输入 2 取消安装。"
        printf '%s' "请选择[1-2]："
        IFS= read -r choose || return 1
        case "$choose" in
        1)
            stop
            ;;
        2)
            echo "取消安装"
            return 1
            ;;
        *)
            echo "输入错误，取消安装。"
            return 1
            ;;
        esac
    fi

    ensure_runtime_files || return 1
    change_limit
    check_downloader || return 1

    download_url="${TARGET_ROUTE}${TARGET_ROUTE_EXEC}"
    echo "开始下载程序..."

    rm -f -- "$PATH_BIN_TMP"
    download_file "$download_url" "$PATH_BIN_TMP"
    filter_result $? "下载程序"

    chmod 755 "$PATH_BIN_TMP"

    if [ -f "$PATH_BIN" ]; then
        cp -f "$PATH_BIN" "$PATH_BIN_BAK" 2>/dev/null || true
        echo "检测到已有安装，已保留旧程序备份：$PATH_BIN_BAK"
    fi

    if ! mv -f "$PATH_BIN_TMP" "$PATH_BIN"; then
        echo "替换程序失败。"
        [ -f "$PATH_BIN_BAK" ] && cp -f "$PATH_BIN_BAK" "$PATH_BIN"
        return 1
    fi

    start
}

uninstall() {
    local confirm

    printf '%s' "输入 YES 确认卸载："
    IFS= read -r confirm || return 1
    if [ "$confirm" != "YES" ]; then
        echo "已取消卸载。"
        return 1
    fi

    stop
    disable_autostart
    remove_service_files
    safe_remove_install_dir || return 1

    echo "卸载成功"
}


# -----------------------------------------------------------------------------
# Menu and status
# -----------------------------------------------------------------------------

detect_arch_choice() {
    case "$UNAME" in
    x86_64|amd64)
        echo "1"
        ;;
    aarch64|arm64)
        echo "3"
        ;;
    armv7l|armv7*|armhf)
        echo "2"
        ;;
    *)
        echo ""
        ;;
    esac
}

select_arch() {
    local suggested
    local target_exec

    suggested="$(detect_arch_choice)"

    echo "------RMS Linux------"
    echo "当前 CPU 架构【${UNAME}】"
    echo "请选择对应架构安装选项，直接回车使用推荐项。"
    echo "---------------------"
    echo "1. x86-64"
    echo "2. armv7-musleabihf"
    echo "3. aarch64"
    echo ""

    if [ -n "$suggested" ]; then
        printf '%s' "[1-3]（推荐 ${suggested}）："
        IFS= read -r target_exec || return 1
        [ -n "$target_exec" ] || target_exec="$suggested"
    else
        printf '%s' "[1-3]："
        IFS= read -r target_exec || return 1
    fi

    case "$target_exec" in
    1) TARGET_ROUTE_EXEC="$ROUTE_EXEC_1" ;;
    2) TARGET_ROUTE_EXEC="$ROUTE_EXEC_2" ;;
    3) TARGET_ROUTE_EXEC="$ROUTE_EXEC_3" ;;
    *)
        echo "错误的架构选择命令"
        return 1
        ;;
    esac
}

select_route() {
    local target_route

    echo "------RMS Linux------"
    echo "请选择下载线路:"
    echo "1. 线路1（GitHub 官方地址，如无法下载请选择其他线路）"
    echo "2. 线路2"
    echo "---------------------"

    printf '%s' "[1-2]（默认 1）："
    IFS= read -r target_route || return 1
    [ -n "$target_route" ] || target_route="1"

    case "$target_route" in
    1) TARGET_ROUTE="$ROUTE_1" ;;
    2) TARGET_ROUTE="$ROUTE_2" ;;
    *)
        echo "错误的线路选择命令"
        return 1
        ;;
    esac
}

get_service_status_text() {
    if [ "$IS_OPENWRT" = true ]; then
        if [ -x "/etc/init.d/${INIT_SCRIPT_NAME}" ]; then
            echo "OpenWrt init 已安装"
        else
            echo "OpenWrt init 未安装"
        fi
    elif is_systemd_available; then
        systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || echo "inactive"
    else
        if grep -q "$PATH_BIN" /etc/rc.local 2>/dev/null; then
            echo "rc.local 已配置"
        else
            echo "未配置"
        fi
    fi
}

show_status() {
    local pids
    local service_status

    pids="$(get_process_pids "$PATH_EXEC" | tr '\n' ' ')"
    service_status="$(get_service_status_text)"

    echo "------RMS 运行状态------"
    echo "系统：${OS_NAME}"
    echo "初始化系统：${INIT_SYSTEM}"
    echo "安装目录：${PATH_RMS}"
    echo "程序文件：$([ -f "$PATH_BIN" ] && echo "存在" || echo "不存在")"
    echo "服务状态：${service_status}"
    echo "进程状态：$([ -n "$pids" ] && echo "运行中 (${pids})" || echo "未运行")"
    echo "运行日志：${PATH_NOHUP}"
    echo "错误日志：${PATH_ERR}"
    echo "WEB 端口：${DEFAULT_WEB_PORT}"
    echo "------------------------"
}

tail_log() {
    local file="$1"

    ensure_runtime_files

    if ! command -v tail >/dev/null 2>&1; then
        echo "当前系统缺少 tail 命令。"
        return 1
    fi

    echo "按 CTRL+C 停止查看日志"
    tail -f "$file"
}

show_main_menu() {
    local running_text

    if check_process "$PATH_EXEC"; then
        running_text="${GREEN}运行中${RESET}"
    else
        running_text="${YELLOW}未运行${RESET}"
    fi

    printf '%b\n' "${BOLD}${BLUE}------RMS Linux------${RESET}"
    printf '%b\n' "状态：${running_text}"
    echo "1. 安装/更新"
    echo "2. 停止运行 RMS"
    echo "3. 重启 RMS"
    echo "4. 卸载 RMS"
    echo "5. 启动 RMS"
    echo "6. 查看运行状态"
    echo "7. 查看运行日志"
    echo "8. 查看错误日志"
    echo "9. 设置开机启动"
    echo "10. 关闭开机启动"
    echo "---------------------"
}

dispatch_menu_choice() {
    local comm="$1"

    case "$comm" in
    1)
        select_arch || return 1
        clear 2>/dev/null || true
        select_route || return 1
        clear 2>/dev/null || true
        install_app
        ;;
    2)
        stop
        ;;
    3)
        restart
        ;;
    4)
        uninstall
        ;;
    5)
        start
        ;;
    6)
        show_status
        ;;
    7)
        tail_log "$PATH_NOHUP"
        ;;
    8)
        tail_log "$PATH_ERR"
        ;;
    9)
        enable_autostart
        ;;
    10)
        disable_autostart
        ;;
    *)
        echo "错误的菜单选择。"
        return 1
        ;;
    esac
}

main() {
    local comm

    clear 2>/dev/null || true
    require_root
    detect_system
    check_dependencies || exit 1

    show_main_menu
    printf '%s' "[1-10]："
    IFS= read -r comm || return 1
    dispatch_menu_choice "$comm"
}

main "$@"
