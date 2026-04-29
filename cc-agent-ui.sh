#!/usr/bin/env bash
#
# Claude Code 多 Agent 管理 - 交互式界面
# 用法: ~/cc-agent-ui.sh
#

# 注意: 不使用 set -e 以避免意外退出，使用显式错误处理
set -o pipefail

# 设置 SCRIPT_DIR 变量（如果未设置）
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# 配置目录
AGENTS_DIR="$HOME/.claude/agents"
PID_DIR="$AGENTS_DIR/pids"
LOG_DIR="$AGENTS_DIR/logs"

# 颜色定义
RED='\e[0;31m'
GREEN='\e[0;32m'
YELLOW='\e[1;33m'
BLUE='\e[0;34m'
CYAN='\e[0;36m'
DIM='\e[2m'
BOLD='\e[1m'
NC='\e[0m'

# ── 通用工具函数 ──

# 初始化目录
init_dirs() {
    mkdir -p "$AGENTS_DIR" "$PID_DIR" "$LOG_DIR"
}

# 检查依赖
check_deps() {
    local deps_ok=true
    for cmd in python3 curl; do
        if ! command -v "$cmd" &>/dev/null; then
            echo -e "${RED}错误: 缺少依赖 $cmd${NC}"
            deps_ok=false
        fi
    done

    # Python 版本检查 (需要 3.6+)
    if ! python3 -c "import sys; assert sys.version_info >= (3, 6)" 2>/dev/null; then
        echo -e "${RED}错误: Python 版本过低，需要 3.6 或更高版本${NC}"
        echo -e "${RED}当前版本: $(python3 --version 2>&1 || echo "未知")${NC}"
        deps_ok=false
    fi

    $deps_ok || return 1
}

# 暂停并等待用户按回车
pause() {
    echo ""
    echo "按回车键返回菜单..."
    read -r
}

# 清屏
clear_screen() {
    clear 2>/dev/null || printf '\033[2J\033[H'
}

# ── Agent 数据访问函数 ──

# 获取所有 Agent 列表
get_agents() {
    local -n arr=$1
    arr=()
    for f in "$AGENTS_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        arr+=("$(basename "$f" .json)")
    done
}

# 获取 Agent 配置（安全版本：使用环境变量传递参数）
get_agent_config() {
    local name="$1"
    local key="$2"
    local config_file="$AGENTS_DIR/$name.json"

    if [[ ! -f "$config_file" ]]; then
        echo "未知"
        return
    fi

    # 使用环境变量传递参数，避免 Python 代码注入
    CONFIG_FILE="$config_file" CONFIG_KEY="$key" python3 -c '
import json
import os
try:
    with open(os.environ["CONFIG_FILE"]) as f:
        c = json.load(f)
    key = os.environ["CONFIG_KEY"]
    if key == "vendor.name":
        print(c.get("vendor", {}).get("name", "未知"))
    elif key == "model":
        print(c.get("model", "未知"))
    else:
        print(c.get(key, "未知"))
except Exception:
    print("未知")
' 2>/dev/null || echo "未知"
}

# 检查 Agent 是否运行
is_agent_running() {
    local name="$1"
    local pid_file="$PID_DIR/$name.pid"

    [[ ! -f "$pid_file" ]] && return 1

    local pid
    pid=$(cat "$pid_file" 2>/dev/null) || return 1
    [[ -z "$pid" ]] && return 1

    kill -0 "$pid" 2>/dev/null || return 1
}

# 获取 Agent 状态统计
get_agent_stats() {
    local -a agents=()
    local running_count=0
    get_agents agents

    for name in "${agents[@]}"; do
        is_agent_running "$name" && ((running_count++))
    done

    printf "%s|%s" "${#agents[@]}" "$running_count"
}

# ── 供应商相关函数 ──

