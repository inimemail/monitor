#!/usr/bin/env bash

# Telegram domain/IP monitor manager.
# Supports multiple targets, multiple bots, and multiple notification receivers.

set -o pipefail

APP_NAME="TG 域名/IP 巡检通知管理器"
CONFIG_DIR="${TG_MONITOR_HOME:-$HOME/.tg-monitor}"
TARGETS_DB="${CONFIG_DIR}/targets.tsv"
BOTS_DB="${CONFIG_DIR}/bots.tsv"
NOTIFIERS_DB="${CONFIG_DIR}/notifiers.tsv"
SETTINGS_FILE="${CONFIG_DIR}/settings.conf"
LEGACY_CONFIG_FILE="$HOME/.tg_monitor.conf"
CRON_MARK="# tg-monitor-auto"
LOOP_PID_FILE="${CONFIG_DIR}/monitor-loop.pid"
CHECK_TIMEOUT="${CHECK_TIMEOUT:-3}"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
blue() { printf '\033[36m%s\033[0m\n' "$*"; }
muted() { printf '\033[90m%s\033[0m\n' "$*"; }
ok() { green "成功：$*"; }
warn() { yellow "提醒：$*"; }
info() { blue "信息：$*"; }
err() { red "错误：$*"; }

pause_enter() {
    local _
    read -r -p "按回车继续..." _
}

ensure_data() {
    mkdir -p "${CONFIG_DIR}"
    touch "${TARGETS_DB}" "${BOTS_DB}" "${NOTIFIERS_DB}" "${SETTINGS_FILE}"
    chmod 700 "${CONFIG_DIR}" 2>/dev/null || true
    chmod 600 "${TARGETS_DB}" "${BOTS_DB}" "${NOTIFIERS_DB}" "${SETTINGS_FILE}" 2>/dev/null || true
}

now_ts() {
    date '+%Y-%m-%d %H:%M:%S'
}

get_script_path() {
    readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || printf '%s' "$0"
}

shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

have_crontab() {
    command -v crontab >/dev/null 2>&1
}

cron_without_mark() {
    if have_crontab; then
        crontab -l 2>/dev/null | grep -vF "${CRON_MARK}" || true
    fi
}

clean_field() {
    printf '%s' "$1" | tr '\t\r\n' '   ' | sed 's/^ *//; s/ *$//'
}

read_required() {
    local prompt="$1"
    local var_name="$2"
    local value
    while true; do
        read -r -p "${prompt}: " value
        value="$(clean_field "${value}")"
        if [[ -n "${value}" ]]; then
            printf -v "${var_name}" '%s' "${value}"
            return 0
        fi
        warn "这一项不能为空。"
    done
}

read_default() {
    local prompt="$1"
    local default_value="$2"
    local var_name="$3"
    local value
    read -r -p "${prompt} [${default_value}]: " value
    value="$(clean_field "${value}")"
    if [[ -z "${value}" ]]; then
        value="${default_value}"
    fi
    printf -v "${var_name}" '%s' "${value}"
}

confirm() {
    local prompt="$1"
    local answer
    read -r -p "${prompt} [y/N]: " answer
    [[ "${answer}" =~ ^[Yy]$|^[Yy][Ee][Ss]$|^是$|^确认$ ]]
}

next_id() {
    local file="$1"
    local max=0
    local id
    while IFS=$'\t' read -r id _; do
        [[ "${id}" =~ ^[0-9]+$ ]] || continue
        (( id > max )) && max="${id}"
    done < "${file}"
    printf '%s\n' "$((max + 1))"
}

row_count() {
    local file="$1"
    local count=0
    local first
    while IFS=$'\t' read -r first _; do
        [[ -n "${first}" ]] && count=$((count + 1))
    done < "${file}"
    printf '%s\n' "${count}"
}

get_id_by_seq() {
    local file="$1"
    local wanted_seq="$2"
    local seq=1
    local id
    while IFS=$'\t' read -r id _; do
        [[ -n "${id}" ]] || continue
        if [[ "${seq}" -eq "${wanted_seq}" ]]; then
            printf '%s\n' "${id}"
            return 0
        fi
        seq=$((seq + 1))
    done < "${file}"
    return 1
}

