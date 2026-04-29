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
  return 0
}

trap _global_cleanup EXIT INT TERM

mkdir -p "$BACKUP_DIR"

# ── 供应商数据 (唯一数据源) ──
# 格式: 编号|名称|URL|Token|默认模型|haiku模型|sonnet模型|small_fast模型|可选模型列表
# haiku/sonnet/small_fast 留空则与默认模型相同
# 可选模型列表用逗号分隔，单项格式：模型[:说明]

# 配置文件路径
API_KEYS_CONF="$(dirname "${BASH_SOURCE[0]}")/api-keys.conf"

# 从配置文件加载供应商数据
PROVIDERS=()
_reload_providers() {
  local line
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
}

_reload_providers
CUSTOM_MODEL=""

# ── 从数组解析供应商字段 ──
_parse_provider() {
  local entry="$1"
  IFS='|' read -r P_NUM P_NAME P_URL P_TOKEN P_MODEL P_HAIKU P_SONNET P_SMALL P_MODEL_OPTIONS <<< "$entry"
  P_HAIKU="${P_HAIKU:-$P_MODEL}"
  P_SONNET="${P_SONNET:-$P_MODEL}"
  P_SMALL="${P_SMALL:-$P_MODEL}"
  P_MODEL_OPTIONS="${P_MODEL_OPTIONS:-$P_MODEL}"
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

# ── 输出辅助函数 ──
_gum_log() {
  local level="$1" msg="$2"
  case "$level" in
    info) printf "%b✓ %s%b\n" "$GREEN" "$msg" "$NC" ;;
    warn) printf "%b⚠ %s%b\n" "$YELLOW" "$msg" "$NC" ;;
    error) printf "%b✗ %s%b\n" "$RED" "$msg" "$NC" ;;
    *) echo "$msg" ;;
  esac
}

_read_or_quit() {
  local var_name="$1" prompt="$2" silent="${3:-}"
  local input_value
  if [[ "$silent" == "silent" ]]; then
    read -r -s -p "$prompt" input_value
    echo ""
  else
    read -r -p "$prompt" input_value
  fi
  if [[ "$input_value" == "q" || "$input_value" == "Q" ]]; then
    if [[ "${MENU_ROOT:-0}" == "1" ]]; then
      echo "退出"
      exit 0
    fi
    _gum_log warn "已取消"
    return 1
  fi
  printf -v "$var_name" "%s" "$input_value"
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
  printf "%b📊 Claude Code 当前配置%b\n" "$CYAN" "$NC"
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

  _gum_log info "正在启动 Claude Code..."
  echo ""
  exec claude --dangerously-skip-permissions
}

# ── 动态菜单 ──
show_menu() {
  # 获取当前供应商 URL
  local current_url=""
  if ! read -r current_url _ < <(_read_current_config); then
    current_url=""
  fi

  printf "%b【供应商】%b\n" "$CYAN" "$NC"
  echo ""

  for entry in "${PROVIDERS[@]}"; do
    _parse_provider "$entry"
    if [[ "$current_url" == "$P_URL" ]]; then
      printf "    %b[%s] %s ● 当前%b\n" "$RED" "$P_NUM" "$P_NAME" "$NC"
    else
      printf "    [%s] %s\n" "$P_NUM" "$P_NAME"
    fi
  done
  echo ""
}

show_menu_help() {
  printf "%b帮助%b\n\n" "$CYAN" "$NC"
  echo "  编号       选择供应商并进入模型选择"
  echo "  回车       使用当前供应商和模型启动 Claude Code"
  echo "  e          编辑供应商 API Key"
  echo "  c          打开供应商/模型配置管理"
  echo "  q          退出"
  echo "  ? / h      显示帮助"
  echo ""
}

# ── 模型选择菜单 ──
_trim() {
  local value="$1"
  value="${value%$'\r'}"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf "%s" "$value"
}

