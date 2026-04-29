#!/usr/bin/env bash

# Claude Code 供应商切换脚本
# 用法：~/cc.sh [选项]
#   无参数：交互式选择
#   1-N: 直接选择对应供应商
#   status: 查看当前配置
#   -m <model>: 指定模型（不指定则使用供应商默认模型）

set -e
set -o pipefail

# 安全设置：确保新建文件权限严格
umask 0077

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

# 依赖检查
for cmd in python3; do
  command -v "$cmd" &>/dev/null || {
    echo "错误: 需要安装 $cmd" >&2
    exit 1
  }
done

# Python 版本检查 (需要 3.6+)
if ! python3 -c "import sys; assert sys.version_info >= (3, 6)" 2>/dev/null; then
  echo "错误: Python 版本过低，需要 3.6 或更高版本" >&2
  echo "当前版本: $(python3 --version 2>&1 || echo "未知")" >&2
  exit 1
fi

# 配置目录
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
BACKUP_DIR="$HOME/.claude/backups"
MAX_BACKUPS=10
TEMP_FILES=()

# 全局清理函数
_global_cleanup() {
  for f in "${TEMP_FILES[@]}"; do
    [[ -f "$f" ]] && rm -f "$f"
  done
}

trap _global_cleanup EXIT INT TERM

mkdir -p "$BACKUP_DIR"

# ── 供应商数据 (唯一数据源) ──
# 格式: 编号|名称|URL|Token|模型|haiku模型|sonnet模型|small_fast模型
# haiku/sonnet/small_fast 留空则与主模型相同

# 配置文件路径
API_KEYS_CONF="$(dirname "${BASH_SOURCE[0]}")/api-keys.conf"

# 从配置文件加载供应商数据
PROVIDERS=()
if [[ -f "$API_KEYS_CONF" ]]; then
  while IFS= read -r line; do
    # 跳过空行和注释
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    PROVIDERS+=("$line")
  done < "$API_KEYS_CONF"
else
  echo "错误: 配置文件不存在: $API_KEYS_CONF" >&2
  exit 1
fi

PROVIDER_COUNT=${#PROVIDERS[@]}
CUSTOM_MODEL=""

# ── 从数组解析供应商字段 ──
_parse_provider() {
  local entry="$1"
  IFS='|' read -r P_NUM P_NAME P_URL P_TOKEN P_MODEL P_HAIKU P_SONNET P_SMALL <<< "$entry"
  P_HAIKU="${P_HAIKU:-$P_MODEL}"
  P_SONNET="${P_SONNET:-$P_MODEL}"
  P_SMALL="${P_SMALL:-$P_MODEL}"
}

# ── 读取当前配置 ──
_read_current_config() {
  python3 -c "
import json, sys
try:
  d = json.load(open('$CLAUDE_SETTINGS'))
  env = d.get('env', {})
  print(env.get('ANTHROPIC_BASE_URL', ''), env.get('ANTHROPIC_MODEL', ''))
except Exception as e:
  print('ERROR', str(e), file=sys.stderr)
  sys.exit(1)
" 2>/dev/null
}

# 根据编号查找供应商
_find_provider() {
  local target="$1"
  for entry in "${PROVIDERS[@]}"; do
    IFS='|' read -r num _ <<< "$entry"
    if [[ "$num" == "$target" ]]; then
      echo "$entry"
      return 0
    fi
  done
  return 1
}

# ── gum 辅助函数 ──
_has_gum() {
  command -v gum &>/dev/null
}

_gum_header() {
  local title="$1"
  if _has_gum; then
    gum style --border rounded --border-foreground 99 --padding "0 2" --bold "$title"
  else
    printf "%b╔══════════════════════════════════════════════════╗%b\n" "$CYAN" "$NC"
    printf "%b║  %-46s║%b\n" "$CYAN" "$title" "$NC"
    printf "%b╚══════════════════════════════════════════════════╝%b\n" "$CYAN" "$NC"
  fi
}

_gum_log() {
  local level="$1" msg="$2"
  if _has_gum; then
    gum log --level "$level" "$msg"
  else
    case "$level" in
      info) printf "%b✓ %s%b\n" "$GREEN" "$msg" "$NC" ;;
      warn) printf "%b⚠ %s%b\n" "$YELLOW" "$msg" "$NC" ;;
      error) printf "%b✗ %s%b\n" "$RED" "$msg" "$NC" ;;
      *) echo "$msg" ;;
    esac
  fi
}

