#!/usr/bin/env bash
#
# Claude Code 多 Agent 管理脚本
# 支持同时运行多个 Agent，每个使用不同的厂商/API
#
# 用法:
#   ./cc-agent.sh create <name> <vendor_num> [model]  # 创建新 Agent
#   ./cc-agent.sh start <name>                        # 启动 Agent
#   ./cc-agent.sh stop <name>                         # 停止 Agent
#   ./cc-agent.sh status                              # 查看所有 Agent 状态
#   ./cc-agent.sh list                                # 列出所有 Agent
#   ./cc-agent.sh remove <name>                       # 删除 Agent
#   ./cc-agent.sh log <name>                          # 查看 Agent 日志

set -e
set -o pipefail

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
NC='\e[0m'

# 设置脚本目录
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# 初始化目录
init_dirs() {
    mkdir -p "$AGENTS_DIR" "$PID_DIR" "$LOG_DIR"
}

# 从 cc.sh 获取供应商信息
get_vendor_info() {
    local num="$1"
    # 从 cc.sh 读取供应商数据
    local cc_script="${SCRIPT_DIR}/cc.sh"
    [[ ! -f "$cc_script" ]] && cc_script="$HOME/cc.sh"
    [[ ! -f "$cc_script" ]] && cc_script="./cc.sh"
    grep -E "^[[:space:]]*\"$num\|" "$cc_script" 2>/dev/null | head -1
}

# 生成唯一的 Session ID
generate_session_id() {
    local agent_name="$1"
    local timestamp=$(date +%s)
    local random=$(openssl rand -hex 4 2>/dev/null || echo "$RANDOM$RANDOM")
    echo "${agent_name}-${timestamp}-${random}"
}

# 创建 Agent 配置
create_agent() {
    local name="$1"
    local vendor_num="$2"
    local custom_model="${3:-}"

    if [[ -z "$name" || -z "$vendor_num" ]]; then
        echo "用法: $0 create <name> <vendor_num> [model]"
        exit 1
    fi

    # 检查名称是否已存在
    if [[ -f "$AGENTS_DIR/$name.json" ]]; then
        echo -e "${RED}错误: Agent '$name' 已存在${NC}"
        exit 1
    fi

    # 从 cc.sh 获取供应商配置
    local vendor_line
    vendor_line=$(get_vendor_info "$vendor_num" 2>/dev/null || true)

    if [[ -z "$vendor_line" ]]; then
        echo -e "${RED}错误: 找不到供应商编号 $vendor_num${NC}"
        exit 1
    fi

    # 解析供应商数据
    # 格式: "编号|名称|URL|Token|模型|..."
    local v_num v_name v_url v_token v_model
    v_num=$(echo "$vendor_line" | grep -oE '[0-9]+' | head -1)
    v_name=$(echo "$vendor_line" | cut -d'|' -f2 | tr -d '"')
    v_url=$(echo "$vendor_line" | cut -d'|' -f3 | tr -d '"')
    v_token=$(echo "$vendor_line" | cut -d'|' -f4 | tr -d '"')
    v_model=$(echo "$vendor_line" | cut -d'|' -f5 | tr -d '"')

    # 使用自定义模型或默认模型
    local final_model="${custom_model:-$v_model}"
    [[ -z "$final_model" ]] && final_model="claude-opus-4-6"

    # 生成配置文件
    cat > "$AGENTS_DIR/$name.json" << EOF
{
  "name": "$name",
  "vendor": {
    "num": "$v_num",
    "name": "$v_name",
    "url": "$v_url",
    "token": "$v_token",
    "default_model": "$v_model"
  },
  "model": "$final_model",
  "created_at": "$(date -Iseconds)",
  "settings": {
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "CLAUDE_CODE_SKIP_PERMISSIONS": "true"
  }
}
EOF

    echo -e "${GREEN}✓ Agent '$name' 创建成功${NC}"
    echo "  供应商: $v_name"
    echo "  模型: $final_model"
    echo "  配置: $AGENTS_DIR/$name.json"
    echo ""
    echo "启动命令: $0 start $name"
}

# 生成 Agent 的 settings.json
generate_agent_settings() {
    local name="$1"
    local config_file="$AGENTS_DIR/$name.json"

    if [[ ! -f "$config_file" ]]; then
        echo "错误: Agent '$name' 不存在" >&2
        return 1
    fi

    # 使用 Python 解析 JSON 并生成 settings
    python3 << EOF
import json

with open("$config_file") as f:
    config = json.load(f)

vendor = config["vendor"]
model = config["model"]

settings = {
    "env": {
        "ANTHROPIC_BASE_URL": vendor["url"],
        "ANTHROPIC_AUTH_TOKEN": vendor["token"],
        "ANTHROPIC_MODEL": model,
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": vendor.get("default_model", model),
        "ANTHROPIC_DEFAULT_SONNET_MODEL": vendor.get("default_model", model),
        "ANTHROPIC_DEFAULT_OPUS_MODEL": model,
        "ANTHROPIC_SMALL_FAST_MODEL": vendor.get("default_model", model),
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
    },
    "model": "opus",
    "skipDangerousModePermissionPrompt": True
}

print(json.dumps(settings, indent=2))
EOF
}