_emit_model_options() {
  local options="$1"
  local default_model="$2"
  local item value description

  options="${options:-$default_model}"
  while [[ -n "$options" ]]; do
    item="${options%%,*}"
    if [[ "$options" == *,* ]]; then
      options="${options#*,}"
    else
      options=""
    fi

    item=$(_trim "$item")
    [[ -z "$item" ]] && continue

    if [[ "$item" == *:* ]]; then
      value=$(_trim "${item%%:*}")
      description=$(_trim "${item#*:}")
    else
      value="$item"
      description="可选"
    fi
    printf "%s|%s|%s\n" "$value" "$value" "$description"
  done
}

_choose_model() {
  local default_model="$1"
  local model_options="$2"
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
  done < <(_emit_model_options "$model_options" "$default_model")

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
  echo ""

  local range="1-${count}"
  if [[ "$manual_key" == "0" ]]; then
    range="${range}/0"
  else
    range="1-${manual_key}"
  fi

  local model_choice
  _read_or_quit model_choice "  输入选项: " || return 1

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
      _read_or_quit CUSTOM_MODEL "请输入模型名称（q 返回）： " || return 1
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

  printf "  请选择模型:\n"
  echo ""

  local manual_key=""
  [[ "$provider_name" == *"火山方舟"* ]] && manual_key="0"
  _choose_model "$default_model" "$P_MODEL_OPTIONS" "$manual_key" || return 1

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
  printf "%b✏️ 编辑供应商 API Key%b\n" "$CYAN" "$NC"
  echo ""

  # 列出所有供应商供选择
  for entry in "${PROVIDERS[@]}"; do
    _parse_provider "$entry"
    printf "  [%s] %s\n" "$P_NUM" "$P_NAME"
  done
  echo ""

  _read_or_quit edit_num "请输入要编辑的供应商编号（q 返回）: " || return 1

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
  _read_or_quit new_token "请输入新的 API Key（q 返回）: " || return 1

  _validate_required_field "API Key" "$new_token" || {
    echo ""
    return 1
  }

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

# ── 供应商 / 模型管理 ──
_parse_provider_raw() {
  local entry="$1"
  IFS='|' read -r R_NUM R_NAME R_URL R_TOKEN R_MODEL R_HAIKU R_SONNET R_SMALL R_MODEL_OPTIONS <<< "$entry"
}

_validate_number() {
  local label="$1" value="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    _gum_log error "${label} 必须是数字"
    return 1
  fi
}

_validate_required_field() {
  local label="$1" value="$2"
  if [[ -z "$value" ]]; then
    _gum_log error "${label} 不能为空"
    return 1
  fi
  _validate_conf_field "$label" "$value"
}

_validate_conf_field() {
  local label="$1" value="$2"
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* || "$value" == *"|"* ]]; then
    _gum_log error "${label} 不能包含换行或 | 字符"
    return 1
  fi
}

_validate_model_item() {
  local model="$1" description="$2"
  if [[ -z "$model" ]]; then
    _gum_log error "模型名不能为空"
    return 1
  fi
  if [[ "$model" == *$'\n'* || "$model" == *$'\r'* || "$model" == *"|"* || "$model" == *","* || "$model" == *":"* ]]; then
    _gum_log error "模型名不能包含换行、|、, 或 : 字符"
    return 1
  fi
  if [[ "$description" == *$'\n'* || "$description" == *$'\r'* || "$description" == *"|"* || "$description" == *","* ]]; then
    _gum_log error "模型说明不能包含换行、| 或 , 字符"
    return 1
  fi
}

_validate_model_options() {
  local label="$1" options="$2" default_model="$3"
  local value _ description count=0
  _validate_conf_field "$label" "$options" || return 1
  while IFS='|' read -r value _ description; do
    _validate_model_item "$value" "$description" || return 1
    count=$((count + 1))
  done < <(_emit_model_options "$options" "$default_model")
  if [[ $count -eq 0 ]]; then
    _gum_log error "${label} 至少需要一个模型"
    return 1
  fi
}

_build_provider_line() {
  printf "%s|%s|%s|%s|%s|%s|%s|%s|%s" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
}