is_ipv4() {
    local ip="$1"
    local part
    local -a parts
    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a parts <<< "${ip}"
    for part in "${parts[@]}"; do
        [[ "${part}" =~ ^[0-9]{1,3}$ ]] || return 1
        ((10#${part} <= 255)) || return 1
    done
}

is_ipv6() {
    local ip="$1"
    [[ "${ip}" == *:* ]] || return 1
    [[ "${ip}" =~ ^[0-9A-Fa-f:.]+$ ]]
}

is_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}

is_domain() {
    local domain="$1"
    [[ ${#domain} -le 253 ]] || return 1
    [[ "${domain}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

valid_target() {
    is_ip "$1" || is_domain "$1"
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

method_label() {
    case "$1" in
        tcp|hping3) printf 'TCP %s' "$2" ;;
        *) printf 'Ping' ;;
    esac
}

mode_label() {
    case "$1" in
        ALL) printf '全部 IP 不通才告警' ;;
        *) printf '任一 IP 不通就告警' ;;
    esac
}

status_label() {
    case "$1" in
        yes) printf '启用' ;;
        *) printf '停用' ;;
    esac
}

get_bot_name_by_id() {
    local wanted_id="$1"
    local id name token created
    while IFS=$'\t' read -r id name token created; do
        if [[ "${id}" == "${wanted_id}" ]]; then
            printf '%s\n' "${name}"
            return 0
        fi
    done < "${BOTS_DB}"
    printf '未知机器人(%s)\n' "${wanted_id}"
}

get_bot_token_by_id() {
    local wanted_id="$1"
    local id name token created
    while IFS=$'\t' read -r id name token created; do
        if [[ "${id}" == "${wanted_id}" ]]; then
            printf '%s\n' "${token}"
            return 0
        fi
    done < "${BOTS_DB}"
    return 1
}

get_notifier_name_by_id() {
    local wanted_id="$1"
    local id name bot_id chat_id type enabled created
    while IFS=$'\t' read -r id name bot_id chat_id type enabled created; do
        if [[ "${id}" == "${wanted_id}" ]]; then
            printf '%s\n' "${name}"
            return 0
        fi
    done < "${NOTIFIERS_DB}"
    printf '未知位置(%s)\n' "${wanted_id}"
}

describe_notifier_ids() {
    local ids="$1"
    local result=""
    local id name

    if [[ "${ids}" == "all" ]]; then
        printf '全部启用通知位置'
        return 0
    fi
    if [[ "${ids}" == "none" || -z "${ids}" ]]; then
        printf '不通知'
        return 0
    fi

    IFS=',' read -r -a id_list <<< "${ids}"
    for id in "${id_list[@]}"; do
        id="$(clean_field "${id}")"
        [[ -n "${id}" ]] || continue
        name="$(get_notifier_name_by_id "${id}")"
        if [[ -z "${result}" ]]; then
            result="${name}"
        else
            result="${result}, ${name}"
        fi
    done

    [[ -n "${result}" ]] && printf '%s' "${result}" || printf '不通知'
}

select_bot_id() {
    local var_name="$1"
    local total
    total="$(row_count "${BOTS_DB}")"
    if [[ "${total}" -eq 0 ]]; then
        warn "还没有 Telegram 机器人，请先添加机器人。"
        return 1
    fi

    list_bots
    local seq selected_bot_id
    while true; do
        read_required "请输入机器人序号" seq
        [[ "${seq}" =~ ^[0-9]+$ ]] || { warn "请输入数字序号。"; continue; }
        selected_bot_id="$(get_id_by_seq "${BOTS_DB}" "${seq}")" || { warn "没有这个序号。"; continue; }
        printf -v "${var_name}" '%s' "${selected_bot_id}"
        return 0
    done
}

select_notifier_ids() {
    local var_name="$1"
    local current="${2:-all}"
    local total input part id result=""

    total="$(row_count "${NOTIFIERS_DB}")"
    if [[ "${total}" -eq 0 ]]; then
        warn "还没有通知位置。目标会先保存为“不通知”，添加通知位置后可再修改。"
        printf -v "${var_name}" 'none'
        return 0
    fi

    list_notifiers
    cat <<EOF

通知位置选择：
  all   通知到全部启用的位置
  none  只检测，不发送通知
  序号  指定位置，多选用英文逗号分隔，例如 1,3
EOF

    while true; do
        read_default "通知到哪里" "${current}" input
        input="$(printf '%s' "${input}" | tr 'A-Z' 'a-z' | tr -d ' ')"
        if [[ "${input}" == "all" || "${input}" == "none" ]]; then
            printf -v "${var_name}" '%s' "${input}"
            return 0
        fi

        result=""
        local ok_input="yes"
        IFS=',' read -r -a parts <<< "${input}"
        for part in "${parts[@]}"; do
            [[ "${part}" =~ ^[0-9]+$ ]] || { ok_input="no"; break; }
            id="$(get_id_by_seq "${NOTIFIERS_DB}" "${part}")" || { ok_input="no"; break; }
            if [[ -z "${result}" ]]; then
                result="${id}"
            else
                result="${result},${id}"
            fi
        done

        if [[ "${ok_input}" == "yes" && -n "${result}" ]]; then
            printf -v "${var_name}" '%s' "${result}"
            return 0
        fi
        warn "通知位置输入不正确，请输入 all、none 或序号列表。"
    done
}

migrate_legacy_config() {
    ensure_data
    [[ -s "${TARGETS_DB}" || ! -f "${LEGACY_CONFIG_FILE}" ]] && return 0

    local TG_TOKEN="" TG_CHAT_ID="" TARGET="" METHOD="" PORT="" MODE=""
    # shellcheck disable=SC1090
    source "${LEGACY_CONFIG_FILE}" 2>/dev/null || return 0
    [[ -n "${TG_TOKEN}" && -n "${TG_CHAT_ID}" && -n "${TARGET}" ]] || return 0

    local bot_id notifier_id target_id method port mode created
    bot_id="$(next_id "${BOTS_DB}")"
    notifier_id="$(next_id "${NOTIFIERS_DB}")"
    target_id="$(next_id "${TARGETS_DB}")"
    created="$(now_ts)"
    method="${METHOD:-ping}"
    [[ "${method}" == "ping" ]] || method="tcp"
    port="${PORT:-0}"
    mode="${MODE:-ANY}"

    printf '%s\t%s\t%s\t%s\n' "${bot_id}" "默认机器人" "${TG_TOKEN}" "${created}" >> "${BOTS_DB}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${notifier_id}" "默认通知位置" "${bot_id}" "${TG_CHAT_ID}" "私聊/群/频道" "yes" "${created}" >> "${NOTIFIERS_DB}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${target_id}" "旧配置目标" "${TARGET}" "${method}" "${port}" "${mode}" "${notifier_id}" "yes" "${created}" >> "${TARGETS_DB}"
}

check_deps() {
    local missing=()
    local cmd
    for cmd in curl ping timeout; do
        command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
    done

    if ! command -v dig >/dev/null 2>&1 && ! command -v getent >/dev/null 2>&1 && ! command -v nslookup >/dev/null 2>&1; then
        missing+=("dig/getent/nslookup")
    fi

    if ! command -v hping3 >/dev/null 2>&1; then
        missing+=("hping3")
    fi

    if [[ "${#missing[@]}" -eq 0 ]]; then
        ok "依赖已就绪。"
        return 0
    fi

    warn "缺少依赖：${missing[*]}"
    if [[ "${EUID:-$(id -u)}" -eq 0 && -x /usr/bin/apt-get ]]; then
        info "正在尝试通过 apt 安装依赖。"
        apt-get update -y >/dev/null 2>&1
        apt-get install -y curl dnsutils iputils-ping coreutils hping3 >/dev/null 2>&1 || true
        ok "依赖安装流程已执行。"
    else
        warn "TCP 检测使用 hping3。Debian/Ubuntu 可执行：sudo apt-get install curl dnsutils iputils-ping hping3"
        warn "hping3 SYN 检测通常需要 root 权限运行脚本。"
    fi
}

resolve_target_ips() {
    local target="$1"
    RESOLVED_IPS=()

    if is_ip "${target}"; then
        RESOLVED_IPS=("${target}")
        return 0
    fi

    mapfile -t RESOLVED_IPS < <(
        {
            if command -v dig >/dev/null 2>&1; then
                dig +time=2 +tries=1 +short "${target}" A 2>/dev/null
                dig +time=2 +tries=1 +short "${target}" AAAA 2>/dev/null
            fi
            if command -v getent >/dev/null 2>&1; then
                getent ahosts "${target}" 2>/dev/null | awk '{print $1}'
            fi
            if command -v nslookup >/dev/null 2>&1; then
                nslookup "${target}" 2>/dev/null | awk '
                    /^Non-authoritative/ || /^Name:/ || /^名称:/ || /^非权威/ { answer=1 }
                    answer && /^[[:space:]]*Address(es)?:[[:space:]]*/ {
                        sub(/^[[:space:]]*Address(es)?:[[:space:]]*/, "")
                        print
                    }
                    answer && /^[[:space:]]+[0-9A-Fa-f:.]+$/ { print $1 }
                '
            fi
        } | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9A-Fa-f:.]+$' | awk '!seen[$0]++'
    )

    [[ "${#RESOLVED_IPS[@]}" -gt 0 ]]
}

tcp_check() {
    local host="$1"
    local port="$2"
    local output
    TCP_CHECK_ERROR=""

    if ! command -v hping3 >/dev/null 2>&1; then
        TCP_CHECK_ERROR="缺少 hping3，无法执行 TCP 检测"
        return 2
    fi

    output="$(timeout "${CHECK_TIMEOUT}" hping3 -S -p "${port}" -c 1 "${host}" 2>&1)"
    if printf '%s\n' "${output}" | grep -Eq 'flags=SA|flags=.*SA'; then
        return 0
    fi
    if printf '%s\n' "${output}" | grep -Eqi 'operation not permitted|permission denied|not permitted|must be root|socket'; then
        TCP_CHECK_ERROR="hping3 权限不足，通常需要 root 或 CAP_NET_RAW"
        return 2
    fi
    return 1
}

check_one_target() {
    local name="$1"
    local target="$2"
    local method="$3"
    local port="$4"
    local mode="$5"
    local ip

    CHECK_ERROR=""
    CHECK_ALERT="no"
    CHECK_UP_IPS=()
    CHECK_DOWN_IPS=()
    CHECK_ALL_IPS=()
    TCP_CHECK_ERROR=""

    if ! resolve_target_ips "${target}"; then
        CHECK_ERROR="DNS 解析失败，未获取到可检测 IP"
        CHECK_ALERT="yes"
        return 0
    fi

    CHECK_ALL_IPS=("${RESOLVED_IPS[@]}")
    if [[ "${method}" != "ping" && ! command -v hping3 >/dev/null 2>&1 ]]; then
        CHECK_ERROR="缺少 hping3，无法执行 TCP 检测"
        CHECK_DOWN_IPS=("${CHECK_ALL_IPS[@]}")
        CHECK_ALERT="yes"
        return 0
    fi

    for ip in "${CHECK_ALL_IPS[@]}"; do
        if [[ "${method}" == "ping" ]]; then
            if ping -c 1 -W "${CHECK_TIMEOUT}" "${ip}" >/dev/null 2>&1; then
                CHECK_UP_IPS+=("${ip}")
            else
                CHECK_DOWN_IPS+=("${ip}")
            fi
        else
            if tcp_check "${ip}" "${port}"; then
                CHECK_UP_IPS+=("${ip}")
            else
                CHECK_DOWN_IPS+=("${ip}")
                if [[ -n "${TCP_CHECK_ERROR}" ]]; then
                    CHECK_ERROR="${TCP_CHECK_ERROR}"
                fi
            fi
        fi
    done

    if [[ "${mode}" == "ALL" && "${#CHECK_DOWN_IPS[@]}" -eq "${#CHECK_ALL_IPS[@]}" ]]; then
        CHECK_ALERT="yes"
    elif [[ "${mode}" != "ALL" && "${#CHECK_DOWN_IPS[@]}" -gt 0 ]]; then
        CHECK_ALERT="yes"
    fi
}

join_lines() {
    local value
    if [[ "$#" -eq 0 ]]; then
        printf '无'
        return 0
    fi
    for value in "$@"; do
        printf '%s\n' "${value}"
    done
}

html_escape() {
    local value="$1"
    value="${value//&/&amp;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"
    value="${value//\"/&quot;}"
    printf '%s' "${value}"
}

join_ip_html() {
    local value
    if [[ "$#" -eq 0 ]]; then
        printf '无'
        return 0
    fi
    for value in "$@"; do
        printf '• <code>%s</code>\n' "$(html_escape "${value}")"
    done
}

build_alert_message() {
    local name="$1"
    local target="$2"
    local method="$3"
    local port="$4"
    local mode="$5"
    local method_text status_text down_text up_text all_text target_type

    method_text="$(method_label "${method}" "${port}")"
    if [[ -n "${CHECK_ERROR}" ]]; then
        status_text="${CHECK_ERROR}"
    elif [[ "${#CHECK_DOWN_IPS[@]}" -eq "${#CHECK_ALL_IPS[@]}" ]]; then
        status_text="全部 IP 不通"
    else
        status_text="部分 IP 不通"
    fi

    is_ip "${target}" && target_type="IP" || target_type="域名"
    down_text="$(join_ip_html "${CHECK_DOWN_IPS[@]}")"
    up_text="$(join_ip_html "${CHECK_UP_IPS[@]}")"
    all_text="$(join_ip_html "${CHECK_ALL_IPS[@]}")"

    cat <<EOF
<b>[监控告警]</b> <code>$(html_escape "${name}")</code>

<b>目标</b>：<code>$(html_escape "${target}")</code> (${target_type})
<b>状态</b>：<b>$(html_escape "${status_text}")</b>
<b>检测</b>：$(html_escape "${method_text}")
<b>策略</b>：$(html_escape "$(mode_label "${mode}")")
<b>时间</b>：$(html_escape "$(now_ts)")

<b>离线 IP (${#CHECK_DOWN_IPS[@]})</b>
${down_text}

<b>在线 IP (${#CHECK_UP_IPS[@]})</b>
${up_text}

<b>本次最新解析结果 (${#CHECK_ALL_IPS[@]})</b>
${all_text}
EOF
}

send_telegram() {
    local token="$1"
    local chat_id="$2"
    local text="$3"
    curl -fsS -X POST "https://api.telegram.org/bot${token}/sendMessage" \
        --data-urlencode "chat_id=${chat_id}" \
        --data-urlencode "text=${text}" \
        --data-urlencode "parse_mode=HTML" \
        --data-urlencode "disable_web_page_preview=true" >/dev/null 2>&1
}

send_to_notifier_id() {
    local wanted_id="$1"
    local text="$2"
    local id name bot_id chat_id type enabled created token
    SEND_LAST_STATUS="failed"
    while IFS=$'\t' read -r id name bot_id chat_id type enabled created; do
        [[ "${id}" == "${wanted_id}" ]] || continue
        if [[ "${enabled}" != "yes" ]]; then
            SEND_LAST_STATUS="skipped"
            return 0
        fi
        token="$(get_bot_token_by_id "${bot_id}")" || {
            SEND_LAST_STATUS="failed"
            return 1
        }
        if send_telegram "${token}" "${chat_id}" "${text}"; then
            SEND_LAST_STATUS="sent"
            return 0
        fi
        SEND_LAST_STATUS="failed"
        return 1
    done < "${NOTIFIERS_DB}"
    SEND_LAST_STATUS="failed"
    return 1
}

send_to_target_notifiers() {
    local notifier_ids="$1"
    local text="$2"
    local id name bot_id chat_id type enabled created
    local sent=0 failed=0 skipped=0

    SEND_SENT=0
    SEND_FAILED=0
    SEND_SKIPPED=0
    if [[ "${notifier_ids}" == "none" || -z "${notifier_ids}" ]]; then
        SEND_SKIPPED=1
        return 0
    fi

    if [[ "${notifier_ids}" == "all" ]]; then
        while IFS=$'\t' read -r id name bot_id chat_id type enabled created; do
            [[ -n "${id}" ]] || continue
            send_to_notifier_id "${id}" "${text}" || true
            case "${SEND_LAST_STATUS}" in
                sent) sent=$((sent + 1)) ;;
                skipped) skipped=$((skipped + 1)) ;;
                *) failed=$((failed + 1)) ;;
            esac
        done < "${NOTIFIERS_DB}"
    else
        IFS=',' read -r -a ids <<< "${notifier_ids}"
        for id in "${ids[@]}"; do
            id="$(clean_field "${id}")"
            [[ -n "${id}" ]] || continue
            send_to_notifier_id "${id}" "${text}" || true
            case "${SEND_LAST_STATUS}" in
                sent) sent=$((sent + 1)) ;;
                skipped) skipped=$((skipped + 1)) ;;
                *) failed=$((failed + 1)) ;;
            esac
        done
    fi

    SEND_SENT="${sent}"
    SEND_FAILED="${failed}"
    SEND_SKIPPED="${skipped}"
    [[ "${failed}" -eq 0 && "${sent}" -gt 0 ]]
}

print_send_result() {
    local prefix="$1"
    if [[ "${SEND_SENT:-0}" -gt 0 ]]; then
        ok "${prefix}通知成功 ${SEND_SENT} 个，失败 ${SEND_FAILED:-0} 个，跳过 ${SEND_SKIPPED:-0} 个。"
    elif [[ "${SEND_FAILED:-0}" -gt 0 ]]; then
        err "${prefix}已触发告警，但通知发送失败 ${SEND_FAILED} 个。请检查 Bot Token、Chat ID、群/频道权限或服务器网络。"
    else
        warn "${prefix}已触发告警，但没有启用的通知位置。"
    fi
}

run_checks() {
    local run_mode="${1:-manual}"
    local id name target method port mode notifier_ids enabled created msg method_text
    local total=0 alerts=0 sent_total=0 failed_total=0 skipped_total=0

    ensure_data
    migrate_legacy_config

    if [[ ! -s "${TARGETS_DB}" ]]; then
        [[ "${run_mode}" == "manual" ]] && warn "还没有监控目标。"
        return 1
    fi

    while IFS=$'\t' read -r id name target method port mode notifier_ids enabled created; do
        [[ -n "${id}" && "${enabled}" == "yes" ]] || continue
        total=$((total + 1))
        method_text="$(method_label "${method}" "${port}")"
        [[ "${run_mode}" == "manual" ]] && info "正在检测 [${name}] ${target} (${method_text})"

        check_one_target "${name}" "${target}" "${method}" "${port}" "${mode}"

        if [[ "${CHECK_ALERT}" == "yes" ]]; then
            alerts=$((alerts + 1))
            msg="$(build_alert_message "${name}" "${target}" "${method}" "${port}" "${mode}")"
            send_to_target_notifiers "${notifier_ids}" "${msg}" || true
            sent_total=$((sent_total + ${SEND_SENT:-0}))
            failed_total=$((failed_total + ${SEND_FAILED:-0}))
            skipped_total=$((skipped_total + ${SEND_SKIPPED:-0}))
            if [[ "${run_mode}" == "manual" ]]; then
                print_send_result "[${name}] "
            fi
        elif [[ "${run_mode}" == "manual" ]]; then
            ok "[${name}] 正常：${#CHECK_UP_IPS[@]}/${#CHECK_ALL_IPS[@]} 可达。"
        fi
    done < "${TARGETS_DB}"

    if [[ "${run_mode}" == "manual" ]]; then
        echo
        ok "巡检完成：启用目标 ${total} 个，触发告警 ${alerts} 个，通知成功 ${sent_total} 个，失败 ${failed_total} 个，跳过 ${skipped_total} 个。"
    fi
}

list_targets() {
    ensure_data
    if [[ ! -s "${TARGETS_DB}" ]]; then
        warn "当前没有监控目标。"
        return 0
    fi

    local seq=1 id name target method port mode notifier_ids enabled created notify_text
    printf '\n%-4s %-6s %-16s %-32s %-10s %-18s %-22s %s\n' "序号" "状态" "名称" "域名/IP" "检测" "告警策略" "通知位置" "创建时间"
    printf '%s\n' "------------------------------------------------------------------------------------------------------------------------"
    while IFS=$'\t' read -r id name target method port mode notifier_ids enabled created; do
        [[ -n "${id}" ]] || continue
        notify_text="$(describe_notifier_ids "${notifier_ids}")"
        printf '%-4s %-6s %-16s %-32s %-10s %-18s %-22s %s\n' \
            "${seq}" "$(status_label "${enabled}")" "${name}" "${target}" "$(method_label "${method}" "${port}")" "$(mode_label "${mode}")" "${notify_text}" "${created}"
        seq=$((seq + 1))
    done < "${TARGETS_DB}"
}

add_target() {
    ensure_data
    local name target method_choice method port mode_choice mode notifier_ids id created

    echo
    blue "新增监控目标"
    read_required "目标名称，例如 hk-01 或 api-main" name
    while true; do
        read_required "请输入域名或 IP" target
        target="$(printf '%s' "${target}" | tr 'A-Z' 'a-z')"
        valid_target "${target}" && break
        warn "格式不正确，请输入域名、IPv4 或 IPv6。"
    done

    echo "检测方式："
    echo "  1. Ping"
    echo "  2. TCP 端口"
    while true; do
        read_default "请选择" "1" method_choice
        case "${method_choice}" in
            1) method="ping"; port="0"; break ;;
            2)
                method="tcp"
                while true; do
                    read_required "请输入 TCP 端口，例如 80 或 443" port
                    valid_port "${port}" && break
                    warn "端口必须是 1-65535 的数字。"
                done
                break
                ;;
            *) warn "请输入 1 或 2。" ;;
        esac
    done

    echo "告警策略："
    echo "  1. 任一 IP 不通就告警"
    echo "  2. 全部 IP 不通才告警"
    while true; do
        read_default "请选择" "1" mode_choice
        case "${mode_choice}" in
            1) mode="ANY"; break ;;
            2) mode="ALL"; break ;;
            *) warn "请输入 1 或 2。" ;;
        esac
    done

    select_notifier_ids notifier_ids "all"
    id="$(next_id "${TARGETS_DB}")"
    created="$(now_ts)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${name}" "${target}" "${method}" "${port}" "${mode}" "${notifier_ids}" "yes" "${created}" >> "${TARGETS_DB}"
    ok "监控目标已添加。"
}

