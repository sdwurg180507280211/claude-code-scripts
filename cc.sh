#!/usr/local/bin/bash

# Claude Code 供应商切换脚本
# 用法：~/cc.sh [选项]
#   无参数：交互式选择
#   1-N: 直接选择对应供应商
#   0/test: 速度测试
#   status: 查看当前配置
#   -m <model>: 指定模型（不指定默认为 claude-opus-4-6）

set -e
set -o pipefail

# 依赖检查
for cmd in python3 perl curl; do
  command -v "$cmd" &>/dev/null || {
    echo "错误: 需要安装 $cmd" >&2
    exit 1
  }
done

# 配置目录
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
BACKUP_DIR="$HOME/.claude/backups"
MAX_BACKUPS=10
LOCK_FILE="$HOME/.claude/.cc.lock"
TEMP_FILES=()

# 全局清理函数
_global_cleanup() {
  for f in "${TEMP_FILES[@]}"; do
    [[ -f "$f" ]] && rm -f "$f"
  done
  [[ -f "$LOCK_FILE" ]] && rm -f "$LOCK_FILE"
}

trap _global_cleanup EXIT INT TERM

# 获取文件锁
_acquire_lock() {
  local max_wait=5
  local waited=0
  while [[ -f "$LOCK_FILE" ]] && (( waited < max_wait )); do
    sleep 1
    (( waited++ ))
  done
  if [[ -f "$LOCK_FILE" ]]; then
    echo "错误: 另一个实例正在运行" >&2
    exit 1
  fi
  echo $$ > "$LOCK_FILE"
}

mkdir -p "$BACKUP_DIR"
_acquire_lock

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

# ── 供应商数据 (唯一数据源) ──
# 格式: 编号|名称|URL|Token|模型|haiku模型|sonnet模型|small_fast模型
# haiku/sonnet/small_fast 留空则与主模型相同
PROVIDERS=(
  # ── newcli 系列 (共用 token) ──
  "1|newcli/super (Super 特价)|https://code.newcli.com/claude/super|sk-ant-oat01-II5Pqj8w3LkOqYbsXVeil1kg-8xkYflCtjZafD833B6imrsfQ4M-dG-iJIPSB_4WgGYdYerqvdnYh-Zr47y_d8pOMKEXQAA|claude-opus-4-6|||"
  "2|newcli/ultra (Ultra 特价)|https://code.newcli.com/claude/ultra|sk-ant-oat01-II5Pqj8w3LkOqYbsXVeil1kg-8xkYflCtjZafD833B6imrsfQ4M-dG-iJIPSB_4WgGYdYerqvdnYh-Zr47y_d8pOMKEXQAA|claude-opus-4-6|||"
  "3|newcli/droid (AWS 思考)|https://code.newcli.com/claude/droid|sk-ant-oat01-II5Pqj8w3LkOqYbsXVeil1kg-8xkYflCtjZafD833B6imrsfQ4M-dG-iJIPSB_4WgGYdYerqvdnYh-Zr47y_d8pOMKEXQAA|claude-opus-4-6|||"
  "4|newcli/aws (AWS 特价)|https://code.newcli.com/claude/aws|sk-ant-oat01-II5Pqj8w3LkOqYbsXVeil1kg-8xkYflCtjZafD833B6imrsfQ4M-dG-iJIPSB_4WgGYdYerqvdnYh-Zr47y_d8pOMKEXQAA|claude-opus-4-6|||"
  # ── 独立 Claude 中转 ──
  "5|PuCode (pucode.com)|https://api.pucode.com|sk-hqhrgEo8zJXKaBFzQWIn3GShov9nDj9rWBpunCcCtXUtT9GC|claude-opus-4-6|claude-haiku-4-5-20251001|claude-sonnet-4-6|claude-haiku-4-5-20251001"
  "6|AiCoding (aicoding.sh)|https://api.aicoding.sh|aicoding-53023984484a878506ec4082938d6b2e|claude-opus-4-6|||"
  "7|中转站 (zhongzhuan.win)|https://api.zhongzhuan.win/v1|sk-lcTMEbXxAhrP27hpcdBNf8eSxCWNw6ENuEzaZ34IDHJ53oHV|claude-opus-4-6|||"
  # ── 非 Claude 模型 ──
  "8|LinkAPI (GPT-5.4)|https://api.linkapi.ai|sk-7NoV0BobP08hph5PrQormauliECHLOJU7NPFSSU8RMbidBza|gpt-5.4|gpt-5-mini|gpt-5.2|gpt-5-mini"
  "9|Kimi K2.5 (moonshot.cn)|https://api.moonshot.cn/anthropic|sk-ymAwI8vqQY2TV94QXDyHNZ9wRXoEBOlgMm57u1SFxbj1okuR|kimi-k2.5|||"
  "10|阿里云 Coding (qwen3.5-plus)|https://coding.dashscope.aliyuncs.com/apps/anthropic|sk-sp-bfa0853dbd634cb1a3779bc17cfd94bf|qwen3.5-plus|||"
)

