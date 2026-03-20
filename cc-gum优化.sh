#!/usr/local/bin/bash

# Claude Code 供应商切换脚本 (gum 美化版)
# 用法：~/cc.sh [选项]
#   无参数：交互式选择
#   1-N: 直接选择对应供应商
#   0/test: 速度测试
#   status: 查看当前配置
#   -m <model>: 指定模型（不指定默认为 claude-opus-4-6）

set -e

# 配置目录
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
BACKUP_DIR="$HOME/.claude/backups"
MAX_BACKUPS=10

mkdir -p "$BACKUP_DIR"

# 颜色定义 (非 gum 输出部分继续使用)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

# 检测是否为交互式终端
IS_TTY=false
[[ -t 0 ]] && IS_TTY=true

# ── 供应商数据 (唯一数据源) ──
# 格式: 编号|名称|URL|Token|模型|haiku模型|sonnet模型|small_fast模型
# haiku/sonnet/small_fast 留空则与主模型相同
PROVIDERS=(
  "1|Super 特价 CC (newcli/super)|https://code.newcli.com/claude/super|sk-ant-oat01-II5Pqj8w3LkOqYbsXVeil1kg-8xkYflCtjZafD833B6imrsfQ4M-dG-iJIPSB_4WgGYdYerqvdnYh-Zr47y_d8pOMKEXQAA|claude-opus-4-6|||"
  "2|Ultra 特价 CC (newcli/ultra)|https://code.newcli.com/claude/ultra|sk-ant-oat01-II5Pqj8w3LkOqYbsXVeil1kg-8xkYflCtjZafD833B6imrsfQ4M-dG-iJIPSB_4WgGYdYerqvdnYh-Zr47y_d8pOMKEXQAA|claude-opus-4-6|||"
  "3|AWS 特价 CC (newcli/droid 思考)|https://code.newcli.com/claude/droid|sk-ant-oat01-II5Pqj8w3LkOqYbsXVeil1kg-8xkYflCtjZafD833B6imrsfQ4M-dG-iJIPSB_4WgGYdYerqvdnYh-Zr47y_d8pOMKEXQAA|claude-opus-4-6|||"
  "4|AWS 特价 CC (newcli/aws)|https://code.newcli.com/claude/aws|sk-ant-oat01-II5Pqj8w3LkOqYbsXVeil1kg-8xkYflCtjZafD833B6imrsfQ4M-dG-iJIPSB_4WgGYdYerqvdnYh-Zr47y_d8pOMKEXQAA|claude-opus-4-6|||"
  "5|LinkAPI (GPT-5.4)|https://api.linkapi.ai|sk-7NoV0BobP08hph5PrQormauliECHLOJU7NPFSSU8RMbidBza|gpt-5.4|gpt-5-mini|gpt-5.2|gpt-5-mini"
  "6|PuCode (api.pucode.com)|https://api.pucode.com|sk-hqhrgEo8zJXKaBFzQWIn3GShov9nDj9rWBpunCcCtXUtT9GC|claude-opus-4-6|claude-haiku-4-5-20251001|claude-sonnet-4-6|claude-haiku-4-5-20251001"
  "7|AiCoding (api.aicoding.sh)|https://api.aicoding.sh|aicoding-53023984484a878506ec4082938d6b2e|claude-opus-4-6|||"
  "8|中转 (zhongzhuan.win)|https://api.zhongzhuan.win/v1|sk-lcTMEbXxAhrP27hpcdBNf8eSxCWNw6ENuEzaZ34IDHJ53oHV|claude-opus-4-6|||"
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
# 带圆角边框的标题
_gum_header() {
  local title="$1"
  local color="${2:-99}"
  gum style --border rounded --border-foreground "$color" --padding "0 2" --bold "$title"
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
  trap 'rm -f "$tmp_out"' RETURN

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
  parsed=$(cat "$tmp_out")
  rm -f "$tmp_out"
  trap - RETURN

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

# 格式化耗时
_format_ms() {
  local ms="$1"
  if (( ms > 1000 )); then
    perl -e "printf '%.1fs', $ms/1000"
  else
    echo "${ms}ms"
  fi
}

# 测试单个供应商 (2 轮取较快值) — 收集 CSV 行到结果文件
_test_one_collect() {
  local entry="$1" csv_file="$2" status_file="$3"
  _parse_provider "$entry"

  local best_ttft=999999 best_total=999999 best_line="" status_tag="FAIL"
  local round=1 rounds=2

  # 实时显示进度
  printf "  ⏳ [%s/%d] %s ..." "$P_NUM" "$PROVIDER_COUNT" "$P_NAME"

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
        local ttft_fmt=$(_format_ms "$best_ttft")
        local total_fmt=$(_format_ms "$best_total")
        # 截断过长的回复
        if [[ ${#reply} -gt 40 ]]; then
          reply="${reply:0:37}..."
        fi
        best_line="${P_NUM},${P_NAME},✅ 200,${ttft_fmt},${total_fmt},${ret_model:-—},${tokens:-—},${reply}"
        status_tag="OK"
      fi
    else
      local total=$(echo "$result" | cut -d'|' -f2)
      local errmsg=$(echo "$result" | cut -d'|' -f3-)
      # 首轮失败则跳过第二轮
      if [[ -z "$best_line" ]]; then
        local total_fmt=$(_format_ms "$total")
        # 截断过长的错误信息
        if [[ ${#errmsg} -gt 40 ]]; then
          errmsg="${errmsg:0:37}..."
        fi
        best_line="${P_NUM},${P_NAME},❌ FAIL,${total_fmt},${total_fmt},—,—,${errmsg}"
      fi
      break
    fi
    (( round++ ))
  done

  if [[ "$status_tag" == "OK" ]]; then
    printf "\r  ✅ [%s/%d] %s — TTFT $(_format_ms "$best_ttft")  \n" "$P_NUM" "$PROVIDER_COUNT" "$P_NAME"
  else
    printf "\r  ❌ [%s/%d] %s — FAIL  \n" "$P_NUM" "$PROVIDER_COUNT" "$P_NAME"
  fi

  echo "$best_line" >> "$csv_file"
  echo "$status_tag" >> "$status_file"
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
    gum log --level error "无效的供应商编号 $num"
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

  echo ""
  gum style --foreground 99 --bold "  [${P_NUM}] ${P_NAME}"
  gum style --foreground 245 "  端点: ${models_url}"

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
    gum log --level error "连接超时 (${VERIFY_TIMEOUT}s)"
    return
  fi

  local parsed=$(echo "$body" | _parse_models_response)
  local tag=$(echo "$parsed" | cut -d'|' -f1)

  if [[ "$tag" == "OK" ]]; then
    local model_list=$(echo "$parsed" | cut -d'|' -f2-)
    local count=$(echo "$model_list" | tr '|' '\n' | wc -l | tr -d ' ')
    gum log --level info "HTTP ${http_code} ($(perl -e "printf '%.1f',$duration/1000")s, 共 ${count} 个模型)"

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
      gum style --foreground 69 --bold "  Claude 系列:"
      printf "%b" "$claude_models"
    fi
    if [[ -n "$gpt_models" ]]; then
      gum style --foreground 69 --bold "  GPT/OpenAI 系列:"
      printf "%b" "$gpt_models"
    fi
    if [[ -n "$other_models" ]]; then
      gum style --foreground 69 --bold "  其他模型:"
      printf "%b" "$other_models"
    fi
  else
    local errmsg=$(echo "$parsed" | cut -d'|' -f2-)
    gum log --level error "HTTP ${http_code} ($(perl -e "printf '%.1f',$duration/1000")s) ${errmsg}"
  fi
  echo ""
}

run_list_models() {
  echo ""
  _gum_header "📋 供应商可用模型列表查询"
  echo ""

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
    gum log --level error "无效的供应商编号 $num"
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

  echo ""
  _gum_header "🔍 功能验证：${P_NAME}" 212
  echo ""
  gum log --level info "模型: ${P_MODEL}"
  gum log --level info "端点: ${test_url}"
  echo ""

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

  echo ""
}

run_speed_test() {
  local work_dir=$(mktemp -d)
  local csv_file="${work_dir}/results.csv"
  local status_file="${work_dir}/status"
  touch "$csv_file" "$status_file"
  trap 'rm -rf "$work_dir"' RETURN

  echo ""
  _gum_header "⚡ 供应商速度测试 (stream, 2轮取优, 超时 ${TEST_TIMEOUT}s)"
  echo ""
  gum log --level info "串行测试 ${PROVIDER_COUNT} 个供应商 (每个 2 轮取较快值) ..."
  echo ""

  for entry in "${PROVIDERS[@]}"; do
    _test_one_collect "$entry" "$csv_file" "$status_file"
  done

  local pass=$(grep -c "^OK$" "$status_file" 2>/dev/null || echo 0)
  local fail=$(grep -c "^FAIL$" "$status_file" 2>/dev/null || echo 0)

  echo ""

  # 用 gum table 渲染汇总结果
  if [[ -s "$csv_file" ]]; then
    (echo "#,供应商,状态,TTFT,总耗时,返回模型,Tokens,回复/错误"; cat "$csv_file") \
      | gum table --separator "," --print \
          --border.foreground 99 \
          --header.foreground 99 \
          --cell.foreground 252
  fi

  echo ""
  gum style --foreground 82 --bold "  ✅ 可用: ${pass}    ❌ 不可用: ${fail}    共 $((pass + fail)) 个供应商"
  echo ""
}

# ── 显示当前配置 ──
show_status() {
  _gum_header "📊 Claude Code 当前配置"
  echo ""

  if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
    gum log --level error "未找到配置文件 ${CLAUDE_SETTINGS}"
    return 1
  fi

  local current_url current_model
  read -r current_url current_model < <(python3 -c "
import json
d = json.load(open('$CLAUDE_SETTINGS'))
env = d.get('env', {})
print(env.get('ANTHROPIC_BASE_URL', '未知'), env.get('ANTHROPIC_MODEL', '未知'))
" 2>/dev/null || echo "未知 未知")

  # 从数组匹配当前供应商
  local provider_name="未知"
  for entry in "${PROVIDERS[@]}"; do
    _parse_provider "$entry"
    if [[ "$current_url" == "$P_URL" ]]; then
      provider_name="$P_NAME"
      break
    fi
  done

  gum style --foreground 245 "  配置文件: ${CLAUDE_SETTINGS}"
  gum style --foreground 81 "  API 端点: ${current_url}"
  gum style --foreground 82 "  模型:     ${current_model}"
  gum style --foreground 214 --bold "  供应商:   ${provider_name}"
  echo ""
}

# ── 备份 (自动清理旧备份) ──
backup_config() {
  [[ ! -f "$CLAUDE_SETTINGS" ]] && return
  local timestamp=$(date +%Y%m%d_%H%M%S)
  local backup_file="$BACKUP_DIR/settings.json.backup.$timestamp"
  cp "$CLAUDE_SETTINGS" "$backup_file"
  gum log --level info "配置已备份到：${backup_file}"

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
    gum log --level error "无效的选项 $1"
    return 1
  }

  _parse_provider "$entry"

  # 交互式模式下用 gum confirm 确认
  if [[ "$IS_TTY" == true ]]; then
    local confirm_msg="切换到 ${P_NAME}"
    [[ -n "$CUSTOM_MODEL" ]] && confirm_msg+=" (模型: ${CUSTOM_MODEL})"
    confirm_msg+=" ？"
    if ! gum confirm "$confirm_msg" --affirmative "确认切换" --negative "取消"; then
      gum log --level warn "已取消切换"
      return 1
    fi
  fi

  echo ""
  if [[ -n "$CUSTOM_MODEL" ]]; then
    gum log --level info "正在切换到：${P_NAME} (模型：${CUSTOM_MODEL})"
  else
    gum log --level info "正在切换到：${P_NAME}"
  fi
  echo ""

  backup_config
  local tmp_config
  tmp_config=$(mktemp) || { gum log --level error "无法创建临时文件"; return 1; }
  if ! generate_config "$entry" > "$tmp_config" || ! mv "$tmp_config" "$CLAUDE_SETTINGS"; then
    rm -f "$tmp_config"
    gum log --level error "配置写入失败，正在恢复备份..."
    local latest_backup
    latest_backup=$(ls -1t "$BACKUP_DIR"/settings.json.backup.* 2>/dev/null | head -1)
    if [[ -n "$latest_backup" ]]; then
      cp "$latest_backup" "$CLAUDE_SETTINGS"
      gum log --level info "已恢复到之前的配置"
    fi
    return 1
  fi

  gum log --level info "✓ 配置已更新!"
  echo ""
  show_status

  # 如果在 Claude Code 内部运行，不能嵌套启动
  if [[ -n "${CLAUDECODE:-}" ]]; then
    gum log --level warn "当前在 Claude Code 会话内，配置已更新。"
    gum log --level warn "请退出当前会话后重新运行 claude 生效。"
    echo ""
    return 0
  fi

  gum log --level info "正在启动 Claude Code..."
  echo ""
  exec claude --dangerously-skip-permissions
}

# ── 交互式菜单 — gum choose ──
show_menu_and_choose() {
  # 获取当前供应商 URL
  local current_url=""
  if [[ -f "$CLAUDE_SETTINGS" ]]; then
    current_url=$(python3 -c "
import json
d = json.load(open('$CLAUDE_SETTINGS'))
print(d.get('env', {}).get('ANTHROPIC_BASE_URL', ''))
" 2>/dev/null)
  fi

  echo ""
  _gum_header "🔧 Claude Code 供应商切换工具" 212
  echo ""

  # 构建选项列表
  local options=()
  for entry in "${PROVIDERS[@]}"; do
    _parse_provider "$entry"
    local label="${P_NUM}) ${P_NAME}"
    if [[ "$current_url" == "$P_URL" ]]; then
      label+=" ◀ 当前"
    fi
    options+=("$label")
  done
  options+=("─────────────────────────────")
  options+=("0) ⚡ 速度测试 (所有供应商)")
  options+=("v) 🔍 功能验证 (工具调用/模型一致性)")
  options+=("m) 📋 模型列表 (查询供应商可用模型)")
  options+=("q) 🚪 退出")

  local choice
  choice=$(gum choose --header "请选择一个操作:" \
    --cursor "▸ " \
    --cursor.foreground 212 \
    --header.foreground 99 \
    --selected.foreground 82 \
    --height 20 \
    "${options[@]}" 2>/dev/null) || { echo "q) 🚪 退出"; return; }

  echo "$choice"
}

# ── 模型选择菜单 — gum choose ──
ask_for_model() {
  local provider_name="$1"

  echo ""
  _gum_header "🎯 选择模型 — ${provider_name}" 214

  local model_options=(
    "claude-opus-4-6 (最强)"
    "claude-sonnet-4-6 (均衡)"
    "claude-haiku-4-5-20251001 (快速)"
    "gpt-5.4 (GPT 主模型)"
    "gpt-5.2 (GPT 均衡)"
    "gpt-5-mini (GPT 快速)"
    "qwen3.5-plus (通义千问)"
    "kimi-k2.5 (Kimi)"
    "✏️  手动输入模型名称"
    "↩️  使用默认模型 (${DEFAULT_MODEL})"
    "❌ 返回主菜单"
  )

  local choice
  choice=$(gum choose --header "请选择模型:" \
    --cursor "▸ " \
    --cursor.foreground 214 \
    --header.foreground 99 \
    --selected.foreground 82 \
    --height 15 \
    "${model_options[@]}" 2>/dev/null) || {
    gum log --level warn "已取消"
    return 1
  }

  case "$choice" in
    "claude-opus-4-6 (最强)") CUSTOM_MODEL="claude-opus-4-6" ;;
    "claude-sonnet-4-6 (均衡)") CUSTOM_MODEL="claude-sonnet-4-6" ;;
    "claude-haiku-4-5-20251001 (快速)") CUSTOM_MODEL="claude-haiku-4-5-20251001" ;;
    "gpt-5.4 (GPT 主模型)") CUSTOM_MODEL="gpt-5.4" ;;
    "gpt-5.2 (GPT 均衡)") CUSTOM_MODEL="gpt-5.2" ;;
    "gpt-5-mini (GPT 快速)") CUSTOM_MODEL="gpt-5-mini" ;;
    "qwen3.5-plus (通义千问)") CUSTOM_MODEL="qwen3.5-plus" ;;
    "kimi-k2.5 (Kimi)") CUSTOM_MODEL="kimi-k2.5" ;;
    "✏️  手动输入模型名称")
      CUSTOM_MODEL=$(gum input --placeholder "输入模型名称..." --prompt "模型: " --cursor.mode "blink" 2>/dev/null) || {
        gum log --level warn "已取消"
        return 1
      }
      if [[ -z "$CUSTOM_MODEL" ]]; then
        gum log --level warn "未输入模型名称，使用默认模型"
        CUSTOM_MODEL=""
      fi
      ;;
    "↩️  使用默认模型 (${DEFAULT_MODEL})")
      CUSTOM_MODEL=""
      ;;
    "❌ 返回主菜单")
      return 1
      ;;
    *)
      CUSTOM_MODEL=""
      ;;
  esac

  if [[ -n "$CUSTOM_MODEL" ]]; then
    gum log --level info "使用模型：${CUSTOM_MODEL}"
  else
    gum log --level info "使用默认模型：${DEFAULT_MODEL}"
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