bulk_add_targets() {
    ensure_data
    local prefix line item target method_choice method port mode_choice mode notifier_ids
    local id created added=0 skipped=0 index=1 name
    local -a targets=()

    echo
    blue "批量新增监控目标"
    muted "可以一次粘贴多个域名/IP，支持空格、逗号或换行分隔；输入空行结束。"
    while true; do
        read -r -p "> " line
        [[ -z "${line}" ]] && break
        line="$(printf '%s' "${line}" | tr ',，;；' '    ')"
        for item in ${line}; do
            target="$(printf '%s' "${item}" | tr 'A-Z' 'a-z')"
            if valid_target "${target}"; then
                targets+=("${target}")
            else
                warn "已跳过格式不正确的目标：${item}"
                skipped=$((skipped + 1))
            fi
        done
    done

    if [[ "${#targets[@]}" -eq 0 ]]; then
        warn "没有可添加的目标。"
        return 1
    fi

    read_default "目标名称前缀" "target" prefix
    echo "检测方式："
    echo "  1. Ping"
    echo "  2. TCP 端口"
    while true; do
        read_default "请选择" "1" method_choice
        case "${method_choice}" in
            1) method="ping"; port="0"; break ;;
            2)
                method="tcp"
                while true; do
                    read_required "请输入 TCP 端口，例如 80 或 443" port
                    valid_port "${port}" && break
                    warn "端口必须是 1-65535 的数字。"
                done
                break
                ;;
            *) warn "请输入 1 或 2。" ;;
        esac
    done

    echo "告警策略："
    echo "  1. 任一 IP 不通就告警"
    echo "  2. 全部 IP 不通才告警"
    while true; do
        read_default "请选择" "1" mode_choice
        case "${mode_choice}" in
            1) mode="ANY"; break ;;
            2) mode="ALL"; break ;;
            *) warn "请输入 1 或 2。" ;;
        esac
    done

    select_notifier_ids notifier_ids "all"
    for target in "${targets[@]}"; do
        id="$(next_id "${TARGETS_DB}")"
        created="$(now_ts)"
        name="$(printf '%s-%03d' "${prefix}" "${index}")"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${name}" "${target}" "${method}" "${port}" "${mode}" "${notifier_ids}" "yes" "${created}" >> "${TARGETS_DB}"
        added=$((added + 1))
        index=$((index + 1))
    done

    ok "批量添加完成：新增 ${added} 个，跳过 ${skipped} 个。"
}