_model_item() {
  local model="$1" description="$2"
  if [[ -n "$description" ]]; then
    printf "%s:%s" "$model" "$description"
  else
    printf "%s" "$model"
  fi
}

_next_provider_num() {
  API_KEYS_CONF="$API_KEYS_CONF" python3 - <<'PY'
import os

max_num = 0
with open(os.environ["API_KEYS_CONF"], "r", encoding="utf-8") as fh:
    for raw in fh:
        line = raw.rstrip("\n")
        if not line or line.lstrip().startswith("#"):
            continue
        num = line.split("|", 1)[0]
        if num.isdigit():
            max_num = max(max_num, int(num))
print(max_num + 1)
PY
}

_provider_num_exists() {
  local target="$1"
  API_KEYS_CONF="$API_KEYS_CONF" TARGET_NUM="$target" python3 - <<'PY'
import os
import sys

target = os.environ["TARGET_NUM"]
with open(os.environ["API_KEYS_CONF"], "r", encoding="utf-8") as fh:
    for raw in fh:
        line = raw.rstrip("\n")
        if not line or line.lstrip().startswith("#"):
            continue
        if line.split("|", 1)[0] == target:
            sys.exit(0)
sys.exit(1)
PY
}

_backup_api_keys_conf() {
  local timestamp backup_file f
  timestamp=$(date +%Y%m%d_%H%M%S)
  backup_file="$BACKUP_DIR/api-keys.conf.backup.${timestamp}.$$"
  cp -p "$API_KEYS_CONF" "$backup_file"
  chmod 600 "$backup_file"
  _gum_log info "API Key 配置已备份到：${backup_file}"

  local old_backups=($(ls -1t "$BACKUP_DIR"/api-keys.conf.backup.* 2>/dev/null | tail -n +$((MAX_BACKUPS + 1))))
  for f in "${old_backups[@]}"; do
    rm -f "$f"
  done
}

_replace_provider_line() {
  local target="$1" new_line="$2" tmp_conf
  tmp_conf=$(mktemp) || { _gum_log error "无法创建临时文件"; return 1; }
  TEMP_FILES+=("$tmp_conf")

  if API_KEYS_CONF="$API_KEYS_CONF" TARGET_NUM="$target" NEW_LINE="$new_line" python3 - "$tmp_conf" <<'PY'
import os
import sys

src = os.environ["API_KEYS_CONF"]
target = os.environ["TARGET_NUM"]
new_line = os.environ["NEW_LINE"]
dst = sys.argv[1]
updated = False

with open(src, "r", encoding="utf-8") as fh, open(dst, "w", encoding="utf-8") as out:
    for line in fh:
        raw = line.rstrip("\n")
        newline = "\n" if line.endswith("\n") else ""
        if raw and not raw.lstrip().startswith("#"):
            parts = raw.split("|")
            if parts and parts[0] == target:
                raw = new_line
                updated = True
        out.write(raw + newline)

if not updated:
    raise SystemExit("未找到目标供应商")
PY
  then
    _backup_api_keys_conf || { rm -f "$tmp_conf"; return 1; }
    mv "$tmp_conf" "$API_KEYS_CONF"
    chmod 600 "$API_KEYS_CONF"
  else
    rm -f "$tmp_conf"
    return 1
  fi
}

_delete_provider_line() {
  local target="$1" tmp_conf
  tmp_conf=$(mktemp) || { _gum_log error "无法创建临时文件"; return 1; }
  TEMP_FILES+=("$tmp_conf")

  if API_KEYS_CONF="$API_KEYS_CONF" TARGET_NUM="$target" python3 - "$tmp_conf" <<'PY'
import os
import sys

src = os.environ["API_KEYS_CONF"]
target = os.environ["TARGET_NUM"]
dst = sys.argv[1]
deleted = False

with open(src, "r", encoding="utf-8") as fh, open(dst, "w", encoding="utf-8") as out:
    for line in fh:
        raw = line.rstrip("\n")
        newline = "\n" if line.endswith("\n") else ""
        if raw and not raw.lstrip().startswith("#"):
            parts = raw.split("|")
            if parts and parts[0] == target:
                deleted = True
                continue
        out.write(raw + newline)

if not deleted:
    raise SystemExit("未找到目标供应商")
PY
  then
    _backup_api_keys_conf || { rm -f "$tmp_conf"; return 1; }
    mv "$tmp_conf" "$API_KEYS_CONF"
    chmod 600 "$API_KEYS_CONF"
  else
    rm -f "$tmp_conf"
    return 1
  fi
}