# ── 生成 settings.json ──
generate_config() {
  _parse_provider "$1"
  local model="${CUSTOM_MODEL:-$P_MODEL}"
  local haiku_model="$P_HAIKU"
  local sonnet_model="$P_SONNET"
  local small_fast_model="$P_SMALL"

  if [[ -n "$CUSTOM_MODEL" ]]; then
    haiku_model="$CUSTOM_MODEL"
    sonnet_model="$CUSTOM_MODEL"
    small_fast_model="$CUSTOM_MODEL"
  fi

  ANTHROPIC_BASE_URL="$P_URL" \
  ANTHROPIC_AUTH_TOKEN="$P_TOKEN" \
  ANTHROPIC_MODEL="$model" \
  ANTHROPIC_DEFAULT_HAIKU_MODEL="$haiku_model" \
  ANTHROPIC_DEFAULT_SONNET_MODEL="$sonnet_model" \
  ANTHROPIC_DEFAULT_OPUS_MODEL="$model" \
  ANTHROPIC_SMALL_FAST_MODEL="$small_fast_model" \
  python3 -c '
import json
import os
import sys

settings = {
    "env": {
        "ANTHROPIC_BASE_URL": os.environ["ANTHROPIC_BASE_URL"],
        "ANTHROPIC_AUTH_TOKEN": os.environ["ANTHROPIC_AUTH_TOKEN"],
        "ANTHROPIC_MODEL": os.environ["ANTHROPIC_MODEL"],
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": os.environ["ANTHROPIC_DEFAULT_HAIKU_MODEL"],
        "ANTHROPIC_DEFAULT_SONNET_MODEL": os.environ["ANTHROPIC_DEFAULT_SONNET_MODEL"],
        "ANTHROPIC_DEFAULT_OPUS_MODEL": os.environ["ANTHROPIC_DEFAULT_OPUS_MODEL"],
        "ANTHROPIC_SMALL_FAST_MODEL": os.environ["ANTHROPIC_SMALL_FAST_MODEL"],
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    },
    "model": "opus",
    "skipDangerousModePermissionPrompt": True,
}
json.dump(settings, sys.stdout, ensure_ascii=False, indent=2)
sys.stdout.write("\n")
'
}

# ── 显示当前配置 ──
show_status() {
  _gum_header "📊 Claude Code 当前配置"
  echo ""

  if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
    _gum_log error "未找到配置文件 ${CLAUDE_SETTINGS}"
    return 1
  fi

  local current_url current_model
  if ! read -r current_url current_model < <(_read_current_config); then
    _gum_log error "配置文件格式错误或损坏"
    return 1
  fi

  if [[ "$current_url" == "未知" || "$current_url" == "ERROR" ]]; then
    _gum_log warn "配置文件缺少必要字段"
  fi

  # 从数组匹配当前供应商
  local provider_name="未知"
  for entry in "${PROVIDERS[@]}"; do
    _parse_provider "$entry"
    if [[ "$current_url" == "$P_URL" ]]; then
      provider_name="$P_NAME"
      break
    fi
  done

  # 美化输出
  local divider="━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  printf "  %b%s%b\n" "$DIM" "$divider" "$NC"
  printf "  %b配置文件%b   %s\n" "$BLUE" "$NC" "$CLAUDE_SETTINGS"
  printf "  %b供应商%b     %s\n" "$GREEN" "$NC" "$provider_name"
  printf "  %bAPI 端点%b    %s\n" "$CYAN" "$NC" "$current_url"
  printf "  %b模型%b       %s\n" "$YELLOW" "$NC" "$current_model"
  printf "  %b%s%b\n" "$DIM" "$divider" "$NC"
  echo ""
}