# 启动 Agent (前台交互式)
start_agent() {
    local name="$1"

    if [[ -z "$name" ]]; then
        echo "用法: $0 start <name>"
        exit 1
    fi

    local config_file="$AGENTS_DIR/$name.json"
    if [[ ! -f "$config_file" ]]; then
        echo -e "${RED}错误: Agent '$name' 不存在${NC}"
        exit 1
    fi

    # 检查是否已在运行
    local pid_file="$PID_DIR/$name.pid"
    if [[ -f "$pid_file" ]]; then
        local old_pid=$(cat "$pid_file" 2>/dev/null)
        if kill -0 "$old_pid" 2>/dev/null; then
            echo -e "${YELLOW}警告: Agent '$name' 已经在运行 (PID: $old_pid)${NC}"
            echo "如果确认没运行，请删除: rm $pid_file"
            return 1
        fi
    fi

    # 生成临时配置文件
    local tmp_config=$(mktemp)
    generate_agent_settings "$name" > "$tmp_config"

    # 生成唯一的 session ID
    local session_id=$(generate_session_id "$name")

    # 清理函数 - 退出时删除临时文件和 PID
    cleanup() {
        [[ -f "$tmp_config" ]] && rm -f "$tmp_config"
        [[ -f "$pid_file" ]] && rm -f "$pid_file"
    }
    trap cleanup EXIT INT TERM

    # 保存当前 PID
    echo "$$" > "$pid_file"

    # 获取供应商信息用于显示
    local vendor_name
    vendor_name=$(python3 -c "
import json
try:
    with open('$config_file') as f:
        c = json.load(f)
    print(c['vendor']['name'])
except:
    print('未知')
" 2>/dev/null)

    local model_name
    model_name=$(python3 -c "
import json
try:
    with open('$config_file') as f:
        c = json.load(f)
    print(c['model'])
except:
    print('未知')
" 2>/dev/null)

    echo -e "${BLUE}╔═════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  Starting Agent: $name${NC}"
    echo -e "${BLUE}╚═════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  供应商: $vendor_name"
    echo "  模型: $model_name"
    echo "  配置文件: $config_file"
    echo "  临时settings: $tmp_config"
    echo ""
    echo "➜  Claude Code 启动中..."
    echo ""

    # 清除可能冲突的环境变量，确保使用我们生成的配置
    unset ANTHROPIC_BASE_URL
    unset ANTHROPIC_AUTH_TOKEN
    unset ANTHROPIC_MODEL
    unset ANTHROPIC_DEFAULT_HAIKU_MODEL
    unset ANTHROPIC_DEFAULT_SONNET_MODEL
    unset ANTHROPIC_DEFAULT_OPUS_MODEL
    unset ANTHROPIC_SMALL_FAST_MODEL

    # 前台直接启动，交互式
    export CLAUDE_SETTINGS="$tmp_config"
    export CLAUDE_CODE_AGENT_NAME="$name"
    export CLAUDE_CODE_SESSION_ID="$session_id"

    # 直接 exec 替换当前进程
    exec claude --dangerously-skip-permissions
}

# 停止 Agent
stop_agent() {
    local name="$1"

    if [[ -z "$name" ]]; then
        echo "用法: $0 stop <name>"
        exit 1
    fi

    local pid_file="$PID_DIR/$name.pid"
    if [[ ! -f "$pid_file" ]]; then
        echo -e "${YELLOW}警告: Agent '$name' 没有在运行${NC}"
        return 1
    fi

    local pid=$(cat "$pid_file")
    if ! kill -0 "$pid" 2>/dev/null; then
        echo -e "${YELLOW}警告: Agent '$name' 进程已不存在${NC}"
        rm -f "$pid_file"
        return 1
    fi

    echo "停止 Agent '$name' (PID: $pid)..."

    # 先尝试优雅停止
    kill "$pid" 2>/dev/null
    local count=0
    while kill -0 "$pid" 2>/dev/null && [[ $count -lt 10 ]]; do
        sleep 0.5
        ((count++))
    done

    # 如果还在运行，强制停止
    if kill -0 "$pid" 2>/dev/null; then
        echo "强制停止..."
        kill -9 "$pid" 2>/dev/null
        sleep 0.5
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        echo -e "${GREEN}✓ Agent '$name' 已停止${NC}"
        rm -f "$pid_file"
    else
        echo -e "${RED}✗ 无法停止 Agent '$name'${NC}"
        return 1
    fi
}

# 查看 Agent 状态
show_status() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Claude Code Multi-Agent 状态${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # 显示所有 Agent
    local count=0
    local running=0
    for config_file in $AGENTS_DIR/*.json; do
        [[ -f "$config_file" ]] || continue
        local name=$(basename "$config_file" .json)
        local pid_file="$PID_DIR/$name.pid"
        local log_file="$LOG_DIR/$name.log"

        echo -e "${BLUE}Agent: $name${NC}"

        # 检查运行状态
        if [[ -f "$pid_file" ]]; then
            local pid=$(cat "$pid_file" 2>/dev/null)
            if kill -0 "$pid" 2>/dev/null; then
                echo -e "  状态: ${GREEN}运行中${NC} (PID: $pid)"
                ((running++))
            else
                echo -e "  状态: ${RED}已停止${NC} (PID 文件残留)"
            fi
        else
            echo -e "  状态: ${YELLOW}未启动${NC}"
        fi

        # 显示配置信息 - 使用 python 可靠提取，不会出错
        {
        python3 - << EOF
import json
try:
    with open('$config_file') as f:
        c = json.load(f)
    v = c['vendor']
    print('  供应商: ' + v['name'])
    print('  模型: ' + c['model'])
except:
    pass
EOF
        exit 0
        } < /dev/null 2>/dev/null || true

        echo "  日志: $log_file"
        echo ""
        : $((count++))
    done

    if [[ $count -eq 0 ]]; then
        echo -e "${YELLOW}还没有创建任何 Agent${NC}"
        echo ""
        echo "创建 Agent:"
        echo "  $0 create agent1 1"
        echo "  $0 create agent2 5 claude-sonnet-4-6"
        echo ""
    fi

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo "  总计: $count 个 Agent, $running 个正在运行"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    true
}

# 列出所有 Agent
list_agents() {
    echo ""
    echo "已创建的 Agents:"
    echo ""

    for config_file in $AGENTS_DIR/*.json; do
        [[ -f "$config_file" ]] || continue
        local name=$(basename "$config_file" .json)
        echo "  - $name"
    done

    echo ""
}

# 删除 Agent
remove_agent() {
    local name="$1"

    if [[ -z "$name" ]]; then
        echo "用法: $0 remove <name>"
        exit 1
    fi

    local config_file="$AGENTS_DIR/$name.json"
    if [[ ! -f "$config_file" ]]; then
        echo -e "${RED}错误: Agent '$name' 不存在${NC}"
        exit 1
    fi

    # 如果正在运行，先停止
    local pid_file="$PID_DIR/$name.pid"
    if [[ -f "$pid_file" ]]; then
        local pid=$(cat "$pid_file" 2>/dev/null)
        if kill -0 "$pid" 2>/dev/null; then
            echo "停止运行中的 Agent '$name'..."
            stop_agent "$name"
        fi
    fi

    # 删除文件
    rm -f "$config_file"
    rm -f "$pid_file"
    rm -f "$LOG_DIR/$name.log"

    echo -e "${GREEN}✓ Agent '$name' 已删除${NC}"
}

# 查看日志
show_log() {
    local name="$1"

    if [[ -z "$name" ]]; then
        echo "用法: $0 log <name>"
        exit 1
    fi

    local log_file="$LOG_DIR/$name.log"
    if [[ ! -f "$log_file" ]]; then
        echo -e "${RED}错误: Agent '$name' 的日志不存在${NC}"
        exit 1
    fi

    echo "显示 $name 的日志 (按 Ctrl+C 退出)..."
    echo ""
    tail -f "$log_file"
}

# 显示帮助
show_help() {
    cat << 'EOF'
Claude Code Multi-Agent 管理工具

用法:
  ./cc-agent.sh create <name> <vendor_num> [model]  创建新 Agent
  ./cc-agent.sh start <name>                          启动 Agent
  ./cc-agent.sh stop <name>                           停止 Agent
  ./cc-agent.sh restart <name>                       重启 Agent
  ./cc-agent.sh status                                查看所有 Agent 状态
  ./cc-agent.sh list                                  列出所有 Agent
  ./cc-agent.sh remove <name>                         删除 Agent
  ./cc-agent.sh log <name>                            查看 Agent 日志
  ./cc-agent.sh help                                  显示帮助

示例:
  # 创建两个使用不同供应商的 Agent
  ./cc-agent.sh create agent1 1                    # 使用供应商 1
  ./cc-agent.sh create agent2 5 claude-sonnet-4-6    # 使用供应商 5，指定模型

  # 同时启动
  ./cc-agent.sh start agent1
  ./cc-agent.sh start agent2

  # 查看状态
  ./cc-agent.sh status

说明:
  - 每个 Agent 使用独立的配置和 API 密钥
  - Agent 在后台运行，日志保存在 ~/.claude/agents/logs/
  - 可以同时运行多个 Agent，处理不同的任务
EOF
}

# ── 主函数 ──
main() {
    # 初始化目录
    init_dirs

    case "${1:-}" in
        create)
            shift
            create_agent "$@"
            ;;
        start)
            shift
            start_agent "$@"
            ;;
        stop)
            shift
            stop_agent "$@"
            ;;
        restart)
            shift
            stop_agent "$@" 2>/dev/null || true
            sleep 1
            start_agent "$@"
            ;;
        status)
            show_status
            ;;
        list|ls)
            list_agents
            ;;
        remove|rm)
            shift
            remove_agent "$@"
            ;;
        log|logs)
            shift
            show_log "$@"
            ;;
        help|-h|--help)
            show_help
            ;;
        *)
            echo "未知命令: ${1:-}"
            echo "运行 './cc-agent.sh help' 查看用法"
            exit 1
            ;;
    esac
}

main "$@"