run_one_target() {
    ensure_data
    if [[ ! -s "${TARGETS_DB}" ]]; then
        warn "当前没有可巡检的监控目标。"
        return 0
    fi

    list_targets
    local seq wanted_id
    read_required "请输入要立即巡检的目标序号" seq
    [[ "${seq}" =~ ^[0-9]+$ ]] || { warn "请输入数字序号。"; return 1; }
    wanted_id="$(get_id_by_seq "${TARGETS_DB}" "${seq}")" || { warn "没有这个序号。"; return 1; }

    local id name target method port mode notifier_ids enabled created msg
    while IFS=$'\t' read -r id name target method port mode notifier_ids enabled created; do
        [[ "${id}" == "${wanted_id}" ]] || continue
        [[ "${enabled}" == "yes" ]] || warn "该目标当前是停用状态，本次仍会手动检测一次。"
        info "正在检测 [${name}] ${target} ($(method_label "${method}" "${port}"))"
        check_one_target "${name}" "${target}" "${method}" "${port}" "${mode}"
        if [[ "${CHECK_ALERT}" == "yes" ]]; then
            msg="$(build_alert_message "${name}" "${target}" "${method}" "${port}" "${mode}")"
            send_to_target_notifiers "${notifier_ids}" "${msg}" || true
            print_send_result "[${name}] "
        else
            ok "[${name}] 正常：${#CHECK_UP_IPS[@]}/${#CHECK_ALL_IPS[@]} 可达。"
        fi
        return 0
    done < "${TARGETS_DB}"
}