_append_provider_line() {
  local new_line="$1"
  _backup_api_keys_conf || return 1
  API_KEYS_CONF="$API_KEYS_CONF" NEW_LINE="$new_line" python3 - <<'PY'
import os
from pathlib import Path

path = Path(os.environ["API_KEYS_CONF"])
line = os.environ["NEW_LINE"]
text = path.read_text(encoding="utf-8") if path.exists() else ""
with path.open("a", encoding="utf-8") as out:
    if text and not text.endswith("\n"):
        out.write("\n")
    out.write(line + "\n")
PY
  chmod 600 "$API_KEYS_CONF"
}

_prompt_keep() {
  local label="$1" current="$2" hint="$3" value
  if [[ -n "$current" ]]; then
    _read_or_quit value "${label} [${current}] (q 返回): " || return 1
  else
    _read_or_quit value "${label} [${hint}] (q 返回): " || return 1
  fi
  if [[ "$value" == "-" ]]; then
    PROMPT_VALUE=""
  elif [[ -n "$value" ]]; then
    PROMPT_VALUE="$value"
  else
    PROMPT_VALUE="$current"
  fi
}

_prompt_provider_num() {
  local prompt="$1" num="$2"
  if [[ -z "$num" ]]; then
    _read_or_quit num "${prompt}(q 返回): " || return 1
  fi
  _validate_number "供应商编号" "$num" || return 1
  PROVIDER_NUM_INPUT="$num"
}

list_providers() {
  local entry
  printf "%b供应商列表%b\n\n" "$CYAN" "$NC"
  for entry in "${PROVIDERS[@]}"; do
    _parse_provider "$entry"
    printf "  [%s] %s\n" "$P_NUM" "$P_NAME"
    printf "      URL: %s\n" "$P_URL"
    printf "      默认模型: %s\n" "$P_MODEL"
  done
  echo ""
}

provider_add() {
  local suggested num name url token model haiku sonnet small options line
  suggested=$(_next_provider_num)

  printf "%b新增供应商%b\n\n" "$CYAN" "$NC"
  _read_or_quit num "供应商编号 [${suggested}] (q 返回): " || return 1
  num="${num:-$suggested}"
  _validate_number "供应商编号" "$num" || return 1
  if _provider_num_exists "$num"; then
    _gum_log error "供应商编号 ${num} 已存在"
    return 1
  fi

  _read_or_quit name "供应商名称 (q 返回): " || return 1
  _read_or_quit url "API URL (q 返回): " || return 1
  _read_or_quit token "API Key (q 返回): " silent || return 1
  _read_or_quit model "默认模型 (q 返回): " || return 1
  _read_or_quit haiku "Haiku 模型 [回车=默认模型] (q 返回): " || return 1
  _read_or_quit sonnet "Sonnet 模型 [回车=默认模型] (q 返回): " || return 1
  _read_or_quit small "Small fast 模型 [回车=默认模型] (q 返回): " || return 1
  _read_or_quit options "可选模型列表 [回车=默认模型] (q 返回): " || return 1
  options="${options:-$model}"

  _validate_required_field "供应商名称" "$name" || return 1
  _validate_required_field "API URL" "$url" || return 1
  _validate_required_field "API Key" "$token" || return 1
  _validate_required_field "默认模型" "$model" || return 1
  _validate_conf_field "Haiku 模型" "$haiku" || return 1
  _validate_conf_field "Sonnet 模型" "$sonnet" || return 1
  _validate_conf_field "Small fast 模型" "$small" || return 1
  _validate_model_options "可选模型列表" "$options" "$model" || return 1

  line=$(_build_provider_line "$num" "$name" "$url" "$token" "$model" "$haiku" "$sonnet" "$small" "$options")
  _append_provider_line "$line" || return 1
  _gum_log info "供应商已新增：[$num] $name"
}