PROVIDER_COUNT=${#PROVIDERS[@]}
TEST_TIMEOUT=8
DEFAULT_MODEL="claude-opus-4-6"
CUSTOM_MODEL=""

# ── 从数组解析供应商字段 ──
_parse_provider() {
  local entry="$1"
  IFS='|' read -r P_NUM P_NAME P_URL P_TOKEN P_MODEL P_HAIKU P_SONNET P_SMALL <<< "$entry"
  P_HAIKU="${P_HAIKU:-$P_MODEL}"
  P_SONNET="${P_SONNET:-$P_MODEL}"
  P_SMALL="${P_SMALL:-$P_MODEL}"
}

# 根据 token 格式返回正确的 Authorization header 值
# aicoding- 前缀：直接用 token；其他：Bearer token 或 x-api-key
_auth_headers() {
  local token="$1"
  if [[ "$token" == aicoding-* ]]; then
    echo "-H \"Authorization: ${token}\""
  else
    echo "-H \"x-api-key: ${token}\" -H \"Authorization: Bearer ${token}\""
  fi
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
  local model="${CUSTOM_MODEL:-$DEFAULT_MODEL}"
  local haiku_model="$P_HAIKU"
  local sonnet_model="$P_SONNET"
  local small_fast_model="$P_SMALL"

  [[ -n "$CUSTOM_MODEL" ]] && haiku_model="$CUSTOM_MODEL"
  [[ -n "$CUSTOM_MODEL" ]] && sonnet_model="$CUSTOM_MODEL"
  [[ -n "$CUSTOM_MODEL" ]] && small_fast_model="$CUSTOM_MODEL"

  cat <<EOF
{
  "env": {
    "ANTHROPIC_BASE_URL": "${P_URL}",
    "ANTHROPIC_AUTH_TOKEN": "${P_TOKEN}",
    "ANTHROPIC_MODEL": "${model}",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "${haiku_model}",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "${sonnet_model}",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "${model}",
    "ANTHROPIC_SMALL_FAST_MODEL": "${small_fast_model}",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  },
  "model": "opus",
  "skipDangerousModePermissionPrompt": true
}
EOF
}

# ── 速度测试 ──
_get_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time()*1000'; }

_parse_response() {
  python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if 'content' in d and len(d['content']) > 0:
        texts = [c.get('text','') for c in d['content'] if c.get('type') == 'text']
        reply = ' '.join(texts).strip()[:80]
        model = d.get('model', '?')
        tok_in = d.get('usage', {}).get('input_tokens', '?')
        tok_out = d.get('usage', {}).get('output_tokens', '?')
        print(f'OK|{model}|{tok_in}|{tok_out}|{reply}')
    elif 'error' in d:
        e = d['error']
        msg = e.get('message', str(e)) if isinstance(e, dict) else str(e)
        print(f'ERR|{msg[:120]}')
    else:
        print(f'ERR|{json.dumps(d)[:120]}')
except Exception as ex:
    raw = sys.stdin.read().strip()
    print(f'ERR|{raw[:120] if raw else str(ex)[:120]}')
" 2>/dev/null
}

# 计算字符串显示宽度（中文=2，英文=1）
_display_width() {
  echo "$1" | perl -C -ne 'use utf8; my $w=0; for(split//){$w+=/\p{Han}|\p{Hiragana}|\p{Katakana}|\p{Hangul}/||/[\x{3000}-\x{303F}\x{FF00}-\x{FFEF}]/||/[\x{2E80}-\x{9FFF}]/||/[\x{AC00}-\x{D7AF}]/?2:1} print $w'
}

# 右侧填充空格到指定显示宽度
_pad_right() {
  local str="$1" target_width="$2"
  local current_width=$(_display_width "$str")
  local padding=$((target_width - current_width))
  if [[ $padding -gt 0 ]]; then
    printf "%s%*s" "$str" "$padding" ""
  else
    printf "%s" "$str"
  fi
}

# 格式化单行结果并输出 (支持 TTFT + 总耗时)
_print_result_line() {
  local line="$1"
  IFS='|' read -r num name http_code ttft total ret_model tokens reply <<< "$line"
  local ttft_fmt total_fmt
  if (( ttft > 1000 )); then
    ttft_fmt=$(perl -e "printf '%.1fs', $ttft/1000")
  else
    ttft_fmt="${ttft}ms"
  fi
  if (( total > 1000 )); then
    total_fmt=$(perl -e "printf '%.1fs', $total/1000")
  else
    total_fmt="${total}ms"
  fi

  # 截断过长的错误信息
  if [[ ${#reply} -gt 50 ]]; then
    reply="${reply:0:47}..."
  fi

  # 使用显示宽度对齐
  local num_col=$(_pad_right "${num})" 5)
  local name_col=$(_pad_right "$name" 38)

  # 状态列固定宽度
  local status_display
  if [[ "$http_code" == "200" ]]; then
    status_display="200"
  elif [[ "$http_code" == "FAIL" ]]; then
    status_display="失败"
  else
    status_display="$http_code"
  fi
  local http_col=$(_pad_right "$status_display" 10)

  printf -v ttft_col "%9s" "$ttft_fmt"
  printf -v total_col "%9s" "$total_fmt"
  local model_col=$(_pad_right "${ret_model:--}" 28)
  local token_col=$(_pad_right "${tokens:--}" 12)

  if [[ "$http_code" == "200" ]]; then
    printf "%b%s%b%s%b%s%b%s %s %s%s%s\n" \
      "$GREEN" "$num_col" "$NC" "$name_col" "$GREEN" "$http_col" "$NC" "$ttft_col" "$total_col" "$model_col" "$token_col" "$reply"
  else
    printf "%b%s%b%s%b%s%b%s %s %s%s%b%s%b\n" \
      "$RED" "$num_col" "$NC" "$name_col" "$RED" "$http_col" "$NC" "$ttft_col" "$total_col" "$model_col" "$token_col" "$RED" "$reply" "$NC"
  fi
}

# 解析 SSE stream 响应，提取 TTFT、模型、tokens、回复
# 通过 pipe 实时读取 curl SSE 输出，准确测量 TTFT
# 输出: OK|ttft_ms|model|tok_in|tok_out|reply  或  ERR|msg
_parse_stream_response() {
  python3 -c "
import sys, json, subprocess

start_ms = int(sys.argv[1])
ttft = -1
model = '?'
tok_in = '?'
tok_out = '?'
texts = []
error_msg = ''
got_sse = False

def now_ms():
    return int(subprocess.check_output(
        ['perl', '-MTime::HiRes=time', '-e', 'printf \"%d\", time()*1000']
    ).decode())

for raw_line in sys.stdin:
    line = raw_line.strip()
    if not line:
        continue
    # 非 SSE 响应容错 (纯文本/HTML/JSON 错误)
    if not got_sse:
        if line.startswith('{'):
            try:
                d = json.loads(line)
                e = d.get('error', {})
                msg = e.get('message', str(e)) if isinstance(e, dict) else str(e)
                print(f'ERR|{msg[:120]}')
            except:
                print(f'ERR|{line[:120]}')
            sys.exit(0)
        elif not line.startswith('data:') and not line.startswith('event:'):
            # 纯文本错误
            print(f'ERR|{line[:120]}')
            sys.exit(0)

    if not line.startswith('data:'):
        if line.startswith('event:'):
            got_sse = True
        continue

    got_sse = True
    data = line[5:].strip()
    if data == '[DONE]':
        break
    try:
        d = json.loads(data)
    except:
        continue
    etype = d.get('type', '')
    if etype == 'error':
        e = d.get('error', {})
        error_msg = e.get('message', str(e)) if isinstance(e, dict) else str(e)
        break
    if etype == 'message_start':
        msg = d.get('message', {})
        model = msg.get('model', '?')
        usage = msg.get('usage', {})
        tok_in = usage.get('input_tokens', '?')
        # TTFT = 收到 message_start 的时间
        if ttft < 0:
            ttft = now_ms() - start_ms
    elif etype == 'content_block_delta':
        delta = d.get('delta', {})
        delta_type = delta.get('type', '')
        if delta_type == 'text_delta':
            texts.append(delta.get('text', ''))
        # thinking_delta 不纳入 texts
    elif etype == 'message_delta':
        usage = d.get('usage', {})
        tok_out = usage.get('output_tokens', tok_out)

if error_msg:
    print(f'ERR|{error_msg[:120]}')
elif texts or model != '?':
    reply = ''.join(texts).strip()[:80] if texts else '(thinking only)'
    if ttft < 0:
        ttft = 0
    print(f'OK|{ttft}|{model}|{tok_in}|{tok_out}|{reply}')
else:
    print(f'ERR|no content received')
" "$1" 2>/dev/null
}

# 测试单个供应商一次 (stream 模式，pipe 实时测 TTFT)
# 输出: OK|ttft|total|model|tok_in/tok_out|reply  或  FAIL|total|errmsg
_test_one_round() {
  local entry="$1"
  _parse_provider "$entry"
  local test_url="${P_URL}/v1/messages"
  [[ "$P_URL" == */v1 ]] && test_url="${P_URL}/messages"

  local auth_args
  if [[ "$P_TOKEN" == aicoding-* ]]; then
    auth_args=(-H "Authorization: ${P_TOKEN}")
  else
    auth_args=(-H "x-api-key: ${P_TOKEN}" -H "Authorization: Bearer ${P_TOKEN}")
  fi

  local start=$(_get_ms)
  local tmp_out=$(mktemp)
  TEMP_FILES+=("$tmp_out")

  # 用 pipe 方式让 python 实时读取 SSE 流，准确测量 TTFT
  curl -sS -N --max-time "$TEST_TIMEOUT" \
    -X POST "$test_url" \
    -H "Content-Type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    "${auth_args[@]}" \
    -d "{\"model\":\"${P_MODEL}\",\"max_tokens\":30,\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"Say ok\"}]}" 2>/dev/null \
  | _parse_stream_response "$start" > "$tmp_out" 2>/dev/null
  local pipe_status=${PIPESTATUS[0]}
  local total=$(( $(_get_ms) - start ))

  local parsed
  parsed=$(cat "$tmp_out" 2>/dev/null || echo "")

  # curl 超时或连接失败且无输出
  if [[ -z "$parsed" ]]; then
    echo "FAIL|${total}|连接超时 (${TEST_TIMEOUT}s)"
    return
  fi

  local tag=$(echo "$parsed" | cut -d'|' -f1)

  if [[ "$tag" == "OK" ]]; then
    local ttft=$(echo "$parsed" | cut -d'|' -f2)
    local ret_model=$(echo "$parsed" | cut -d'|' -f3)
    local tok_in=$(echo "$parsed" | cut -d'|' -f4)
    local tok_out=$(echo "$parsed" | cut -d'|' -f5)
    local reply=$(echo "$parsed" | cut -d'|' -f6-)
    echo "OK|${ttft}|${total}|${ret_model}|${tok_in}/${tok_out}|${reply}"
  else
    local errmsg=$(echo "$parsed" | cut -d'|' -f2-)
    echo "FAIL|${total}|${errmsg}"
  fi
}

# 测试单个供应商 (2 轮取较快值) 并实时输出
_test_one_live() {
  local entry="$1" result_file="$2"
  _parse_provider "$entry"

  local best_ttft=999999 best_total=999999 best_line="" status_tag="FAIL"
  local round=1 rounds=2

  while (( round <= rounds )); do
    local result
    result=$(_test_one_round "$entry")
    local tag=$(echo "$result" | cut -d'|' -f1)

    if [[ "$tag" == "OK" ]]; then
      local ttft=$(echo "$result" | cut -d'|' -f2)
      local total=$(echo "$result" | cut -d'|' -f3)
      local ret_model=$(echo "$result" | cut -d'|' -f4)
      local tokens=$(echo "$result" | cut -d'|' -f5)
      local reply=$(echo "$result" | cut -d'|' -f6-)

      if (( ttft < best_ttft )); then
        best_ttft=$ttft
        best_total=$total
        best_line="${P_NUM}|${P_NAME}|200|${best_ttft}|${best_total}|${ret_model}|${tokens}|${reply}"
        status_tag="OK"
      fi
    else
      local total=$(echo "$result" | cut -d'|' -f2)
      local errmsg=$(echo "$result" | cut -d'|' -f3-)
      # 首轮失败则跳过第二轮
      if [[ -z "$best_line" ]]; then
        best_line="${P_NUM}|${P_NAME}|FAIL|${total}|${total}|||${errmsg}"
      fi
      break
    fi
    (( round++ ))
  done

  _print_result_line "$best_line"
  echo "$status_tag" >> "$result_file"
}

# ── 功能验证（模拟 Claude Code 真实请求）──
VERIFY_TIMEOUT=30

_verify_response() {
  python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    model = d.get('model', '?')
    content = d.get('content', [])
    has_tool_use = any(c.get('type') == 'tool_use' for c in content)
    has_text = any(c.get('type') == 'text' for c in content)
    texts = [c.get('text','') for c in content if c.get('type') == 'text']
    reply = ' '.join(texts).strip()[:100].replace('\n', ' ')
    if 'error' in d:
        e = d['error']
        msg = e.get('message', str(e)) if isinstance(e, dict) else str(e)
        print('ERR')
        print(msg[:120])
    elif has_tool_use:
        tool = next(c for c in content if c.get('type') == 'tool_use')
        print('TOOL')
        print(model)
        print(tool.get('name','?'))
        print(json.dumps(tool.get('input',{}))[:60])
    elif has_text:
        print('TEXT')
        print(model)
        print(reply)
    else:
        print('ERR')
        print('unexpected response: ' + json.dumps(d)[:120])
except Exception as ex:
    print('ERR')
    print(str(ex)[:120])
" 2>/dev/null
}

# ── 模型列表查询 ──
_parse_models_response() {
  python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if 'error' in d:
        e = d['error']
        msg = e.get('message', str(e)) if isinstance(e, dict) else str(e)
        print('ERR|' + msg[:200])
    elif 'data' in d:
        models = [m.get('id', '?') for m in d['data']]
        models.sort()
        print('OK|' + '|'.join(models))
    elif isinstance(d, list):
        models = [m.get('id', '?') if isinstance(m, dict) else str(m) for m in d]
        models.sort()
        print('OK|' + '|'.join(models))
    else:
        print('ERR|unexpected: ' + json.dumps(d)[:200])
except Exception as ex:
    raw = sys.stdin.read().strip()
    print('ERR|' + (raw[:200] if raw else str(ex)[:200]))
" 2>/dev/null
}

list_models_provider() {
  local num="$1"
  local entry
  entry=$(_find_provider "$num") || {
    _gum_log error "无效的供应商编号 $num"
    return 1
  }
  _parse_provider "$entry"

  local models_url="${P_URL}/v1/models"
  [[ "$P_URL" == */v1 ]] && models_url="${P_URL}/models"

  local auth_args
  if [[ "$P_TOKEN" == aicoding-* ]]; then
    auth_args=(-H "Authorization: ${P_TOKEN}")
  else
    auth_args=(-H "x-api-key: ${P_TOKEN}" -H "Authorization: Bearer ${P_TOKEN}")
  fi

  printf "\n  %b[%s]%b %s\n" "$CYAN" "$P_NUM" "$NC" "$P_NAME"
  printf "  端点: %s\n" "$models_url"

  local start=$(_get_ms)
  local raw=$(curl -s -w "\n%{http_code}" --max-time "$VERIFY_TIMEOUT" \
    -X GET "$models_url" \
    -H "Content-Type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    "${auth_args[@]}" 2>&1)
  local duration=$(( $(_get_ms) - start ))
  local http_code=$(echo "$raw" | tail -1)
  local body=$(echo "$raw" | sed '$d')

  if [[ -z "$http_code" || "$http_code" == "000" ]]; then
    printf "  %b✗ 连接超时%b (${VERIFY_TIMEOUT}s)\n\n" "$RED" "$NC"
    return
  fi

  local parsed=$(echo "$body" | _parse_models_response)
  local tag=$(echo "$parsed" | cut -d'|' -f1)

  if [[ "$tag" == "OK" ]]; then
    local model_list=$(echo "$parsed" | cut -d'|' -f2-)
    local count=$(echo "$model_list" | tr '|' '\n' | wc -l | tr -d ' ')
    printf "  %b✓ HTTP %s%b (%.1fs, 共 %s 个模型)\n" "$GREEN" "$http_code" "$NC" \
      "$(perl -e "printf '%.1f',$duration/1000")" "$count"

    # 按类别分组显示
    local claude_models="" gpt_models="" other_models=""
    while IFS='|' read -d'|' -r m || [[ -n "$m" ]]; do
      [[ -z "$m" ]] && continue
      if [[ "$m" == claude-* ]]; then
        claude_models+="    $m\n"
      elif [[ "$m" == gpt-* || "$m" == o1-* || "$m" == o3-* || "$m" == o4-* ]]; then
        gpt_models+="    $m\n"
      else
        other_models+="    $m\n"
      fi
    done <<< "${model_list}|"

    if [[ -n "$claude_models" ]]; then
      printf "  %bClaude 系列:%b\n" "$BLUE" "$NC"
      printf "%b" "$claude_models"
    fi
    if [[ -n "$gpt_models" ]]; then
      printf "  %bGPT/OpenAI 系列:%b\n" "$BLUE" "$NC"
      printf "%b" "$gpt_models"
    fi
    if [[ -n "$other_models" ]]; then
      printf "  %b其他模型:%b\n" "$BLUE" "$NC"
      printf "%b" "$other_models"
    fi
  else
    local errmsg=$(echo "$parsed" | cut -d'|' -f2-)
    printf "  %b✗ HTTP %s%b (%.1fs) %s\n" "$RED" "$http_code" "$NC" \
      "$(perl -e "printf '%.1f',$duration/1000")" "$errmsg"
  fi
  printf "\n"
}

run_list_models() {
  printf "\n"
  _gum_header "📋 供应商可用模型列表查询"
  printf "\n"

  local target="${1:-}"
  if [[ -n "$target" ]]; then
    list_models_provider "$target"
  else
    for entry in "${PROVIDERS[@]}"; do
      _parse_provider "$entry"
      list_models_provider "$P_NUM"
    done
  fi
}

verify_provider() {
  local num="$1"
  local entry
  entry=$(_find_provider "$num") || {
    _gum_log error "无效的供应商编号 $num"
    return 1
  }
  _parse_provider "$entry"

  local test_url="${P_URL}/v1/messages"
  [[ "$P_URL" == */v1 ]] && test_url="${P_URL}/messages"

  # 根据 token 格式选择 auth headers
  local auth_args
  if [[ "$P_TOKEN" == aicoding-* ]]; then
    auth_args=(-H "Authorization: ${P_TOKEN}")
  else
    auth_args=(-H "x-api-key: ${P_TOKEN}" -H "Authorization: Bearer ${P_TOKEN}")
  fi

  printf "\n"
  _gum_header "🔍 功能验证：${P_NAME}"
  printf "\n  模型: %b%s%b\n  端点: %s\n\n" "$GREEN" "$P_MODEL" "$NC" "$test_url"

  # 测试1：基础响应（较长输出）
  printf "  %b[1/3]%b 基础响应测试 (max_tokens=300)... " "$YELLOW" "$NC"
  local start=$(_get_ms)
  local raw=$(curl -s -w "\n%{http_code}" --max-time "$VERIFY_TIMEOUT" \
    -X POST "$test_url" \
    -H "Content-Type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    "${auth_args[@]}" \
    -d "{\"model\":\"${P_MODEL}\",\"max_tokens\":300,\"stream\":false,\"system\":\"You are a coding assistant.\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a bubble sort in Python, just the code.\"}]}" 2>&1)
  local duration=$(( $(_get_ms) - start ))
  local http_code=$(echo "$raw" | tail -1)
  local body=$(echo "$raw" | sed '$d')
  local parsed_lines
  mapfile -t parsed_lines < <(echo "$body" | _verify_response)
  local tag="${parsed_lines[0]}"
  if [[ "$tag" == "TEXT" ]]; then
    local ret_model="${parsed_lines[1]}"
    local reply="${parsed_lines[2]}"
    printf "%b✓ OK%b (%.1fs, 模型:%s)\n    回复: %s\n" "$GREEN" "$NC" "$(perl -e "printf '%.1f',$duration/1000")" "$ret_model" "$reply"
  else
    local errmsg="${parsed_lines[1]}"
    printf "%b✗ FAIL%b (%.1fs) %s\n" "$RED" "$NC" "$(perl -e "printf '%.1f',$duration/1000")" "$errmsg"
  fi

  # 测试2：工具调用
  printf "  %b[2/3]%b 工具调用测试 (tool_use)... " "$YELLOW" "$NC"
  local tool_payload='{
    "model":"'"${P_MODEL}"'",
    "max_tokens":200,
    "tools":[{
      "name":"read_file",
      "description":"Read a file from disk",
      "input_schema":{
        "type":"object",
        "properties":{"path":{"type":"string","description":"file path"}},
        "required":["path"]
      }
    }],
    "messages":[{"role":"user","content":"Please read the file /etc/hosts"}]
  }'
  start=$(_get_ms)
  raw=$(curl -s -w "\n%{http_code}" --max-time "$VERIFY_TIMEOUT" \
    -X POST "$test_url" \
    -H "Content-Type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    "${auth_args[@]}" \
    -d "$tool_payload" 2>&1)
  duration=$(( $(_get_ms) - start ))
  http_code=$(echo "$raw" | tail -1)
  body=$(echo "$raw" | sed '$d')
  mapfile -t parsed_lines < <(echo "$body" | _verify_response)
  tag="${parsed_lines[0]}"
  if [[ "$tag" == "TOOL" ]]; then
    local tool_name="${parsed_lines[2]}"
    local tool_input="${parsed_lines[3]}"
    printf "%b✓ OK%b (%.1fs, 工具:%s, 参数:%s)\n" "$GREEN" "$NC" "$(perl -e "printf '%.1f',$duration/1000")" "$tool_name" "$tool_input"
  elif [[ "$tag" == "TEXT" ]]; then
    printf "%b△ 降级%b (%.1fs) 返回文本而非工具调用，可能不支持 tool_use\n" "$YELLOW" "$NC" "$(perl -e "printf '%.1f',$duration/1000")"
  else
    local errmsg="${parsed_lines[1]}"
    printf "%b✗ FAIL%b (%.1fs) %s\n" "$RED" "$NC" "$(perl -e "printf '%.1f',$duration/1000")" "$errmsg"
  fi

  # 测试3：模型名一致性
  printf "  %b[3/3]%b 模型名一致性检查... " "$YELLOW" "$NC"
  raw=$(curl -s -w "\n%{http_code}" --max-time "$VERIFY_TIMEOUT" \
    -X POST "$test_url" \
    -H "Content-Type: application/json" \
    -H "anthropic-version: 2023-06-01" \
    "${auth_args[@]}" \
    -d "{\"model\":\"${P_MODEL}\",\"max_tokens\":10,\"stream\":false,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" 2>&1)
  http_code=$(echo "$raw" | tail -1)
  body=$(echo "$raw" | sed '$d')
  mapfile -t parsed_lines < <(echo "$body" | _verify_response)
  tag="${parsed_lines[0]}"
  if [[ "$tag" == "TEXT" || "$tag" == "TOOL" ]]; then
    local ret_model="${parsed_lines[1]}"
    if [[ "$ret_model" == "$P_MODEL"* ]]; then
      printf "%b✓ 一致%b (请求:%s 返回:%s)\n" "$GREEN" "$NC" "$P_MODEL" "$ret_model"
    else
      printf "%b△ 不一致%b (请求:%s 但返回:%s)\n" "$YELLOW" "$NC" "$P_MODEL" "$ret_model"
    fi
  else
    local errmsg="${parsed_lines[1]:-未知错误}"
    printf "%b✗ FAIL%b %s\n" "$RED" "$NC" "$errmsg"
  fi

  printf "\n"
}

run_speed_test() {
  local work_dir=$(mktemp -d)
  local result_file="${work_dir}/results"
  touch "$result_file"
  trap 'rm -rf "$work_dir"' RETURN

  printf "\n"
  _gum_header "⚡ 供应商速度测试 (stream, 2轮取优, 超时 ${TEST_TIMEOUT}s)"
  printf "\n  %b⏳ 串行测试 %d 个供应商 (每个 2 轮取较快值) ...%b\n\n" "$YELLOW" "$PROVIDER_COUNT" "$NC"

  local num_col=$(_pad_right "#" 5)
  local name_col=$(_pad_right "供应商" 38)
  local http_col=$(_pad_right "状态" 10)
  printf -v ttft_col "%9s" "TTFT"
  printf -v total_col "%9s" "总耗时"
  local model_col=$(_pad_right "返回模型" 28)
  local token_col=$(_pad_right "Tokens" 12)

  printf "%b%s%s%s%s %s %s%s回复/错误%b\n" "$CYAN" "$num_col" "$name_col" "$http_col" "$ttft_col" "$total_col" "$model_col" "$token_col" "$NC"
  printf "%b%s%b\n" "$DIM" "$(printf '─%.0s' {1..140})" "$NC"

  for entry in "${PROVIDERS[@]}"; do
    _test_one_live "$entry" "$result_file"
  done

  local pass=$(grep -c "^OK$" "$result_file" 2>/dev/null || echo 0)
  local fail=$(grep -c "^FAIL$" "$result_file" 2>/dev/null || echo 0)

  printf "%b%s%b\n" "$DIM" "$(printf '─%.0s' {1..140})" "$NC"
  printf "  %b✅ 可用: %d%b    %b❌ 不可用: %d%b    共 %d 个供应商\n\n" \
    "$GREEN" "$pass" "$NC" "$RED" "$fail" "$NC" "$((pass + fail))"
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
  if ! read -r current_url current_model < <(python3 -c "
import json, sys
try:
  d = json.load(open('$CLAUDE_SETTINGS'))
  env = d.get('env', {})
  print(env.get('ANTHROPIC_BASE_URL', '未知'), env.get('ANTHROPIC_MODEL', '未知'))
except Exception as e:
  print('ERROR', str(e), file=sys.stderr)
  sys.exit(1)
" 2>/dev/null); then
    _gum_log error "配置文件格式错误或损坏"
    return 1
  fi

  if [[ "$current_url" == "未知" ]]; then
    _gum_log warn "配置文件缺少必要字段"
  fi

  printf "%b配置文件:%b %s\n" "$BLUE" "$NC" "$CLAUDE_SETTINGS"
  printf "%bAPI 端点:%b %s\n" "$BLUE" "$NC" "$current_url"
  printf "%b模型:%b %s\n" "$BLUE" "$NC" "$current_model"

  # 从数组匹配当前供应商
  local provider_name="未知"
  for entry in "${PROVIDERS[@]}"; do
    _parse_provider "$entry"
    if [[ "$current_url" == "$P_URL" ]]; then
      provider_name="$P_NAME"
      break
    fi
  done

  printf "%b当前供应商:%b %s\n" "$BLUE" "$NC" "$provider_name"
  echo ""
}

# ── 备份 (自动清理旧备份) ──
backup_config() {
  [[ ! -f "$CLAUDE_SETTINGS" ]] && return
  local timestamp=$(date +%Y%m%d_%H%M%S)
  local backup_file="$BACKUP_DIR/settings.json.backup.${timestamp}.$$"
  cp "$CLAUDE_SETTINGS" "$backup_file"
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
      _gum_log info "已恢复到之前的配置"
    fi
    return 1
  fi

  _gum_log info "✓ 配置已更新!"
  echo ""
  show_status

  # 如果在 Claude Code 内部运行，不能嵌套启动
  if [[ -n "${CLAUDECODE:-}" ]]; then
    _gum_log warn "当前在 Claude Code 会话内，配置已更新。"
    _gum_log warn "请退出当前会话后重新运行 claude 生效。"
    echo ""
    return 0
  fi

  _gum_log info "正在启动 Claude Code..."
  echo ""
  exec claude --dangerously-skip-permissions
}

# ── 动态菜单 ──
show_menu() {
  # 获取当前供应商 URL
  local current_url=""
  if [[ -f "$CLAUDE_SETTINGS" ]]; then
    current_url=$(python3 -c "
import json
d = json.load(open('$CLAUDE_SETTINGS'))
print(d.get('env', {}).get('ANTHROPIC_BASE_URL', ''))
" 2>/dev/null)
  fi

  _gum_header "🔧 Claude Code 供应商切换工具"
  echo ""
  echo "请选择一个供应商:"
  echo ""
  for entry in "${PROVIDERS[@]}"; do
    _parse_provider "$entry"
    if [[ "$current_url" == "$P_URL" ]]; then
      printf "  %b%s)%b %s %b◀ 当前%b\n" "$GREEN" "$P_NUM" "$NC" "$P_NAME" "$YELLOW" "$NC"
    else
      printf "  %b%s)%b %s\n" "$GREEN" "$P_NUM" "$NC" "$P_NAME"
    fi
  done
  echo ""
  printf "  %b0)%b 速度测试 (并行测试所有供应商)\n" "$YELLOW" "$NC"
  printf "  %bv)%b 功能验证 (工具调用/模型一致性)\n" "$YELLOW" "$NC"
  printf "  %bm)%b 模型列表 (查询供应商可用模型)\n" "$YELLOW" "$NC"
  printf "  %bq)%b 退出\n" "$RED" "$NC"
  printf "  %b[回车]%b 使用当前供应商重新启动\n" "$DIM" "$NC"
  echo ""
}

# ── 模型选择菜单 ──
ask_for_model() {
  local provider_name="$1"
  printf "%b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n" "$CYAN" "$NC"
  printf "%b供应商：%s%b\n" "$BLUE" "$provider_name" "$NC"
  printf "%b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n" "$CYAN" "$NC"
  echo ""
  printf "请选择模型 (直接回车默认 %s):\n" "$DEFAULT_MODEL"
  echo "  1) claude-opus-4-6 (最强)"
  echo "  2) claude-sonnet-4-6 (均衡)"
  echo "  3) claude-haiku-4-5-20251001 (快速)"
  echo "  4) gpt-5.4 (GPT 主模型)"
  echo "  5) gpt-5.2 (GPT 均衡)"
  echo "  6) gpt-5-mini (GPT 快速)"
  echo "  7) qwen3.5-plus (通义千问)"
  echo "  8) kimi-k2.5 (Kimi)"
  echo "  9) 手动输入模型名称"
  echo "  b) 返回主菜单"
  echo ""
  read -p "输入选项 (1-9/b/回车): " model_choice

  case "$model_choice" in
    1) CUSTOM_MODEL="claude-opus-4-6" ;;
    2) CUSTOM_MODEL="claude-sonnet-4-6" ;;
    3) CUSTOM_MODEL="claude-haiku-4-5-20251001" ;;
    4) CUSTOM_MODEL="gpt-5.4" ;;
    5) CUSTOM_MODEL="gpt-5.2" ;;
    6) CUSTOM_MODEL="gpt-5-mini" ;;
    7) CUSTOM_MODEL="qwen3.5-plus" ;;
    8) CUSTOM_MODEL="kimi-k2.5" ;;
    9)
      read -p "请输入模型名称: " CUSTOM_MODEL
      ;;
    b|B)
      printf "%b已取消%b\n" "$YELLOW" "$NC"
      echo ""
      return 1
      ;;
    "")
      CUSTOM_MODEL=""
      ;;
    *)
      printf "%b无效选项，使用默认模型%b\n" "$YELLOW" "$NC"
      CUSTOM_MODEL=""
      ;;
  esac

  if [[ -n "$CUSTOM_MODEL" ]]; then
    printf "使用模型：%b%s%b\n" "$GREEN" "$CUSTOM_MODEL" "$NC"
  else
    printf "使用默认模型：%b%s%b\n" "$GREEN" "$DEFAULT_MODEL" "$NC"
  fi
  echo ""
}