edit_target() {
    ensure_data
    if [[ ! -s "${TARGETS_DB}" ]]; then
        warn "当前没有可修改的监控目标。"
        return 0
    fi

    list_targets
    local seq wanted_id tmp
    read_required "请输入要修改的目标序号" seq
    [[ "${seq}" =~ ^[0-9]+$ ]] || { warn "请输入数字序号。"; return 1; }
    wanted_id="$(get_id_by_seq "${TARGETS_DB}" "${seq}")" || { warn "没有这个序号。"; return 1; }

    tmp="$(mktemp)"
    local id name target method port mode notifier_ids enabled created
    local new_name new_target new_method_choice new_method new_port new_mode_choice new_mode new_notifier_ids
    while IFS=$'\t' read -r id name target method port mode notifier_ids enabled created; do
        if [[ "${id}" == "${wanted_id}" ]]; then
            read_default "目标名称" "${name}" new_name
            while true; do
                read_default "域名或 IP" "${target}" new_target
                new_target="$(printf '%s' "${new_target}" | tr 'A-Z' 'a-z')"
                valid_target "${new_target}" && break
                warn "格式不正确，请重新输入。"
            done

            echo "检测方式：1. Ping  2. TCP 端口"
            read_default "请选择" "$([[ "${method}" == "tcp" ]] && echo 2 || echo 1)" new_method_choice
            if [[ "${new_method_choice}" == "2" ]]; then
                new_method="tcp"
                while true; do
                    read_default "TCP 端口" "${port}" new_port
                    valid_port "${new_port}" && break
                    warn "端口必须是 1-65535 的数字。"
                done
            else
                new_method="ping"
                new_port="0"
            fi

            echo "告警策略：1. 任一 IP 不通就告警  2. 全部 IP 不通才告警"
            read_default "请选择" "$([[ "${mode}" == "ALL" ]] && echo 2 || echo 1)" new_mode_choice
            [[ "${new_mode_choice}" == "2" ]] && new_mode="ALL" || new_mode="ANY"

            select_notifier_ids new_notifier_ids "${notifier_ids}"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${new_name}" "${new_target}" "${new_method}" "${new_port}" "${new_mode}" "${new_notifier_ids}" "${enabled}" "${created}" >> "${tmp}"
        else
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${name}" "${target}" "${method}" "${port}" "${mode}" "${notifier_ids}" "${enabled}" "${created}" >> "${tmp}"
        fi
    done < "${TARGETS_DB}"
    mv "${tmp}" "${TARGETS_DB}"
    ok "监控目标已修改。"
}

delete_target() {
    ensure_data
    if [[ ! -s "${TARGETS_DB}" ]]; then
        warn "当前没有可删除的监控目标。"
        return 0
    fi

    list_targets
    local seq wanted_id tmp removed="no"
    read_required "请输入要删除的目标序号，输入 0 取消" seq
    [[ "${seq}" =~ ^[0-9]+$ ]] || { warn "请输入数字序号。"; return 1; }
    [[ "${seq}" -eq 0 ]] && return 0
    wanted_id="$(get_id_by_seq "${TARGETS_DB}" "${seq}")" || { warn "没有这个序号。"; return 1; }

    tmp="$(mktemp)"
    local id name target method port mode notifier_ids enabled created
    while IFS=$'\t' read -r id name target method port mode notifier_ids enabled created; do
        [[ -n "${id}" ]] || continue
        if [[ "${id}" == "${wanted_id}" ]]; then
            removed="yes"
            info "已删除目标：${name} (${target})"
        else
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${name}" "${target}" "${method}" "${port}" "${mode}" "${notifier_ids}" "${enabled}" "${created}" >> "${tmp}"
        fi
    done < "${TARGETS_DB}"
    mv "${tmp}" "${TARGETS_DB}"
    [[ "${removed}" == "yes" ]] && ok "监控目标已删除。"
}

toggle_target() {
    ensure_data
    if [[ ! -s "${TARGETS_DB}" ]]; then
        warn "当前没有可操作的监控目标。"
        return 0
    fi

    list_targets
    local seq wanted_id tmp
    read_required "请输入要启用/停用的目标序号" seq
    [[ "${seq}" =~ ^[0-9]+$ ]] || { warn "请输入数字序号。"; return 1; }
    wanted_id="$(get_id_by_seq "${TARGETS_DB}" "${seq}")" || { warn "没有这个序号。"; return 1; }

    tmp="$(mktemp)"
    local id name target method port mode notifier_ids enabled created new_enabled
    while IFS=$'\t' read -r id name target method port mode notifier_ids enabled created; do
        if [[ "${id}" == "${wanted_id}" ]]; then
            [[ "${enabled}" == "yes" ]] && new_enabled="no" || new_enabled="yes"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${name}" "${target}" "${method}" "${port}" "${mode}" "${notifier_ids}" "${new_enabled}" "${created}" >> "${tmp}"
        else
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${name}" "${target}" "${method}" "${port}" "${mode}" "${notifier_ids}" "${enabled}" "${created}" >> "${tmp}"
        fi
    done < "${TARGETS_DB}"
    mv "${tmp}" "${TARGETS_DB}"
    ok "目标状态已切换。"
}