# 从 api-keys.conf 获取供应商列表
get_vendors_from_ccsh() {
    local -n arr=$1
    arr=()

    # 从当前目录查找 api-keys.conf
    local api_keys_conf="${SCRIPT_DIR:-.}/api-keys.conf"
    [[ ! -f "$api_keys_conf" ]] && api_keys_conf="$HOME/api-keys.conf"
    [[ ! -f "$api_keys_conf" ]] && api_keys_conf="./api-keys.conf"

    if [[ ! -f "$api_keys_conf" ]]; then
        return
    fi

    # 从 api-keys.conf 读取供应商定义
    while IFS= read -r line; do
        # 跳过空行和注释
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # 匹配 "数字|名称|..." 格式的行
        if [[ "$line" =~ ^[0-9]+\| ]]; then
            # 提取编号和名称
            local num=${line%%|*}
            local rest=${line#*|}
            local name=${rest%%|*}
            if [[ -n "$num" && -n "$name" ]]; then
                arr+=("$num|$name")
            fi
        fi
    done < "$api_keys_conf"
}

# 选择供应商
select_vendor() {
    local -n result=$1

    local -a vendors=()
    get_vendors_from_ccsh vendors

    if [[ ${#vendors[@]} -eq 0 ]]; then
        echo -e "${RED}错误: 无法从 cc.sh 读取供应商列表${NC}"
        result=""
        return 1
    fi

    echo -e "${BOLD}可用供应商:${NC}"
    echo ""

    local i=1
    for v in "${vendors[@]}"; do
        local num=${v%%|*}
        local name=${v#*|}
        printf "  ${GREEN}%2d)${NC} [%s] %s\n" "$i" "$num" "$name"
        ((i++))
    done

    echo ""
    read -r -p "选择供应商 (1-${#vendors[@]}): " choice

    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt ${#vendors[@]} ]]; then
        echo -e "${RED}无效选择${NC}"
        result=""
        return 1
    fi

    local idx=$((choice - 1))
    result=${vendors[$idx]%%|*}
    return 0
}

# ── UI 显示函数 ──

# 显示标题
show_header() {
    printf "\e[0;36m╔══════════════════════════════════════════════════════════════╗\e[0m\n"
    printf "\e[0;36m║\e[0m           \e[1mClaude Code 多 Agent 管理工具\e[0m                    \e[0;36m║\e[0m\n"
    printf "\e[0;36m╚══════════════════════════════════════════════════════════════╝\e[0m\n"
    printf "\n"
}

# 显示菜单选项（带状态统计）
show_menu() {
    local total=0 running=0 stats
    stats=$(get_agent_stats)
    total=${stats%%|*}
    running=${stats#*|}

    printf "\n"
    if [[ $total -gt 0 ]]; then
        printf "\e[1;36m─── Agent 状态: %d 个总, %d 个运行中 ───\e[0m\n" "$total" "$running"
    fi
    printf "\n"
    printf "\e[1m请选择操作:\e[0m\n"
    printf "\n"
    printf "  \e[0;32m1)\e[0m 创建新 Agent\n"
    printf "  \e[0;32m2)\e[0m 启动 Agent\n"
    printf "  \e[0;32m3)\e[0m 停止 Agent\n"
    printf "  \e[0;32m4)\e[0m 查看所有 Agent 状态\n"
    printf "  \e[0;32m5)\e[0m 编辑 Agent 配置\n"
    printf "  \e[0;32m6)\e[0m 删除 Agent\n"
    printf "  \e[0;32m7)\e[0m 查看 Agent 日志\n"
    printf "  \e[0;32m8)\e[0m 批量操作\n"
    printf "  \e[0;32m9)\e[0m 供应商/模型配置管理\n"
    printf "\n"
    printf "  \e[1;33m0)\e[0m 退出\n"
    printf "\n"
}

# 显示 Agent 选择列表
# 参数: $1=标题, $2=是否显示已停止(true/false), $3=是否显示全选选项(true/false)
# 返回: 选择的 Agent 名称（通过 result 数组），选择 "0" 表示全选
select_agent() {
    local title="$1"
    local include_stopped=${2:-true}
    local show_all_option=${3:-false}
    local -n result=$4

    local -a agents=()
    get_agents agents

    # 过滤列表
    local -a display_agents=()
    if $include_stopped; then
        display_agents=("${agents[@]}")
    else
        for name in "${agents[@]}"; do
            is_agent_running "$name" && display_agents+=("$name")
        done
    fi

    if [[ ${#display_agents[@]} -eq 0 ]]; then
        if [[ ${#agents[@]} -eq 0 ]]; then
            echo -e "${YELLOW}还没有创建任何 Agent${NC}"
        else
            echo -e "${YELLOW}没有符合条件的 Agent${NC}"
        fi
        return 1
    fi

    echo "可用 Agent:"
    echo ""

    local i=1
    for name in "${display_agents[@]}"; do
        local status="${DIM}停止${NC}"
        local extra=""
        if is_agent_running "$name"; then
            status="${GREEN}运行中${NC}"
            local pid=$(cat "$PID_DIR/$name.pid" 2>/dev/null || true)
            [[ -n "$pid" ]] && extra=" (PID: $pid)"
        fi
        printf "  %d) %-20s [%b%s]\n" "$i" "$name" "$status" "$extra"
        ((i++))
    done

    echo ""
    if $show_all_option && [[ ${#display_agents[@]} -gt 1 ]]; then
        echo "  0) 全部"
        echo ""
        read -r -p "选择 (0-${#display_agents[@]}): " choice
        if [[ "$choice" == "0" ]]; then
            result=("${display_agents[@]}")
            return 0
        fi
    else
        read -r -p "选择 (1-${#display_agents[@]}): " choice
    fi

    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt ${#display_agents[@]} ]]; then
        echo -e "${RED}无效选择${NC}"
        return 1
    fi

    local idx=$((choice - 1))
    result=("${display_agents[$idx]}")
    return 0
}

# ── 菜单功能函数 ──

run_cc_config_command() {
    local title="$1"
    shift
    clear_screen
    show_header
    echo -e "${BOLD}${title}${NC}"
    echo ""

    if [[ ! -x "$SCRIPT_DIR/cc.sh" ]]; then
        echo -e "${RED}错误: 找不到可执行脚本 $SCRIPT_DIR/cc.sh${NC}"
        pause
        return
    fi

    "$SCRIPT_DIR/cc.sh" "$@"
    pause
}

menu_config_management() {
    while true; do
        clear_screen
        show_header
        echo -e "${BOLD}供应商/模型配置管理${NC}"
        echo ""
        echo "  1) 查看供应商列表"
        echo "  2) 新增供应商"
        echo "  3) 修改供应商"
        echo "  4) 删除供应商"
        echo "  5) 查看供应商模型"
        echo "  6) 新增模型"
        echo "  7) 修改模型"
        echo "  8) 删除模型"
        echo ""
        echo "  q) 返回上一级"
        echo ""

        local choice
        read -r -p "输入选项: " choice

        case "$choice" in
            1) run_cc_config_command "查看供应商列表" list ;;
            2) run_cc_config_command "新增供应商" provider-add ;;
            3) run_cc_config_command "修改供应商" provider-edit ;;
            4) run_cc_config_command "删除供应商" provider-delete ;;
            5) run_cc_config_command "查看供应商模型" model-list ;;
            6) run_cc_config_command "新增模型" model-add ;;
            7) run_cc_config_command "修改模型" model-edit ;;
            8) run_cc_config_command "删除模型" model-delete ;;
            0|q|Q) return ;;
            *)
                echo -e "${RED}无效选项，请重新选择${NC}"
                sleep 1
                ;;
        esac
    done
}

# 菜单：创建新 Agent
menu_create_agent() {
    clear_screen
    show_header
    echo -e "${BOLD}创建新 Agent${NC}"
    echo ""

    # 输入名称
    local name=""
    while [[ -z "$name" ]]; do
        read -r -p "输入 Agent 名称 (如: agent1): " name
        if [[ -z "$name" ]]; then
            echo -e "${RED}名称不能为空${NC}"
            continue
        fi

        # 检查是否已存在
        if [[ -f "$AGENTS_DIR/$name.json" ]]; then
            echo -e "${RED}错误: Agent '$name' 已存在${NC}"
            name=""
            continue
        fi
    done

    # 选择供应商
    local vendor_num=""
    if ! select_vendor vendor_num; then
        pause
        return
    fi

    # 获取供应商的默认模型
    local default_model=""
    local api_keys_conf="${SCRIPT_DIR:-.}/api-keys.conf"
    [[ ! -f "$api_keys_conf" ]] && api_keys_conf="$HOME/api-keys.conf"
    [[ ! -f "$api_keys_conf" ]] && api_keys_conf="./api-keys.conf"
    if [[ -f "$api_keys_conf" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
            if [[ "$line" =~ ^"$vendor_num"\| ]]; then
                local IFS='|'
                local -a parts=($line)
                default_model="${parts[4]:-}"
                break
            fi
        done < "$api_keys_conf"
    fi

    # 选择模型（可选）
    echo ""
    if [[ -n "$default_model" ]]; then
        read -r -p "指定模型名称 (回车默认: $default_model): " model
    else
        read -r -p "指定模型名称 (直接回车使用默认): " model
    fi

    # 创建 Agent
    echo ""
    echo "正在创建 Agent '$name'..."

    if "$SCRIPT_DIR/cc-agent.sh" create "$name" "$vendor_num" ${model:+"$model"}; then
        echo ""
        echo -e "${GREEN}✓ Agent 创建成功!${NC}"
        echo ""
        read -r -p "是否立即启动? (y/n): " start_now
        if [[ "$start_now" == "y" || "$start_now" == "Y" ]]; then
            echo ""
            "$SCRIPT_DIR/cc-agent.sh" start "$name"
        fi
    else
        echo -e "${RED}✗ Agent 创建失败${NC}"
    fi

    pause
}

# 菜单：启动 Agent
menu_start_agent() {
    clear_screen
    show_header
    echo -e "${BOLD}启动 Agent${NC}"
    echo ""

    local -a selected=()
    if ! select_agent "启动 Agent" true true selected; then
        pause
        return
    fi

    echo ""
    for name in "${selected[@]}"; do
        if is_agent_running "$name"; then
            echo -e "${YELLOW}Agent '$name' 已经在运行${NC}"
        else
            echo "正在启动 '$name'..."
            "$SCRIPT_DIR/cc-agent.sh" start "$name"
        fi
    done

    pause
}

# 菜单：停止 Agent
menu_stop_agent() {
    clear_screen
    show_header
    echo -e "${BOLD}停止 Agent${NC}"
    echo ""

    local -a selected=()
    if ! select_agent "停止 Agent" false true selected; then
        pause
        return
    fi

    echo ""
    for name in "${selected[@]}"; do
        echo "正在停止 '$name'..."
        "$SCRIPT_DIR/cc-agent.sh" stop "$name"
    done

    pause
}

# 菜单：查看状态
menu_status() {
    clear_screen
    show_header

    "$SCRIPT_DIR/cc-agent.sh" status

    pause
}

# 菜单：编辑 Agent 配置
menu_edit_agent() {
    clear_screen
    show_header
    echo -e "${BOLD}编辑 Agent 配置${NC}"
    echo ""

    local -a selected=()
    if ! select_agent "编辑 Agent" true false selected; then
        pause
        return
    fi

    local name="${selected[0]}"
    local config_file="$AGENTS_DIR/$name.json"

    echo ""
    echo "当前配置 ($name):"
    echo "────────────────────────────────────────"
    if [[ -f "$config_file" ]]; then
        cat "$config_file"
    else
        echo -e "${RED}配置文件不存在${NC}"
    fi
    echo "────────────────────────────────────────"
    echo ""

    # 确定编辑器
    local editor="${EDITOR:-nano}"
    if ! command -v "$editor" &>/dev/null; then
        editor="nano"
    fi
    if ! command -v "$editor" &>/dev/null; then
        editor="vi"
    fi

    read -r -p "是否在编辑器 ($editor) 中打开? (y/n): " edit_confirm
    if [[ "$edit_confirm" == "y" || "$edit_confirm" == "Y" ]]; then
        "$editor" "$config_file"
        echo ""
        echo -e "${GREEN}配置已更新${NC}"
    fi

    pause
}

# 菜单：删除 Agent
menu_remove_agent() {
    clear_screen
    show_header
    echo -e "${BOLD}删除 Agent${NC}"
    echo ""

    local -a selected=()
    if ! select_agent "删除 Agent" true false selected; then
        pause
        return
    fi

    local name="${selected[0]}"

    # 确认
    echo ""
    echo -e "${RED}警告: 这将永久删除 Agent '$name'${NC}"
    read -r -p "输入 'yes' 确认删除: " confirm

    if [[ "$confirm" == "yes" ]]; then
        echo ""
        "$SCRIPT_DIR/cc-agent.sh" remove "$name" || true
    else
        echo "已取消"
    fi

    pause
}

# 菜单：查看日志
menu_view_logs() {
    clear_screen
    show_header
    echo -e "${BOLD}查看日志${NC}"
    echo ""

    local -a selected=()
    if ! select_agent "查看日志" true false selected; then
        pause
        return
    fi

    local name="${selected[0]}"
    local log_file="$LOG_DIR/$name.log"

    if [[ -f "$log_file" ]]; then
        echo ""
        echo "显示 $name 的最近日志 (按 q 退出):"
        echo "---"
        if command -v less &>/dev/null; then
            tail -50 "$log_file" | less -R
        else
            tail -50 "$log_file"
        fi
    else
        echo -e "${YELLOW}该 Agent 还没有日志${NC}"
    fi

    pause
}

# 批量操作
menu_batch() {
    clear_screen
    show_header
    echo -e "${BOLD}批量操作${NC}"
    echo ""
    echo "  1) 启动所有 Agent"
    echo "  2) 停止所有 Agent"
    echo "  3) 重启所有 Agent"
    echo ""
    read -r -p "选择操作 (1-3): " choice

    local -a agents=()
    get_agents agents

    case "$choice" in
        1)
            echo ""
            echo "启动所有 Agent..."
            for name in "${agents[@]}"; do
                if is_agent_running "$name"; then
                    echo "  $name: 已在运行"
                else
                    echo -n "  $name: "
                    if "$SCRIPT_DIR/cc-agent.sh" start "$name" >/dev/null 2>&1; then
                        echo -e "${GREEN}启动成功${NC}"
                    else
                        echo -e "${RED}启动失败${NC}"
                    fi
                fi
            done
            ;;
        2)
            echo ""
            echo "停止所有 Agent..."
            for name in "${agents[@]}"; do
                if is_agent_running "$name"; then
                    echo -n "  $name: "
                    if "$SCRIPT_DIR/cc-agent.sh" stop "$name" >/dev/null 2>&1; then
                        echo -e "${GREEN}已停止${NC}"
                    else
                        echo -e "${RED}停止失败${NC}"
                    fi
                else
                    echo "  $name: 未运行"
                fi
            done
            ;;
        3)
            echo ""
            echo "重启所有 Agent..."
            for name in "${agents[@]}"; do
                echo -n "  $name: "
                "$SCRIPT_DIR/cc-agent.sh" stop "$name" >/dev/null 2>&1 || true
                sleep 0.5
                if "$SCRIPT_DIR/cc-agent.sh" start "$name" >/dev/null 2>&1; then
                    echo -e "${GREEN}重启成功${NC}"
                else
                    echo -e "${RED}重启失败${NC}"
                fi
            done
            ;;
        *)
            echo -e "${RED}无效选择${NC}"
            ;;
    esac

    pause
}

# ── 主菜单循环 ──

main_loop() {
    while true; do
        clear_screen
        show_header
        show_menu

        read -r -p "输入选项 (0-9): " choice

        case "$choice" in
            1) menu_create_agent ;;
            2) menu_start_agent ;;
            3) menu_stop_agent ;;
            4) menu_status ;;
            5) menu_edit_agent ;;
            6) menu_remove_agent ;;
            7) menu_view_logs ;;
            8) menu_batch ;;
            9) menu_config_management ;;
            0)
                clear_screen
                echo -e "${GREEN}再见!${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}无效选项，请重新选择${NC}"
                sleep 1
                ;;
        esac
    done
}

# ── 程序入口 ──

if ! check_deps; then
    exit 1
fi
init_dirs
main_loop