# ── 备份 (自动清理旧备份) ──
backup_config() {
  [[ ! -f "$CLAUDE_SETTINGS" ]] && return
  local timestamp=$(date +%Y%m%d_%H%M%S)
  local backup_file="$BACKUP_DIR/settings.json.backup.${timestamp}.$$"
  cp "$CLAUDE_SETTINGS" "$backup_file"
  chmod 600 "$backup_file"
  _gum_log info "配置已备份到：${backup_file}"

  # 只保留最近 N 份备份
  local old_backups=($(ls -1t "$BACKUP_DIR"/settings.json.backup.* 2>/dev/null | tail -n +$((MAX_BACKUPS + 1))))
  for f in "${old_backups[@]}"; do
    rm -f "$f"
  done
}

# ── 切换供应商 ──
switch_provider() {
  local entry
  entry=$(_find_provider "$1") || {
    _gum_log error "无效的选项 $1"
    return 1
  }

  _parse_provider "$entry"
  echo ""
  if [[ -n "$CUSTOM_MODEL" ]]; then
    _gum_log info "正在切换到：${P_NAME} (模型：${CUSTOM_MODEL})"
  else
    _gum_log info "正在切换到：${P_NAME}"
  fi
  echo ""

  backup_config
  local tmp_config
  tmp_config=$(mktemp) || { _gum_log error "无法创建临时文件"; return 1; }
  TEMP_FILES+=("$tmp_config")

  if ! generate_config "$entry" > "$tmp_config" || ! mv "$tmp_config" "$CLAUDE_SETTINGS"; then
    _gum_log error "配置写入失败，正在恢复备份..."
    local latest_backup
    latest_backup=$(ls -1t "$BACKUP_DIR"/settings.json.backup.* 2>/dev/null | head -1)
    if [[ -n "$latest_backup" ]]; then
      cp "$latest_backup" "$CLAUDE_SETTINGS"
      chmod 600 "$CLAUDE_SETTINGS"
      _gum_log info "已恢复到之前的配置"
    fi
    return 1
  fi
  # 确保权限严格：只有所有者可读写
  chmod 600 "$CLAUDE_SETTINGS"

  _gum_log info "✓ 配置已更新!"
  echo ""
  show_status

  _gum_log info "正在启动 Claude Code..."
  echo ""
  exec claude --dangerously-skip-permissions
}