list_bots() {
    ensure_data
    if [[ ! -s "${BOTS_DB}" ]]; then
        warn "当前没有 Telegram 机器人。"
        return 0
    fi

    local seq=1 id name token created hidden
    printf '\n%-4s %-18s %-28s %s\n' "序号" "名称" "Token" "创建时间"
    printf '%s\n' "----------------------------------------------------------------------------"
    while IFS=$'\t' read -r id name token created; do
        [[ -n "${id}" ]] || continue
        hidden="${token:0:8}********${token: -6}"
        printf '%-4s %-18s %-28s %s\n' "${seq}" "${name}" "${hidden}" "${created}"
        seq=$((seq + 1))
    done < "${BOTS_DB}"
}

add_bot() {
    ensure_data
    local name token id created
    echo
    blue "新增 Telegram 机器人"
    read_required "机器人名称，例如 main-bot" name
    read_required "Bot Token" token
    id="$(next_id "${BOTS_DB}")"
    created="$(now_ts)"
    printf '%s\t%s\t%s\t%s\n' "${id}" "${name}" "${token}" "${created}" >> "${BOTS_DB}"
    ok "机器人已添加。"
}

edit_bot() {
    ensure_data
    if [[ ! -s "${BOTS_DB}" ]]; then
        warn "当前没有可修改的机器人。"
        return 0
    fi

    list_bots
    local seq wanted_id tmp
    read_required "请输入要修改的机器人序号" seq
    [[ "${seq}" =~ ^[0-9]+$ ]] || { warn "请输入数字序号。"; return 1; }
    wanted_id="$(get_id_by_seq "${BOTS_DB}" "${seq}")" || { warn "没有这个序号。"; return 1; }

    tmp="$(mktemp)"
    local id name token created new_name new_token
    while IFS=$'\t' read -r id name token created; do
        if [[ "${id}" == "${wanted_id}" ]]; then
            read_default "机器人名称" "${name}" new_name
            read_default "Bot Token" "${token}" new_token
            printf '%s\t%s\t%s\t%s\n' "${id}" "${new_name}" "${new_token}" "${created}" >> "${tmp}"
        else
            printf '%s\t%s\t%s\t%s\n' "${id}" "${name}" "${token}" "${created}" >> "${tmp}"
        fi
    done < "${BOTS_DB}"
    mv "${tmp}" "${BOTS_DB}"
    ok "机器人已修改。"
}

bot_is_used() {
    local wanted_id="$1"
    local id name bot_id chat_id type enabled created
    while IFS=$'\t' read -r id name bot_id chat_id type enabled created; do
        [[ "${bot_id}" == "${wanted_id}" ]] && return 0
    done < "${NOTIFIERS_DB}"
    return 1
}

delete_bot() {
    ensure_data
    if [[ ! -s "${BOTS_DB}" ]]; then
        warn "当前没有可删除的机器人。"
        return 0
    fi

    list_bots
    local seq wanted_id tmp removed="no"
    read_required "请输入要删除的机器人序号，输入 0 取消" seq
    [[ "${seq}" =~ ^[0-9]+$ ]] || { warn "请输入数字序号。"; return 1; }
    [[ "${seq}" -eq 0 ]] && return 0
    wanted_id="$(get_id_by_seq "${BOTS_DB}" "${seq}")" || { warn "没有这个序号。"; return 1; }

    if bot_is_used "${wanted_id}"; then
        warn "这个机器人正在被通知位置使用。请先修改或删除对应通知位置。"
        return 1
    fi

    tmp="$(mktemp)"
    local id name token created
    while IFS=$'\t' read -r id name token created; do
        [[ -n "${id}" ]] || continue
        if [[ "${id}" == "${wanted_id}" ]]; then
            removed="yes"
            info "已删除机器人：${name}"
        else
            printf '%s\t%s\t%s\t%s\n' "${id}" "${name}" "${token}" "${created}" >> "${tmp}"
        fi
    done < "${BOTS_DB}"
    mv "${tmp}" "${BOTS_DB}"
    [[ "${removed}" == "yes" ]] && ok "机器人已删除。"
}

list_notifiers() {
    ensure_data
    if [[ ! -s "${NOTIFIERS_DB}" ]]; then
        warn "当前没有通知位置。"
        return 0
    fi

    local seq=1 id name bot_id chat_id type enabled created bot_name
    printf '\n%-4s %-6s %-18s %-16s %-24s %-12s %s\n' "序号" "状态" "名称" "机器人" "Chat ID / @频道" "类型" "创建时间"
    printf '%s\n' "----------------------------------------------------------------------------------------------------"
    while IFS=$'\t' read -r id name bot_id chat_id type enabled created; do
        [[ -n "${id}" ]] || continue
        bot_name="$(get_bot_name_by_id "${bot_id}")"
        printf '%-4s %-6s %-18s %-16s %-24s %-12s %s\n' "${seq}" "$(status_label "${enabled}")" "${name}" "${bot_name}" "${chat_id}" "${type}" "${created}"
        seq=$((seq + 1))
    done < "${NOTIFIERS_DB}"
}

add_notifier() {
    ensure_data
    local name bot_id chat_id type_choice type id created
    echo
    blue "新增通知位置"
    select_bot_id bot_id || return 1
    read_required "通知位置名称，例如 admin、ops-group、notice-channel" name
    echo "位置类型："
    echo "  1. 私聊/用户"
    echo "  2. 群组/超级群"
    echo "  3. 频道"
    while true; do
        read_default "请选择" "1" type_choice
        case "${type_choice}" in
            1) type="私聊"; break ;;
            2) type="群组"; break ;;
            3) type="频道"; break ;;
            *) warn "请输入 1、2 或 3。" ;;
        esac
    done
    read_required "Chat ID 或 @频道用户名。群/频道请确保机器人已加入并有发言权限" chat_id
    id="$(next_id "${NOTIFIERS_DB}")"
    created="$(now_ts)"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${name}" "${bot_id}" "${chat_id}" "${type}" "yes" "${created}" >> "${NOTIFIERS_DB}"
    ok "通知位置已添加。"
}

edit_notifier() {
    ensure_data
    if [[ ! -s "${NOTIFIERS_DB}" ]]; then
        warn "当前没有可修改的通知位置。"
        return 0
    fi

    list_notifiers
    local seq wanted_id tmp
    read_required "请输入要修改的通知位置序号" seq
    [[ "${seq}" =~ ^[0-9]+$ ]] || { warn "请输入数字序号。"; return 1; }
    wanted_id="$(get_id_by_seq "${NOTIFIERS_DB}" "${seq}")" || { warn "没有这个序号。"; return 1; }

    tmp="$(mktemp)"
    local id name bot_id chat_id type enabled created new_name new_bot_id new_chat_id new_type_choice new_type new_type_choice_default
    while IFS=$'\t' read -r id name bot_id chat_id type enabled created; do
        if [[ "${id}" == "${wanted_id}" ]]; then
            read_default "通知位置名称" "${name}" new_name
            if confirm "是否更换机器人"; then
                select_bot_id new_bot_id || new_bot_id="${bot_id}"
            else
                new_bot_id="${bot_id}"
            fi
            read_default "Chat ID 或 @频道用户名" "${chat_id}" new_chat_id
            echo "位置类型：1. 私聊/用户  2. 群组/超级群  3. 频道"
            case "${type}" in
                群组) new_type_choice_default=2 ;;
                频道) new_type_choice_default=3 ;;
                *) new_type_choice_default=1 ;;
            esac
            read_default "请选择" "${new_type_choice_default}" new_type_choice
            case "${new_type_choice}" in
                2) new_type="群组" ;;
                3) new_type="频道" ;;
                *) new_type="私聊" ;;
            esac
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${new_name}" "${new_bot_id}" "${new_chat_id}" "${new_type}" "${enabled}" "${created}" >> "${tmp}"
        else
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${name}" "${bot_id}" "${chat_id}" "${type}" "${enabled}" "${created}" >> "${tmp}"
        fi
    done < "${NOTIFIERS_DB}"
    mv "${tmp}" "${NOTIFIERS_DB}"
    ok "通知位置已修改。"
}