# ── 显示帮助 (动态生成) ──
show_help() {
  echo "Claude Code 供应商切换脚本"
  echo ""
  echo "用法:"
  echo "  ~/cc.sh           # 交互式菜单"
  echo "  ~/cc.sh 0         # 速度测试所有供应商"
  for entry in "${PROVIDERS[@]}"; do
    _parse_provider "$entry"
    printf "  ~/cc.sh %-10s # 切换到 %s\n" "$P_NUM" "$P_NAME"
  done
  echo "  ~/cc.sh models    # 查询所有供应商可用模型"
  echo "  ~/cc.sh models 1  # 查询指定供应商可用模型"
  echo "  ~/cc.sh status    # 查看当前配置"
  echo "  ~/cc.sh -m <model>   # 指定模型 (默认：claude-opus-4-6)"
  echo ""
  echo "示例:"
  echo "  ~/cc.sh 1 -m claude-sonnet-4-6   # 使用供应商 1，指定 sonnet 模型"
  echo "  ~/cc.sh 6 -m qwen3.5-plus        # 使用供应商 6，指定通义千问模型"
  echo "  ~/cc.sh 5 -m gpt-5.4             # 使用供应商 5，指定 GPT-5.4 模型"
  echo ""
}

# ── 后台测速 + 前台选择 ──
_bg_speed_test_pid=""