# ── 从 gum choose 结果提取编号 ──
_extract_choice_num() {
  local choice="$1"
  echo "$choice" | sed -n 's/^\([0-9]*\)).*/\1/p'
}

_extract_choice_action() {
  local choice="$1"
  echo "$choice" | sed -n 's/^\([a-z]\)).*/\1/p'
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
          gum log --level error "-m/--model 需要传入模型名称"
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
        local raw_choice
        raw_choice=$(show_menu_and_choose)
        local num=$(_extract_choice_num "$raw_choice")
        local action=$(_extract_choice_action "$raw_choice")

        if [[ -n "$num" ]]; then
          if [[ "$num" == "0" ]]; then
            run_speed_test_bg
          elif (( num >= 1 && num <= PROVIDER_COUNT )); then
            _cleanup_bg_test
            if [[ -z "$CUSTOM_MODEL" && "$IS_TTY" == true ]]; then
              local entry
              entry=$(_find_provider "$num") || {
                gum log --level error "无效的选项 $num"
                continue
              }
              _parse_provider "$entry"
              ask_for_model "$P_NAME" || continue
            fi
            switch_provider "$num"
            break
          else
            gum log --level error "无效选项"
          fi
        elif [[ -n "$action" ]]; then
          case "$action" in
            v)
              # 用 gum choose 选择要验证的供应商
              local vopts=("全部供应商")
              for entry in "${PROVIDERS[@]}"; do
                _parse_provider "$entry"
                vopts+=("${P_NUM}) ${P_NAME}")
              done
              local vchoice
              vchoice=$(gum choose --header "验证哪个供应商？" \
                --cursor "▸ " --cursor.foreground 212 \
                --header.foreground 99 --height 15 \
                "${vopts[@]}" 2>/dev/null) || continue
              if [[ "$vchoice" == "全部供应商" ]]; then
                for entry in "${PROVIDERS[@]}"; do
                  _parse_provider "$entry"
                  verify_provider "$P_NUM"
                done
              else
                local vnum=$(_extract_choice_num "$vchoice")
                [[ -n "$vnum" ]] && verify_provider "$vnum"
              fi
              ;;
            m)
              # 用 gum choose 选择要查询的供应商
              local mopts=("全部供应商")
              for entry in "${PROVIDERS[@]}"; do
                _parse_provider "$entry"
                mopts+=("${P_NUM}) ${P_NAME}")
              done
              local mchoice
              mchoice=$(gum choose --header "查询哪个供应商的模型？" \
                --cursor "▸ " --cursor.foreground 212 \
                --header.foreground 99 --height 15 \
                "${mopts[@]}" 2>/dev/null) || continue
              if [[ "$mchoice" == "全部供应商" ]]; then
                run_list_models ""
              else
                local mnum=$(_extract_choice_num "$mchoice")
                [[ -n "$mnum" ]] && run_list_models "$mnum"
              fi
              ;;
            q) echo ""; gum log --level info "再见 👋"; exit 0 ;;
            *) gum log --level error "无效选项" ;;
          esac
        elif [[ "$raw_choice" == *"─────"* ]]; then
          # 分隔线，忽略
          continue
        else
          gum log --level error "无效选项"
        fi
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
      gum log --level error "未知选项：$1"
      echo "运行 ~/cc.sh help 查看用法"
      exit 1
      ;;
  esac
}

main "$@"