remove_notifier_from_target_lists() {
    local removed_id="$1"
    local tmp id name target method port mode notifier_ids enabled created result part
    tmp="$(mktemp)"
    while IFS=$'\t' read -r id name target method port mode notifier_ids enabled created; do
        [[ -n "${id}" ]] || continue
        if [[ "${notifier_ids}" != "all" && "${notifier_ids}" != "none" ]]; then
            result=""
            IFS=',' read -r -a parts <<< "${notifier_ids}"
            for part in "${parts[@]}"; do
                part="$(clean_field "${part}")"
                [[ -z "${part}" || "${part}" == "${removed_id}" ]] && continue
                [[ -z "${result}" ]] && result="${part}" || result="${result},${part}"
            done
            notifier_ids="${result:-none}"
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${name}" "${target}" "${method}" "${port}" "${mode}" "${notifier_ids}" "${enabled}" "${created}" >> "${tmp}"
    done < "${TARGETS_DB}"
    mv "${tmp}" "${TARGETS_DB}"
}

delete_notifier() {
    ensure_data
    if [[ ! -s "${NOTIFIERS_DB}" ]]; then
        warn "当前没有可删除的通知位置。"
        return 0
    fi

    list_notifiers
    local seq wanted_id tmp removed="no"
    read_required "请输入要删除的通知位置序号，输入 0 取消" seq
    [[ "${seq}" =~ ^[0-9]+$ ]] || { warn "请输入数字序号。"; return 1; }
    [[ "${seq}" -eq 0 ]] && return 0
    wanted_id="$(get_id_by_seq "${NOTIFIERS_DB}" "${seq}")" || { warn "没有这个序号。"; return 1; }

    tmp="$(mktemp)"
    local id name bot_id chat_id type enabled created
    while IFS=$'\t' read -r id name bot_id chat_id type enabled created; do
        [[ -n "${id}" ]] || continue
        if [[ "${id}" == "${wanted_id}" ]]; then
            removed="yes"
            info "已删除通知位置：${name}"
        else
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${name}" "${bot_id}" "${chat_id}" "${type}" "${enabled}" "${created}" >> "${tmp}"
        fi
    done < "${NOTIFIERS_DB}"
    mv "${tmp}" "${NOTIFIERS_DB}"
    remove_notifier_from_target_lists "${wanted_id}"
    [[ "${removed}" == "yes" ]] && ok "通知位置已删除。"
}

toggle_notifier() {
    ensure_data
    if [[ ! -s "${NOTIFIERS_DB}" ]]; then
        warn "当前没有可操作的通知位置。"
        return 0
    fi

    list_notifiers
    local seq wanted_id tmp
    read_required "请输入要启用/停用的通知位置序号" seq
    [[ "${seq}" =~ ^[0-9]+$ ]] || { warn "请输入数字序号。"; return 1; }
    wanted_id="$(get_id_by_seq "${NOTIFIERS_DB}" "${seq}")" || { warn "没有这个序号。"; return 1; }

    tmp="$(mktemp)"
    local id name bot_id chat_id type enabled created new_enabled
    while IFS=$'\t' read -r id name bot_id chat_id type enabled created; do
        if [[ "${id}" == "${wanted_id}" ]]; then
            [[ "${enabled}" == "yes" ]] && new_enabled="no" || new_enabled="yes"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${name}" "${bot_id}" "${chat_id}" "${type}" "${new_enabled}" "${created}" >> "${tmp}"
        else
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${name}" "${bot_id}" "${chat_id}" "${type}" "${enabled}" "${created}" >> "${tmp}"
        fi
    done < "${NOTIFIERS_DB}"
    mv "${tmp}" "${NOTIFIERS_DB}"
    ok "通知位置状态已切换。"
}

test_notifier() {
    ensure_data
    if [[ ! -s "${NOTIFIERS_DB}" ]]; then
        warn "当前没有可测试的通知位置。"
        return 0
    fi

    list_notifiers
    local seq wanted_id msg
    read_required "请输入要测试的通知位置序号" seq
    [[ "${seq}" =~ ^[0-9]+$ ]] || { warn "请输入数字序号。"; return 1; }
    wanted_id="$(get_id_by_seq "${NOTIFIERS_DB}" "${seq}")" || { warn "没有这个序号。"; return 1; }
    msg="测试通知：${APP_NAME}
时间：$(now_ts)
结果：如果你看到这条消息，说明这个通知位置可用。"
    if send_to_notifier_id "${wanted_id}" "${msg}"; then
        ok "测试通知已发送。"
    else
        err "测试通知发送失败，请检查 Bot Token、Chat ID、机器人权限或服务器网络。"
    fi
}

stop_loop() {
    local mode="${1:-}"
    local pid=""

    if [[ -f "${LOOP_PID_FILE}" ]]; then
        pid="$(cat "${LOOP_PID_FILE}" 2>/dev/null || true)"
        if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
            kill "${pid}" 2>/dev/null || true
            sleep 1
            if kill -0 "${pid}" 2>/dev/null; then
                kill -9 "${pid}" 2>/dev/null || true
            fi
            [[ "${mode}" == "quiet" ]] || ok "秒级后台巡检已停止，PID ${pid}。"
        elif [[ "${mode}" != "quiet" ]]; then
            warn "秒级后台巡检没有运行。"
        fi
        rm -f "${LOOP_PID_FILE}"
    elif [[ "${mode}" != "quiet" ]]; then
        warn "秒级后台巡检没有运行。"
    fi
}

run_loop() {
    local interval="${1:-}"
    ensure_data

    if [[ ! "${interval}" =~ ^[0-9]+$ || "${interval}" -lt 1 ]]; then
        err "秒级巡检间隔必须是大于等于 1 的数字。"
        exit 1
    fi

    printf '%s\n' "$$" > "${LOOP_PID_FILE}"
    trap 'rm -f "${LOOP_PID_FILE}"; exit 0' INT TERM EXIT

    while true; do
        run_checks "loop"
        sleep "${interval}"
    done
}