provider_edit() {
  local num entry name url token model haiku sonnet small options line
  _prompt_provider_num "请输入要修改的供应商编号: " "${1:-}" || return 1
  num="$PROVIDER_NUM_INPUT"
  entry=$(_find_provider "$num") || { _gum_log error "无效的供应商编号"; return 1; }
  _parse_provider_raw "$entry"

  printf "%b修改供应商：[%s] %s%b\n" "$CYAN" "$R_NUM" "$R_NAME" "$NC"
  echo "直接回车保留原值；输入 - 可清空可选字段。"
  echo ""

  _prompt_keep "供应商名称" "$R_NAME" "必填" || return 1; name="$PROMPT_VALUE"
  _prompt_keep "API URL" "$R_URL" "必填" || return 1; url="$PROMPT_VALUE"
  _read_or_quit token "API Key [$(_mask_token "$R_TOKEN")，回车保留] (q 返回): " silent || return 1
  token="${token:-$R_TOKEN}"
  _prompt_keep "默认模型" "$R_MODEL" "必填" || return 1; model="$PROMPT_VALUE"
  _prompt_keep "Haiku 模型" "$R_HAIKU" "空=默认模型" || return 1; haiku="$PROMPT_VALUE"
  _prompt_keep "Sonnet 模型" "$R_SONNET" "空=默认模型" || return 1; sonnet="$PROMPT_VALUE"
  _prompt_keep "Small fast 模型" "$R_SMALL" "空=默认模型" || return 1; small="$PROMPT_VALUE"
  _prompt_keep "可选模型列表" "$R_MODEL_OPTIONS" "空=默认模型" || return 1; options="$PROMPT_VALUE"

  _validate_required_field "供应商名称" "$name" || return 1
  _validate_required_field "API URL" "$url" || return 1
  _validate_required_field "API Key" "$token" || return 1
  _validate_required_field "默认模型" "$model" || return 1
  _validate_conf_field "Haiku 模型" "$haiku" || return 1
  _validate_conf_field "Sonnet 模型" "$sonnet" || return 1
  _validate_conf_field "Small fast 模型" "$small" || return 1
  _validate_model_options "可选模型列表" "$options" "$model" || return 1

  line=$(_build_provider_line "$R_NUM" "$name" "$url" "$token" "$model" "$haiku" "$sonnet" "$small" "$options")
  _replace_provider_line "$num" "$line" || return 1
  _gum_log info "供应商已更新：[$num] $name"
}

provider_delete() {
  local num entry confirm
  _prompt_provider_num "请输入要删除的供应商编号: " "${1:-}" || return 1
  num="$PROVIDER_NUM_INPUT"
  entry=$(_find_provider "$num") || { _gum_log error "无效的供应商编号"; return 1; }
  _parse_provider "$entry"

  printf "%b将删除供应商：[%s] %s%b\n" "$YELLOW" "$P_NUM" "$P_NAME" "$NC"
  _read_or_quit confirm "确认删除请输入 yes（q 返回）: " || return 1
  if [[ "$confirm" != "yes" ]]; then
    _gum_log warn "已取消删除"
    return 1
  fi

  _delete_provider_line "$num" || return 1
  _gum_log info "供应商已删除：[$num] $P_NAME"
}

_model_exists() {
  local options="$1" default_model="$2" target="$3" value label description
  while IFS='|' read -r value label description; do
    [[ "$value" == "$target" ]] && return 0
  done < <(_emit_model_options "$options" "$default_model")
  return 1
}

