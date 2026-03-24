#!/usr/bin/env bash
#
# Claude Code 多 Agent 管理 - 交互式界面
# 用法: ~/cc-agent-ui.sh
#

set -e

# 配置目录
AGENTS_DIR="$HOME/.claude/agents"
PID_DIR="$AGENTS_DIR/pids"
LOG_DIR="$AGENTS_DIR/logs"

# 颜色定义 (使用 printf 的 %b 格式支持)
RED='\e[0;31m'
GREEN='\e[0;32m'
YELLOW='\e[1;33m'
BLUE='\e[0;34m'
CYAN='\e[0;36m'
DIM='\e[2m'
BOLD='\e[1m'
NC='\e[0m'

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
    $deps_ok || exit 1
}

# 清屏
clear_screen() {
    clear 2>/dev/null || printf '\033[2J\033[H'
}

# 显示标题
show_header() {
    printf "\e[0;36m╔══════════════════════════════════════════════════════════════╗\e[0m\n"
    printf "\e[0;36m║\e[0m           \e[1mClaude Code 多 Agent 管理工具\e[0m                    \e[0;36m║\e[0m\n"
    printf "\e[0;36m╚══════════════════════════════════════════════════════════════╝\e[0m\n"
    printf "\n"
}

# 显示菜单选项
show_menu() {
    printf "\n"
    printf "\e[1m请选择操作:\e[0m\n"
    printf "\n"
    printf "  \e[0;32m1)\e[0m 创建新 Agent\n"
    printf "  \e[0;32m2)\e[0m 启动 Agent\n"
    printf "  \e[0;32m3)\e[0m 停止 Agent\n"
    printf "  \e[0;32m4)\e[0m 查看所有 Agent 状态\n"
    printf "  \e[0;32m5)\e[0m 删除 Agent\n"
    printf "  \e[0;32m6)\e[0m 查看 Agent 日志\n"
    printf "  \e[0;32m7)\e[0m 批量操作\n"
    printf "\n"
    printf "  \e[1;33m0)\e[0m 退出\n"
    printf "\n"
}

# 获取所有 Agent 列表
get_agents() {
    local -n arr=$1
    arr=()
    for f in "$AGENTS_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        arr+=("$(basename "$f" .json)")
    done
}

# 获取 Agent 配置
get_agent_config() {
    local name="$1"
    local key="$2"
    local config_file="$AGENTS_DIR/$name.json"

    if [[ ! -f "$config_file" ]]; then
        echo "未知"
        return
    fi

    python3 -c "
import json
try:
    with open('$config_file') as f:
        c = json.load(f)
    if '$key' == 'vendor.name':
        print(c.get('vendor', {}).get('name', '未知'))
    elif '$key' == 'model':
        print(c.get('model', '未知'))
    else:
        print(c.get('$key', '未知'))
except:
    print('未知')
" 2>/dev/null || echo "未知"
}

# 检查 Agent 是否运行
is_agent_running() {
    local name="$1"
    local pid_file="$PID_DIR/$name.pid"

    [[ ! -f "$pid_file" ]] && return 1

    local pid
    pid=$(cat "$pid_file" 2>/dev/null) || true
    [[ -z "$pid" ]] && return 1

    kill -0 "$pid" 2>/dev/null || return 1
}