setup_cron() {
    ensure_data
    local schedule_type interval script_path quoted_path cron_cmd current pid

    if [[ ! -s "${TARGETS_DB}" ]]; then
        warn "请先添加监控目标。"
        return 1
    fi
    if [[ ! -s "${NOTIFIERS_DB}" ]]; then
        warn "还没有通知位置。你可以继续设置定时巡检，但告警不会发送到 Telegram。"
    fi

    while true; do
        echo "巡检间隔单位："
        echo "  1. 秒"
        echo "  2. 分钟"
        read_default "请选择" "2" schedule_type
        case "${schedule_type}" in
            1|秒|s|S) schedule_type="second"; break ;;
            2|分钟|m|M) schedule_type="minute"; break ;;
            *) warn "请输入 1 或 2。" ;;
        esac
    done

    if [[ "${schedule_type}" == "second" ]]; then
        while true; do
            read_default "几秒巡检一次" "30" interval
            [[ "${interval}" =~ ^[0-9]+$ && "${interval}" -ge 1 ]] && break
            warn "请输入大于等于 1 的数字。"
        done
    else
        while true; do
            read_default "几分钟巡检一次" "3" interval
            [[ "${interval}" =~ ^[0-9]+$ && "${interval}" -ge 1 && "${interval}" -le 59 ]] && break
            warn "请输入 1-59 之间的数字。"
        done
    fi

    if [[ "${schedule_type}" == "minute" ]] && ! have_crontab; then
        err "当前系统没有 crontab，无法设置分钟级定时巡检。请选择秒级巡检，或先安装 cron。"
        return 1
    fi

    stop_loop "quiet"
    current="$(cron_without_mark)"

    if [[ "${schedule_type}" == "minute" ]]; then
        script_path="$(get_script_path)"
        quoted_path="$(shell_quote "${script_path}")"
        cron_cmd="*/${interval} * * * * bash ${quoted_path} --cron >/dev/null 2>&1 ${CRON_MARK}"
        {
            printf '%s\n' "${current}"
            printf '%s\n' "${cron_cmd}"
        } | crontab -
        ok "分钟级定时巡检已设置：每 ${interval} 分钟执行一次。"
        return 0
    fi

    if have_crontab; then
        printf '%s\n' "${current}" | crontab -
    fi
    script_path="$(get_script_path)"
    nohup bash "${script_path}" --loop "${interval}" >/dev/null 2>&1 &
    pid="$!"
    printf '%s\n' "${pid}" > "${LOOP_PID_FILE}"
    ok "秒级后台巡检已启动：每 ${interval} 秒执行一次，PID ${pid}。"
}

remove_cron() {
    local current
    stop_loop "quiet"
    if have_crontab; then
        current="$(cron_without_mark)"
        printf '%s\n' "${current}" | crontab -
    fi
    ok "定时巡检任务已移除。"
}

show_summary() {
    ensure_data
    local targets bots notifiers cron_lines loop_status pid
    targets="$(row_count "${TARGETS_DB}")"
    bots="$(row_count "${BOTS_DB}")"
    notifiers="$(row_count "${NOTIFIERS_DB}")"
    if have_crontab; then
        cron_lines="$(crontab -l 2>/dev/null | grep -F "${CRON_MARK}" || true)"
    else
        cron_lines="当前系统没有 crontab"
    fi
    loop_status="未运行"
    if [[ -f "${LOOP_PID_FILE}" ]]; then
        pid="$(cat "${LOOP_PID_FILE}" 2>/dev/null || true)"
        if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
            loop_status="运行中，PID ${pid}"
        else
            loop_status="PID 文件存在但进程不在：${pid:-unknown}"
        fi
    fi

    cat <<EOF

配置目录：${CONFIG_DIR}
监控目标：${targets} 个
Telegram 机器人：${bots} 个
通知位置：${notifiers} 个
分钟级 cron：
${cron_lines:-未设置}
秒级后台巡检：
${loop_status}
EOF
}

target_menu() {
    while true; do
        cat <<EOF

=========== 监控目标管理 ===========
1. 新增监控目标
2. 批量新增目标
3. 查看监控目标
4. 立即巡检指定目标
5. 修改监控目标
6. 删除监控目标
7. 启用/停用目标
0. 返回主菜单
====================================
EOF
        local choice
        read -r -p "请选择 [0-7]: " choice
        case "${choice}" in
            1) add_target; pause_enter ;;
            2) bulk_add_targets; pause_enter ;;
            3) list_targets; pause_enter ;;
            4) run_one_target; pause_enter ;;
            5) edit_target; pause_enter ;;
            6) delete_target; pause_enter ;;
            7) toggle_target; pause_enter ;;
            0) return 0 ;;
            *) warn "无效选项，请重新输入。" ;;
        esac
    done
}

bot_menu() {
    while true; do
        cat <<EOF

=========== Telegram 机器人管理 ===========
1. 新增机器人
2. 查看机器人
3. 修改机器人
4. 删除机器人
0. 返回主菜单
===========================================
EOF
        local choice
        read -r -p "请选择 [0-4]: " choice
        case "${choice}" in
            1) add_bot; pause_enter ;;
            2) list_bots; pause_enter ;;
            3) edit_bot; pause_enter ;;
            4) delete_bot; pause_enter ;;
            0) return 0 ;;
            *) warn "无效选项，请重新输入。" ;;
        esac
    done
}

notifier_menu() {
    while true; do
        cat <<EOF

=========== 通知位置管理 ===========
1. 新增通知位置
2. 查看通知位置
3. 修改通知位置
4. 删除通知位置
5. 启用/停用通知位置
6. 发送测试通知
0. 返回主菜单
====================================
EOF
        local choice
        read -r -p "请选择 [0-6]: " choice
        case "${choice}" in
            1) add_notifier; pause_enter ;;
            2) list_notifiers; pause_enter ;;
            3) edit_notifier; pause_enter ;;
            4) delete_notifier; pause_enter ;;
            5) toggle_notifier; pause_enter ;;
            6) test_notifier; pause_enter ;;
            0) return 0 ;;
            *) warn "无效选项，请重新输入。" ;;
        esac
    done
}

cron_menu() {
    while true; do
        cat <<EOF

=========== 定时巡检 ===========
1. 设置/更新巡检间隔
2. 停止定时巡检
3. 查看配置概览
0. 返回主菜单
================================
EOF
        local choice
        read -r -p "请选择 [0-3]: " choice
        case "${choice}" in
            1) setup_cron; pause_enter ;;
            2) remove_cron; pause_enter ;;
            3) show_summary; pause_enter ;;
            0) return 0 ;;
            *) warn "无效选项，请重新输入。" ;;
        esac
    done
}

main_menu() {
    check_deps
    while true; do
        cat <<EOF

================ ${APP_NAME} ================
1. 监控目标管理
2. Telegram 机器人管理
3. 通知位置管理
4. 立即巡检全部目标
5. 定时巡检设置
6. 查看配置概览
0. 退出
================================================
EOF
        local choice
        read -r -p "请选择 [0-6]: " choice
        case "${choice}" in
            1) target_menu ;;
            2) bot_menu ;;
            3) notifier_menu ;;
            4) run_checks "manual"; pause_enter ;;
            5) cron_menu ;;
            6) show_summary; pause_enter ;;
            0) echo "已退出。"; exit 0 ;;
            *) warn "无效选项，请重新输入。" ;;
        esac
    done
}

usage() {
    cat <<EOF
用法：
  bash auto.sh             打开交互菜单
  bash auto.sh --cron      执行一次巡检，供 cron 调用
  bash auto.sh --loop 秒数  秒级后台循环巡检
  bash auto.sh run         手动执行一次巡检
  bash auto.sh list        查看配置概览
EOF
}

main() {
    ensure_data
    migrate_legacy_config

    case "${1:-}" in
        --cron|cron) run_checks "cron" ;;
        --loop|loop) run_loop "${2:-}" ;;
        run|test) run_checks "manual" ;;
        list|status) show_summary ;;
        help|-h|--help) usage ;;
        "") main_menu ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"