_list_models_for_entry() {
  local options="$1" default_model="$2" value label description index=1
  while IFS='|' read -r value label description; do
    printf "  %d) %-28s %s\n" "$index" "$value" "$description"
    index=$((index + 1))
  done < <(_emit_model_options "$options" "$default_model")
}

_update_provider_model_options() {
  local num="$1" options="$2" entry line
  entry=$(_find_provider "$num") || { _gum_log error "无效的供应商编号"; return 1; }
  _parse_provider_raw "$entry"
  line=$(_build_provider_line "$R_NUM" "$R_NAME" "$R_URL" "$R_TOKEN" "$R_MODEL" "$R_HAIKU" "$R_SONNET" "$R_SMALL" "$options")
  _replace_provider_line "$num" "$line"
}

model_list() {
  local num entry options
  _prompt_provider_num "请输入供应商编号: " "${1:-}" || return 1
  num="$PROVIDER_NUM_INPUT"
  entry=$(_find_provider "$num") || { _gum_log error "无效的供应商编号"; return 1; }
  _parse_provider_raw "$entry"
  options="${R_MODEL_OPTIONS:-$R_MODEL}"

  printf "%b[%s] %s 模型列表%b\n\n" "$CYAN" "$R_NUM" "$R_NAME" "$NC"
  _list_models_for_entry "$options" "$R_MODEL"
  echo ""
}

model_add() {
  local num entry options model description item new_options
  _prompt_provider_num "请输入供应商编号: " "${1:-}" || return 1
  num="$PROVIDER_NUM_INPUT"
  entry=$(_find_provider "$num") || { _gum_log error "无效的供应商编号"; return 1; }
  _parse_provider_raw "$entry"
  options="${R_MODEL_OPTIONS:-$R_MODEL}"

  printf "%b给 [%s] %s 新增模型%b\n\n" "$CYAN" "$R_NUM" "$R_NAME" "$NC"
  _read_or_quit model "模型名 (q 返回): " || return 1
  _read_or_quit description "说明 [可选] (q 返回): " || return 1
  _validate_model_item "$model" "$description" || return 1
  if _model_exists "$options" "$R_MODEL" "$model"; then
    _gum_log error "模型已存在：$model"
    return 1
  fi

  item=$(_model_item "$model" "$description")
  if [[ -n "$options" ]]; then
    new_options="${options},${item}"
  else
    new_options="$item"
  fi
  _update_provider_model_options "$num" "$new_options" || return 1
  _gum_log info "模型已新增：$model"
}

model_delete() {
  local num entry options choice value label description index=1 kept="" item
  _prompt_provider_num "请输入供应商编号: " "${1:-}" || return 1
  num="$PROVIDER_NUM_INPUT"
  entry=$(_find_provider "$num") || { _gum_log error "无效的供应商编号"; return 1; }
  _parse_provider_raw "$entry"
  options="${R_MODEL_OPTIONS:-$R_MODEL}"

  model_list "$num"
  _read_or_quit choice "请输入要删除的模型序号（q 返回）: " || return 1
  _validate_number "模型序号" "$choice" || return 1

  while IFS='|' read -r value label description; do
    if [[ "$index" != "$choice" ]]; then
      item=$(_model_item "$value" "$description")
      if [[ -n "$kept" ]]; then
        kept="${kept},${item}"
      else
        kept="$item"
      fi
    fi
    index=$((index + 1))
  done < <(_emit_model_options "$options" "$R_MODEL")

  if [[ "$choice" -lt 1 || "$choice" -ge "$index" ]]; then
    _gum_log error "无效的模型序号"
    return 1
  fi
  if [[ -z "$kept" ]]; then
    _gum_log error "至少保留一个模型"
    return 1
  fi

  _update_provider_model_options "$num" "$kept" || return 1
  _gum_log info "模型已删除"
}