_cleanup_bg_test() {
  if [[ -n "$_bg_speed_test_pid" ]] && kill -0 "$_bg_speed_test_pid" 2>/dev/null; then
    kill "$_bg_speed_test_pid" 2>/dev/null
    wait "$_bg_speed_test_pid" 2>/dev/null
  fi
  _bg_speed_test_pid=""
}

# 后台测速：结果实时打印，不阻塞用户输入
run_speed_test_bg() {
  _cleanup_bg_test
  run_speed_test &
  _bg_speed_test_pid=$!
}

# ── 主函数 ──
main() {
  trap '_cleanup_bg_test' EXIT

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
        read -p "请输入选项 (0-${PROVIDER_COUNT}/v/m/q/回车=当前): " choice
        case "$choice" in
          0)
            run_speed_test
            ;;
          [1-9]|10)
            _cleanup_bg_test
            if [[ -z "$CUSTOM_MODEL" && -t 0 ]]; then
              local entry
              entry=$(_find_provider "$choice") || {
                _gum_log error "无效的选项 $choice"
                continue
              }
              _parse_provider "$entry"
              ask_for_model "$P_NAME" || continue
            fi
            switch_provider "$choice"
            break
            ;;
          v|verify)
            read -p "验证哪个供应商编号 (回车=全部): " vnum
            if [[ -z "$vnum" ]]; then
              for entry in "${PROVIDERS[@]}"; do
                _parse_provider "$entry"
                verify_provider "$P_NUM"
              done
            else
              verify_provider "$vnum"
            fi
            ;;
          m|models)
            read -p "查询哪个供应商编号 (回车=全部): " mnum
            run_list_models "$mnum"
            ;;
          q|quit) echo "退出"; exit 0 ;;
          "")
            # 直接回车：使用当前配置的供应商
            local current_url
            current_url=$(python3 -c "
import json
d = json.load(open('$CLAUDE_SETTINGS'))
print(d.get('env', {}).get('ANTHROPIC_BASE_URL', ''))
" 2>/dev/null)
            if [[ -n "$current_url" ]]; then
              local current_num=""
              for entry in "${PROVIDERS[@]}"; do
                _parse_provider "$entry"
                if [[ "$current_url" == "$P_URL" ]]; then
                  current_num="$P_NUM"
                  break
                fi
              done
              if [[ -n "$current_num" ]]; then
                _gum_log info "使用当前供应商：$current_num"
                _cleanup_bg_test
                if [[ -z "$CUSTOM_MODEL" && -t 0 ]]; then
                  local entry
                  entry=$(_find_provider "$current_num") || {
                    _gum_log error "无法找到当前供应商"
                    continue
                  }
                  _parse_provider "$entry"
                  ask_for_model "$P_NAME" || continue
                fi
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
    0|test)
      run_speed_test
      ;;
    [1-9]|10)
      switch_provider "$1"
      ;;
    verify|v)
      if [[ -z "${2:-}" ]]; then
        # 无参数：对所有供应商依次验证
        for entry in "${PROVIDERS[@]}"; do
          _parse_provider "$entry"
          verify_provider "$P_NUM"
        done
      else
        verify_provider "$2"
      fi
      ;;
    models|m)
      run_list_models "${2:-}"
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