# 从 cc.sh 获取供应商列表
get_vendors_from_ccsh() {
    local -n arr=$1
    arr=()

    # 从当前目录或家目录查找 cc.sh
    local cc_script="${SCRIPT_DIR:-.}/cc.sh"
    [[ ! -f "$cc_script" ]] && cc_script="$HOME/cc.sh"
    [[ ! -f "$cc_script" ]] && cc_script="./cc.sh"

    # 从 cc.sh 读取供应商定义
    while IFS= read -r line; do
        # 匹配 "数字|名称|..." 格式的行
        if [[ "$line" =~ ^[[:space:]]*\"[0-9]+\| ]]; then
            # 提取编号和名称
            local num=$(echo "$line" | grep -oE '[0-9]+' | head -1 || true)
            local name=$(echo "$line" | cut -d'|' -f2 | tr -d '"')
            if [[ -n "$num" && -n "$name" ]]; then
                arr+=("$num|$name")
            fi
        fi
    done < <(grep -E '^\s*"[0-9]+\|' "$cc_script" 2>/dev/null || echo "")
}

# 设置 SCRIPT_DIR 变量（如果未设置）
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# 选择供应商
elect_vendor() {
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
        local num=$(echo "$v" | cut -d'|' -f1)
        local name=$(echo "$v" | cut -d'|' -f2-)
        printf "  ${GREEN}%2d)${NC} [%s] %s\n" "$i" "$num" "$name"
        ((i++))
    done

    echo ""
    read -p "选择供应商 (1-${#vendors[@]}): " choice

    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ $choice -lt 1 ]] || [[ $choice -gt ${#vendors[@]} ]]; then
        echo -e "${RED}无效选择${NC}"
        result=""
        return 1
    fi

    local idx=$((choice - 1))
    result=$(echo "${vendors[$idx]}" | cut -d'|' -f1)
    return 0
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
        read -p "输入 Agent 名称 (如: agent1): " name
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
    if ! elect_vendor vendor_num; then
        echo ""
        echo "按回车键返回菜单..."
        read
        return
    fi

    # 选择模型（可选）
    echo ""
    read -p "指定模型名称 (直接回车使用默认): " model

    # 创建 Agent
    echo ""
    echo "正在创建 Agent '$name'..."

    if "$SCRIPT_DIR/cc-agent.sh" create "$name" "$vendor_num" ${model:+"$model"}; then
        echo ""
        echo -e "${GREEN}✓ Agent 创建成功!${NC}"
        echo ""
        read -p "是否立即启动? (y/n): " start_now
        if [[ "$start_now" == "y" || "$start_now" == "Y" ]]; then
            echo ""
            "$SCRIPT_DIR/cc-agent.sh" start "$name"
        fi
    else
        echo -e "${RED}✗ Agent 创建失败${NC}"
    fi

    echo ""
    echo "按回车键返回菜单..."
    read
}

# 菜单：启动 Agent
menu_start_agent() {
    clear_screen
    show_header
    echo -e "${BOLD}启动 Agent${NC}"
    echo ""

    local -a agents=()
    get_agents agents

    if [[ ${#agents[@]} -eq 0 ]]; then
        echo -e "${YELLOW}还没有创建任何 Agent${NC}"
        echo ""
        echo "使用菜单选项 1 创建新 Agent"
    else
        echo "可用 Agent:"
        echo ""

        local i=1
        for name in "${agents[@]}"; do
            local status="${DIM}停止${NC}"
            if is_agent_running "$name"; then
                status="${GREEN}运行中${NC}"
            fi
            printf "  %d) %-20s [%b]\n" "$i" "$name" "$status"
            ((i++))
        done

        echo ""
        read -p "选择要启动的 Agent (1-${#agents[@]}): " choice

        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#agents[@]} ]]; then
            local idx=$((choice - 1))
            local name="${agents[$idx]}"

            if is_agent_running "$name"; then
                echo -e "${YELLOW}Agent '$name' 已经在运行${NC}"
            else
                echo ""
                "$SCRIPT_DIR/cc-agent.sh" start "$name"
            fi
        else
            echo -e "${RED}无效选择${NC}"
        fi
    fi

    echo ""
    echo "按回车键返回菜单..."
    read
}

# 菜单：停止 Agent
menu_stop_agent() {
    clear_screen
    show_header
    echo -e "${BOLD}停止 Agent${NC}"
    echo ""

    local -a agents=()

    # 只显示运行中的 agent
    for f in "$AGENTS_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        local name=$(basename "$f" .json)
        if is_agent_running "$name"; then
            agents+=("$name")
        fi
    done

    if [[ ${#agents[@]} -eq 0 ]]; then
        echo -e "${YELLOW}没有运行中的 Agent${NC}"
    else
        echo "运行中的 Agent:"
        echo ""

        local i=1
        for name in "${agents[@]}"; do
            local pid=$(cat "$PID_DIR/$name.pid" 2>/dev/null || true)
            printf "  %d) %-20s (PID: %s)\n" "$i" "$name" "$pid"
            ((i++))
        done

        echo ""
        echo "  0) 停止所有"
        echo ""
        read -p "选择要停止的 Agent (0-${#agents[@]}): " choice

        if [[ "$choice" == "0" ]]; then
            echo ""
            echo "正在停止所有 Agent..."
            for name in "${agents[@]}"; do
                echo -n "  停止 $name ... "
                if "$SCRIPT_DIR/cc-agent.sh" stop "$name" >/dev/null 2>&1; then
                    echo -e "${GREEN}OK${NC}"
                else
                    echo -e "${RED}失败${NC}"
                fi
            done
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#agents[@]} ]]; then
            local idx=$((choice - 1))
            local name="${agents[$idx]}"
            echo ""
            "$SCRIPT_DIR/cc-agent.sh" stop "$name"
        else
            echo -e "${RED}无效选择${NC}"
        fi
    fi

    echo ""
    echo "按回车键返回菜单..."
    read
}

# 菜单：查看状态
menu_status() {
    clear_screen
    show_header

    "$SCRIPT_DIR/cc-agent.sh" status || true

    echo ""
    echo "按回车键返回菜单..."
    read
}

# 菜单：删除 Agent
menu_remove_agent() {
    clear_screen
    show_header
    echo -e "${BOLD}删除 Agent${NC}"
    echo ""

    local -a agents=()
    get_agents agents

    if [[ ${#agents[@]} -eq 0 ]]; then
        echo -e "${YELLOW}还没有创建任何 Agent${NC}"
    else
        echo "已创建的 Agent:"
        echo ""

        local i=1
        for name in "${agents[@]}"; do
            printf "  %d) %s\n" "$i" "$name"
            ((i++))
        done

        echo ""
        read -p "选择要删除的 Agent (1-${#agents[@]}): " choice

        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ $choice -ge 1 ]] && [[ $choice -le ${#agents[@]} ]]; then
            local idx=$((choice - 1))
            local name="${agents[$idx]}"

            # 确认
            echo ""
            echo -e "${RED}警告: 这将永久删除 Agent '$name'${NC}"
            read -p "输入 'yes' 确认删除: " confirm

            if [[ "$confirm" == "yes" ]]; then
                echo ""
                "$SCRIPT_DIR/cc-agent.sh" remove "$name" || true
            else
                echo "已取消"
            fi
        else
            echo -e "${RED}无效选择${NC}"
        fi
    fi

    echo ""
    echo "按回车键返回菜单..."
    read
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
    read -p "选择操作 (1-3): " choice

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
                sleep 1
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

    echo ""
    echo "按回车键返回菜单..."
    read
}

# 主菜单循环
main_loop() {
    while true; do
        clear_screen
        show_header
        show_menu

        read -p "输入选项 (0-7): " choice

        case "$choice" in
            1) menu_create_agent ;;
            2) menu_start_agent ;;
            3) menu_stop_agent ;;
            4) menu_status ;;
            5) menu_remove_agent ;;
            6)
                clear_screen
                show_header
                echo -e "${BOLD}查看日志${NC}"
                echo ""
                local -a agents=()
                get_agents agents
                if [[ ${#agents[@]} -eq 0 ]]; then
                    echo -e "${YELLOW}没有可用的 Agent${NC}"
                    echo ""
                    echo "按回车键返回菜单..."
                    read
                else
                    for i in "${!agents[@]}"; do
                        printf "  %d) %s\n" "$((i+1))" "${agents[$i]}"
                    done
                    echo ""
                    read -p "选择 Agent (1-${#agents[@]}): " log_choice
                    if [[ "$log_choice" =~ ^[0-9]+$ ]] && [[ $log_choice -ge 1 ]] && [[ $log_choice -le ${#agents[@]} ]]; then
                        local idx=$((log_choice - 1))
                        local name="${agents[$idx]}"
                        local log_file="$LOG_DIR/$name.log"
                        if [[ -f "$log_file" ]]; then
                            echo ""
                            echo "显示 $name 的最近日志 (按 q 退出):"
                            echo "---"
                            tail -50 "$log_file" | less -R
                        else
                            echo -e "${YELLOW}该 Agent 还没有日志${NC}"
                            echo ""
                            echo "按回车键返回菜单..."
                            read
                        fi
                    else
                        echo -e "${RED}无效选择${NC}"
                        echo ""
                        echo "按回车键返回菜单..."
                        read
                    fi
                fi
                ;;
            7) menu_batch ;;
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

# 初始化
check_deps
init_dirs

# 启动主循环
main_loop