model_edit() {
  local num entry options choice value label description index=1 old_model old_description new_model new_description kept="" item found=0
  _prompt_provider_num "请输入供应商编号: " "${1:-}" || return 1
  num="$PROVIDER_NUM_INPUT"
  entry=$(_find_provider "$num") || { _gum_log error "无效的供应商编号"; return 1; }
  _parse_provider_raw "$entry"
  options="${R_MODEL_OPTIONS:-$R_MODEL}"

  model_list "$num"
  _read_or_quit choice "请输入要修改的模型序号（q 返回）: " || return 1
  _validate_number "模型序号" "$choice" || return 1

  while IFS='|' read -r value label description; do
    if [[ "$index" == "$choice" ]]; then
      old_model="$value"
      old_description="$description"
      found=1
      break
    fi
    index=$((index + 1))
  done < <(_emit_model_options "$options" "$R_MODEL")

  if [[ "$found" -eq 0 ]]; then
    _gum_log error "无效的模型序号"
    return 1
  fi

  _read_or_quit new_model "模型名 [${old_model}] (q 返回): " || return 1
  new_model="${new_model:-$old_model}"
  _read_or_quit new_description "说明 [${old_description}，输入 - 清空] (q 返回): " || return 1
  if [[ "$new_description" == "-" ]]; then
    new_description=""
  else
    new_description="${new_description:-$old_description}"
  fi
  _validate_model_item "$new_model" "$new_description" || return 1
  if [[ "$new_model" != "$old_model" ]] && _model_exists "$options" "$R_MODEL" "$new_model"; then
    _gum_log error "模型已存在：$new_model"
    return 1
  fi

  index=1
  while IFS='|' read -r value label description; do
    if [[ "$index" == "$choice" ]]; then
      item=$(_model_item "$new_model" "$new_description")
    else
      item=$(_model_item "$value" "$description")
    fi

    if [[ -n "$kept" ]]; then
      kept="${kept},${item}"
    else
      kept="$item"
    fi
    index=$((index + 1))
  done < <(_emit_model_options "$options" "$R_MODEL")

  _update_provider_model_options "$num" "$kept" || return 1
  _gum_log info "模型已更新"
}

config_management_menu() {
  local choice
  while true; do
    printf "%b配置管理%b\n\n" "$CYAN" "$NC"
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

    _read_or_quit choice "请输入选项: " || return 0
    case "$choice" in
      1) list_providers ;;
      2) provider_add && _reload_providers ;;
      3) provider_edit && _reload_providers ;;
      4) provider_delete && _reload_providers ;;
      5) model_list ;;
      6) model_add && _reload_providers ;;
      7) model_edit && _reload_providers ;;
      8) model_delete && _reload_providers ;;
      q|Q|0|b|B) return 0 ;;
      *) _gum_log error "无效选项" ;;
    esac
    echo ""
  done
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
  echo "  ~/cc.sh list      # 查看供应商列表"
  echo "  ~/cc.sh provider-add             # 新增供应商"
  echo "  ~/cc.sh provider-edit <编号>     # 修改供应商"
  echo "  ~/cc.sh provider-delete <编号>   # 删除供应商"
  echo "  ~/cc.sh model-list <编号>        # 查看供应商模型"
  echo "  ~/cc.sh model-add <编号>         # 新增模型"
  echo "  ~/cc.sh model-edit <编号>        # 修改模型"
  echo "  ~/cc.sh model-delete <编号>      # 删除模型"
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
      while true; do
        show_menu
        MENU_ROOT=1 _read_or_quit choice "请输入选项 (? 查看帮助): "
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
          c|config|manage)
            config_management_menu
            ;;
          \?|h|help)
            show_menu_help
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
    list|ls|providers)
      list_providers
      ;;
    config|manage)
      config_management_menu
      ;;
    provider-add|add-provider|add)
      provider_add
      ;;
    provider-edit|edit-provider)
      provider_edit "${2:-}"
      ;;
    provider-delete|delete-provider|provider-del|del-provider)
      provider_delete "${2:-}"
      ;;
    model-list|models)
      model_list "${2:-}"
      ;;
    model-add)
      model_add "${2:-}"
      ;;
    model-edit)
      model_edit "${2:-}"
      ;;
    model-delete|model-del)
      model_delete "${2:-}"
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