# ── 动态菜单 ──
_provider_category() {
  local name="$1"
  if [[ "$name" == newcli/* ]]; then
    PROVIDER_CATEGORY="foxcode"
  elif [[ "$name" == *"Kimi"* || "$name" == *"阿里云"* || "$name" == *"火山方舟"* || "$name" == *"DeepSeek"* ]]; then
    PROVIDER_CATEGORY="domestic"
  else
    PROVIDER_CATEGORY="other"
  fi
}

_print_provider_menu_item() {
  local current_url="$1"
  if [[ "$current_url" == "$P_URL" ]]; then
    printf "    %b[%s] %s ● 当前%b\n" "$RED" "$P_NUM" "$P_NAME" "$NC"
  else
    printf "    [%s] %s\n" "$P_NUM" "$P_NAME"
  fi
}

_render_provider_group() {
  local category="$1"
  local title="$2"
  local suffix="$3"
  local current_url="$4"
  local entry

  printf "  %b▸ %s%b%s\n" "$BLUE" "$title" "$NC" "$suffix"
  for entry in "${PROVIDERS[@]}"; do
    _parse_provider "$entry"
    _provider_category "$P_NAME"
    [[ "$PROVIDER_CATEGORY" == "$category" ]] || continue
    _print_provider_menu_item "$current_url"
  done
  echo ""
}

show_menu() {
  # 获取当前供应商 URL
  local current_url=""
  if ! read -r current_url _ < <(_read_current_config); then
    current_url=""
  fi

  local divider=$(printf "%b────────────────────────────────────────────────────────────────────────────────%b" "$DIM" "$NC")

  _gum_header "🔧 Claude Code 供应商切换工具"
  echo ""
  printf "  %b说明:%b 输入编号切换供应商，e 编辑 API Key，q 退出\n" "$DIM" "$NC"
  echo ""

  # 分类显示供应商
  printf "%b【分类选择】%b\n" "$CYAN" "$NC"
  echo ""

  _render_provider_group "foxcode" "FoxCode 中转" " (newcli, 共用 token)" "$current_url"
  _render_provider_group "domestic" "国内模型" " (Kimi / Qwen / 火山 / DeepSeek)" "$current_url"
  _render_provider_group "other" "其它供应商" "" "$current_url"

  echo "$divider"
  echo ""
  printf "  %b【功能选项】%b\n" "$CYAN" "$NC"
  echo ""
  printf "    %be%b) ✏️ 编辑 API Key        %bq%b) 退出\n" "$YELLOW" "$NC" "$RED" "$NC"
  printf "    %b[↵]%b 使用当前配置重启\n" "$DIM" "$NC"
  echo ""
}

# ── 模型选择菜单 ──
_model_options_for_provider() {
  local provider_name="$1"

  if [[ "$provider_name" == *"Kimi"* ]]; then
    cat <<'EOF'
kimi-k2.5|kimi-k2.5|Kimi 只支持此模型
EOF
  elif [[ "$provider_name" == *"DeepSeek"* ]]; then
    cat <<'EOF'
deepseek-v4-pro|deepseek-v4-pro|专业版
deepseek-v4-flash|deepseek-v4-flash|快速版
EOF
  elif [[ "$provider_name" == *"火山方舟"* ]]; then
    cat <<'EOF'
ark-code-latest|ark-code-latest|最新代码专用
doubao-seed-2.0-code|doubao-seed-2.0-code|豆码 代码专用
doubao-seed-2.0-pro|doubao-seed-2.0-pro|豆码 专业版
doubao-seed-2.0-lite|doubao-seed-2.0-lite|豆码 轻量版
doubao-seed-code|doubao-seed-code|豆码 旧版
minimax-m2.5|minimax-m2.5|MiniMax
glm-4.7|glm-4.7|智谱 GLM
deepseek-v3.2|deepseek-v3.2|DeepSeek
kimi-k2.5|kimi-k2.5|Kimi
EOF
  elif [[ "$provider_name" == newcli/codex* ]]; then
    cat <<'EOF'
gpt-5.5|gpt-5.5|最强
gpt-5.4|gpt-5.4|均衡
gpt-5.3-codex|gpt-5.3-codex|代码专用
gpt-5.2|gpt-5.2|快速
EOF
  elif [[ "$provider_name" == newcli/aws* ]]; then
    cat <<'EOF'
claude-sonnet-4-5|claude-sonnet-4-5|Sonnet 4.5
claude-sonnet-4-5-20250929|claude-sonnet-4-5-20250929|Sonnet 4.5 快照
claude-sonnet-4-5-thinking|claude-sonnet-4-5-thinking|Sonnet 4.5 思考
claude-sonnet-4-5-20250929-thinking|claude-sonnet-4-5-20250929-thinking|快照+思考
claude-haiku-4-5-20251001|claude-haiku-4-5-20251001|Haiku 4.5
claude-sonnet-4-20250514|claude-sonnet-4-20250514|Sonnet 4
EOF
  elif [[ "$provider_name" == newcli/* ]]; then
    cat <<'EOF'
claude-opus-4-6|claude-opus-4-6|最强
claude-sonnet-4-6|claude-sonnet-4-6|均衡
claude-haiku-4-5-20251001|claude-haiku-4-5-20251001|快速，支持 thinking
EOF
  elif [[ "$provider_name" == *"PuCode"* || "$provider_name" == *"LinkAPI"* ]]; then
    cat <<'EOF'
gpt-5.5|gpt-5.5|GPT 主模型
gpt-5.3-codex|gpt-5.3-codex|GPT 代码专用
gpt-5-mini|gpt-5-mini|GPT 快速
gpt-5.4|gpt-5.4|GPT 兼容
gpt-5.2|gpt-5.2|GPT 均衡
EOF
  else
    cat <<'EOF'
claude-opus-4-6|claude-opus-4-6|最强
claude-sonnet-4-6|claude-sonnet-4-6|均衡
claude-haiku-4-5-20251001|claude-haiku-4-5|快速
gpt-5.4|gpt-5.4|GPT 主模型
gpt-5.2|gpt-5.2|GPT 均衡
gpt-5-mini|gpt-5-mini|GPT 快速
qwen3.5-plus|qwen3.5-plus|通义千问
kimi-k2.5|kimi-k2.5|Kimi
EOF
  fi
}

_choose_model() {
  local provider_name="$1"
  local default_model="$2"
  local manual_key="${3:-}"
  local values=() labels=() descriptions=()
  local value label description count=0 seen_default=0

  while IFS='|' read -r value label description; do
    [[ -z "$value" ]] && continue
    [[ "$value" == "$default_model" ]] && seen_default=1
    values[$count]="$value"
    labels[$count]="$label"
    descriptions[$count]="$description"
    count=$((count + 1))
  done < <(_model_options_for_provider "$provider_name")

  if [[ $seen_default -eq 0 ]]; then
    values[$count]="$default_model"
    labels[$count]="$default_model"
    descriptions[$count]="供应商默认"
    count=$((count + 1))
  fi

  [[ -z "$manual_key" ]] && manual_key=$((count + 1))

  local i=0 marker line
  while [[ $i -lt $count ]]; do
    marker=""
    [[ "${values[$i]}" == "$default_model" ]] && marker=" ● 当前"
    line=$(printf "    %d) %-28s (%s)%s" "$((i + 1))" "${labels[$i]}" "${descriptions[$i]}" "$marker")
    if [[ -n "$marker" ]]; then
      printf "%b%s%b\n" "$RED" "$line" "$NC"
    else
      printf "%s\n" "$line"
    fi
    i=$((i + 1))
  done
  echo "    ${manual_key}) 手动输入模型名称"
  echo "    b) 返回主菜单"
  echo ""

  local range="1-${count}"
  if [[ "$manual_key" == "0" ]]; then
    range="${range}/0"
  else
    range="1-${manual_key}"
  fi

  local model_choice
  read -r -p "  输入选项 (${range}/b/↵): " model_choice

  case "$model_choice" in
    b|B)
      printf "%b已取消%b\n" "$YELLOW" "$NC"
      echo ""
      return 1
      ;;
    "")
      CUSTOM_MODEL=""
      ;;
    "$manual_key")
      read -r -p "请输入模型名称： " CUSTOM_MODEL
      ;;
    *)
      if [[ "$model_choice" =~ ^[0-9]+$ ]] && [[ "$model_choice" -ge 1 ]] && [[ "$model_choice" -le "$count" ]]; then
        CUSTOM_MODEL="${values[$((model_choice - 1))]}"
      else
        printf "%b无效选项，使用默认模型%b\n" "$YELLOW" "$NC"
        CUSTOM_MODEL=""
      fi
      ;;
  esac
}

ask_for_model() {
  local provider_num="$1"
  local provider_name="$2"
  local entry
  entry=$(_find_provider "$provider_num") || return 1
  _parse_provider "$entry"
  local default_model="$P_MODEL"

  echo ""
  printf "%b┌─────────────────────────────────────────────────────┐%b\n" "$CYAN" "$NC"
  printf "%b│  供应商：%s%b\n" "$BLUE" "$provider_name" "$NC"
  printf "%b└─────────────────────────────────────────────────────┘%b\n" "$CYAN" "$NC"
  echo ""

  printf "  请选择模型 %b[默认：%s]%b:\n" "$DIM" "$default_model" "$NC"
  echo ""

  local manual_key=""
  [[ "$provider_name" == *"火山方舟"* ]] && manual_key="0"
  _choose_model "$provider_name" "$default_model" "$manual_key" || return 1

  if [[ -n "$CUSTOM_MODEL" ]]; then
    printf "使用模型：%b%s%b\n" "$GREEN" "$CUSTOM_MODEL" "$NC"
  else
    printf "使用默认模型：%b%s%b\n" "$GREEN" "$default_model" "$NC"
  fi
  echo ""
}

# ── 编辑供应商 Token ──
_mask_token() {
  local token="$1"
  local len=${#token}
  if [[ $len -le 16 ]]; then
    printf "%s" "********"
  else
    printf "%s...%s" "${token:0:8}" "${token: -8}"
  fi
}

edit_provider_token() {
  echo ""
  _gum_header "✏️ 编辑供应商 API Key"
  echo ""

  # 列出所有供应商供选择
  for entry in "${PROVIDERS[@]}"; do
    _parse_provider "$entry"
    printf "  [%s] %s\n" "$P_NUM" "$P_NAME"
  done
  echo ""

  read -r -p "请输入要编辑的供应商编号: " edit_num

  local target_entry
  target_entry=$(_find_provider "$edit_num") || {
    _gum_log error "无效的供应商编号"
    echo ""
    return 1
  }

  _parse_provider "$target_entry"

  echo ""
  echo " 当前供应商: $P_NAME"
  echo " 当前 API Key: $(_mask_token "$P_TOKEN")"
  echo ""
  read -r -p "请输入新的 API Key: " new_token

  if [[ -z "$new_token" ]]; then
    _gum_log error "API Key 不能为空"
    echo ""
    return 1
  fi
  if [[ "$new_token" == *$'\n'* || "$new_token" == *$'\r'* || "$new_token" == *"|"* ]]; then
    _gum_log error "API Key 不能包含换行或 | 字符"
    echo ""
    return 1
  fi

  local tmp_conf
  tmp_conf=$(mktemp) || { _gum_log error "无法创建临时文件"; return 1; }
  TEMP_FILES+=("$tmp_conf")

  if EDIT_NUM="$edit_num" NEW_TOKEN="$new_token" API_KEYS_CONF="$API_KEYS_CONF" python3 - "$tmp_conf" <<'PY'
import os
import sys

src = os.environ["API_KEYS_CONF"]
target = os.environ["EDIT_NUM"]
new_token = os.environ["NEW_TOKEN"]
dst = sys.argv[1]
updated = False

with open(src, "r", encoding="utf-8") as fh, open(dst, "w", encoding="utf-8") as out:
    for line in fh:
        raw = line.rstrip("\n")
        newline = "\n" if line.endswith("\n") else ""
        if raw and not raw.lstrip().startswith("#"):
            parts = raw.split("|")
            if parts and parts[0] == target:
                if len(parts) < 4:
                    raise SystemExit("目标供应商配置格式错误")
                parts[3] = new_token
                raw = "|".join(parts)
                updated = True
        out.write(raw + newline)

if not updated:
    raise SystemExit("未找到目标供应商")
PY
  then
    if ! mv "$tmp_conf" "$API_KEYS_CONF"; then
      rm -f "$tmp_conf"
      _gum_log error "修改失败，请手动编辑配置文件"
      echo ""
      return 1
    fi
    _gum_log info "✓ API Key 更新成功！需要重新加载脚本生效"
    echo ""
    echo "修改已写入: $API_KEYS_CONF"
    echo "下次运行脚本将使用新的 API Key"
    echo ""
  else
    rm -f "$tmp_conf"
    _gum_log error "修改失败，请手动编辑配置文件"
    echo ""
  fi
}

# ── 显示帮助 (动态生成) ──
show_help() {
  echo "Claude Code 供应商切换脚本"
  echo ""
  echo "用法:"
  echo "  ~/cc.sh           # 交互式菜单"
  echo "  ~/cc.sh e         # 编辑供应商 API Key"
  for entry in "${PROVIDERS[@]}"; do
    _parse_provider "$entry"
    printf "  ~/cc.sh %-10s # 切换到 %s\n" "$P_NUM" "$P_NAME"
  done
  echo "  ~/cc.sh status    # 查看当前配置"
  echo "  ~/cc.sh -m <model>   # 指定模型 (不指定则使用供应商默认模型)"
  echo ""
  echo "示例:"
  echo "  ~/cc.sh 1 -m claude-sonnet-4-6   # 使用供应商 1，指定 sonnet 模型"
  echo "  ~/cc.sh e                         # 交互式编辑 API Key"
  echo "  ~/cc.sh 6 -m qwen3.5-plus        # 使用供应商 6，指定通义千问模型"
  echo "  ~/cc.sh 9 -m gpt-5.4             # 使用供应商 9，指定 GPT-5.4 模型"
  echo ""
}

# ── 主函数 ──
main() {
  trap '_global_cleanup' EXIT INT TERM

  local entry
  local positional=()

  # 解析参数，支持 -m 出现在任意位置
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m|--model)
        if [[ -n "$2" && "$2" != -* ]]; then
          CUSTOM_MODEL="$2"
          shift 2
        else
          _gum_log error "-m/--model 需要传入模型名称"
          exit 1
        fi
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  set -- "${positional[@]}"

  case "${1:-}" in
    ""|menu)
      show_status
      while true; do
        show_menu
        read -r -p "请输入选项 (1-${PROVIDER_COUNT}/e/q/↵): " choice
        case "$choice" in
          [1-9]|[1-9][0-9])
            if [[ -z "$CUSTOM_MODEL" && -t 0 ]]; then
              entry=$(_find_provider "$choice") || {
                _gum_log error "无效的选项 $choice"
                continue
              }
              _parse_provider "$entry"
              ask_for_model "$choice" "$P_NAME" || continue
            fi
            switch_provider "$choice"
            break
            ;;
          e|edit|edit-key)
            edit_provider_token
            ;;
          q|quit) echo "退出"; exit 0 ;;
          "")
            # 直接↵：使用当前配置的供应商，沿用上次模型
            local current_url current_model
            read -r current_url current_model < <(_read_current_config)
            if [[ -n "$current_url" && "$current_url" != "ERROR" ]]; then
              local current_num=""
              for entry in "${PROVIDERS[@]}"; do
                _parse_provider "$entry"
                if [[ "$current_url" == "$P_URL" ]]; then
                  current_num="$P_NUM"
                  break
                fi
              done
              if [[ -n "$current_num" ]]; then
                # 设置 CUSTOM_MODEL 为当前模型，这样 generate_config 会使用它
                CUSTOM_MODEL="$current_model"
                _gum_log info "使用当前供应商：$current_num (模型：$current_model)"
                switch_provider "$current_num"
                break
              else
                _gum_log warn "未找到当前 URL 对应的供应商"
              fi
            else
              _gum_log error "无法读取当前配置"
            fi
            ;;
          *) _gum_log error "无效选项" ;;
        esac
      done
      ;;
    [1-9]|1[0-9]|[2-9][0-9])
      switch_provider "$1"
      ;;
    edit|e|edit-key)
      edit_provider_token
      ;;
    status|s)
      show_status
      ;;
    help|-h|--help)
      show_help
      ;;
    *)
      _gum_log error "未知选项：$1"
      echo "运行 ~/cc.sh help 查看用法"
      exit 1
      ;;
  esac
}

main "$@"
