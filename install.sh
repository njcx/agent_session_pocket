#!/usr/bin/env bash
# install-agent-session-export.sh
# 清理旧版 → 安装 agent-session-export + Claude SessionEnd
# + claude-s/codex-s/pi-s（有 .session 则启动 resume，退出导出）
# 兼容 Linux / macOS
set -euo pipefail

PREFIX="${PREFIX:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
BIN="$BIN_DIR/agent-session-export"
HOOK_DIR="$HOME/.claude/hooks"
HOOK_SH="$HOOK_DIR/export-session-to-project.sh"
SETTINGS="$HOME/.claude/settings.json"
BLOCK_BEGIN="# >>> agent-session-export >>>"
BLOCK_END="# <<< agent-session-export <<<"

echo "==> OS: $(uname -s)  bash: ${BASH_VERSION:-unknown}"
echo "==> prefix: $PREFIX"

# ---------------------------------------------------------------------------
# 前置) 强制依赖检查：jq / python3，缺失即中止
# ---------------------------------------------------------------------------
_OS="$(uname -s)"
_missing=""
for _dep in jq python3; do
  if ! command -v "$_dep" >/dev/null 2>&1; then
    _missing="$_missing $_dep"
  fi
done
if [ -n "$_missing" ]; then
  echo "==> error: missing required dependencies:$_missing" >&2
  echo "    请先安装后重试:" >&2
  case "$_OS" in
    Darwin)
      echo "      brew install jq python3" >&2 ;;
    *)
      echo "      sudo apt install jq python3    # Debian/Ubuntu" >&2
      echo "      sudo dnf install jq python3    # Fedora/RHEL" >&2 ;;
  esac
  exit 1
fi
echo "==> deps OK: jq / python3"

# ---------------------------------------------------------------------------
# 0) 清理旧安装
# ---------------------------------------------------------------------------
echo "==> cleaning previous install..."

rm -f "$BIN" 2>/dev/null || true
rm -f "$HOOK_SH" 2>/dev/null || true
rm -f "$HOME/.local/bin/agent-session-export" 2>/dev/null || true
rm -f "$HOME/.claude/hooks/export-session-to-project.sh" 2>/dev/null || true

if command -v python3 >/dev/null 2>&1 && [ -f "$SETTINGS" ]; then
  SETTINGS="$SETTINGS" python3 << 'PY'
import json, os
from pathlib import Path
path = Path(os.environ["SETTINGS"])
try:
    data = json.loads(path.read_text(encoding="utf-8") or "{}")
except Exception:
    raise SystemExit(0)
hooks = data.get("hooks")
if not isinstance(hooks, dict):
    raise SystemExit(0)
se = hooks.get("SessionEnd")
if not isinstance(se, list):
    raise SystemExit(0)

def is_ours(group):
    for h in (group or {}).get("hooks") or []:
        cmd = str(h.get("command") or "")
        if "export-session-to-project" in cmd or "agent-session-export" in cmd:
            return True
    return False

new_se = [g for g in se if not is_ours(g)]
if len(new_se) != len(se):
    if new_se:
        hooks["SessionEnd"] = new_se
    else:
        hooks.pop("SessionEnd", None)
    if not hooks:
        data.pop("hooks", None)
    path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print("==> removed old SessionEnd export hook")
else:
    print("==> no old export hook in settings.json")
PY
else
  echo "==> skip settings.json cleanup"
fi

strip_block() {
  _rc="$1"
  [ -f "$_rc" ] || return 0
  grep -q 'agent-session-export >>>' "$_rc" 2>/dev/null || return 0
  _tmp=$(mktemp "${TMPDIR:-/tmp}/ase.XXXXXX")
  awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
    $0 == b { skip=1; next }
    $0 == e { skip=0; next }
    !skip { print }
  ' "$_rc" > "$_tmp"
  mv "$_tmp" "$_rc"
  echo "==> removed old block from $_rc"
}
strip_block "$HOME/.bashrc"
strip_block "$HOME/.zshrc"
echo "==> cleanup done"

# ---------------------------------------------------------------------------
# 0.5) session-migrate（跨 agent 会话迁移）—— 强制依赖，缺失即中止
# ---------------------------------------------------------------------------
if command -v session-migrate >/dev/null 2>&1 || command -v smigrate >/dev/null 2>&1; then
  echo "==> session-migrate already installed"
else
  if ! command -v uv >/dev/null 2>&1; then
    echo "==> error: uv not found" >&2
    echo "    请先安装 uv:" >&2
    echo "      curl -LsSf https://astral.sh/uv/install.sh | sh" >&2
    exit 1
  fi
  echo "==> installing session-migrate via uv..."
  if ! uv tool install session-migrate; then
    echo "==> error: session-migrate install failed" >&2
    echo "    请手动排查后重试: uv tool install session-migrate" >&2
    exit 1
  fi
fi

# 安装后校验：命令必须可用（PATH 可能未刷新，补查 uv tool bin 目录）
if ! command -v session-migrate >/dev/null 2>&1 && ! command -v smigrate >/dev/null 2>&1; then
  _uv_bin=$(uv tool dir 2>/dev/null)/bin
  export PATH="$_uv_bin:$PATH"
fi
if ! command -v session-migrate >/dev/null 2>&1 && ! command -v smigrate >/dev/null 2>&1; then
  echo "==> error: session-migrate 不可用（PATH 未包含 uv tool bin）" >&2
  echo "    请重新打开终端后再运行本脚本" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1) 主脚本 agent-session-export
# ---------------------------------------------------------------------------
mkdir -p "$BIN_DIR" "$HOOK_DIR" "$(dirname "$SETTINGS")"

cat > "$BIN" << 'SCRIPT'
#!/usr/bin/env bash
# agent-session-export — Claude / Codex / Pi → $cwd/.session/
set -euo pipefail

agent="${1:-auto}"
ts=$(date +%Y%m%d-%H%M%S)

expand() {
  _p="${1:-}"
  case "$_p" in
    "~/"*) _p="$HOME/${_p#~/}" ;;
    "~")   _p="$HOME" ;;
  esac
  printf '%s' "$_p"
}

latest_file() {
  _dir="$1"
  shift || true
  [ -d "$_dir" ] || return 0
  _candidates=""
  if [ "$#" -eq 0 ]; then
    set -- "*.jsonl" "*.json" "*.jsonl.zst"
  fi
  for _g in "$@"; do
    _part=$(find "$_dir" -type f -name "$_g" 2>/dev/null || true)
    if [ -n "$_part" ]; then
      if [ -n "$_candidates" ]; then
        _candidates=$(printf '%s\n%s\n' "$_candidates" "$_part")
      else
        _candidates="$_part"
      fi
    fi
  done
  [ -n "$_candidates" ] || return 0
  printf '%s\n' "$_candidates" | xargs ls -t 2>/dev/null | head -n 1 || true
}

copy_one() {
  _src=$(expand "$1")
  _dest_dir="$2"
  _tag="$3"
  _sid="${4:-}"
  [ -f "$_src" ] || return 0
  mkdir -p "$_dest_dir"
  if [ -z "$_sid" ]; then
    _sid=$(basename "$_src")
    _sid=${_sid%.*}
    case "$_sid" in *.jsonl) _sid=${_sid%.jsonl} ;; esac
  fi
  _sid=$(printf '%s' "$_sid" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-80)
  _base=$(basename "$_src")
  _ext="${_base##*.}"
  case "$_base" in
    *.jsonl.zst) _ext="jsonl.zst" ;;
    *.*) ;;
    *) _ext="jsonl" ;;
  esac
  # 去重：与 latest-<tag> 内容一致则跳过（源文件未变化）
  _latest="${_dest_dir}/latest-${_tag}.${_ext}"
  if [ -f "$_latest" ] && cmp -s "$_src" "$_latest"; then
    echo "skip: $_tag session unchanged"
    return 0
  fi
  _out="${_dest_dir}/${ts}-${_tag}-${_sid}.${_ext}"
  cp "$_src" "$_out"
  cp "$_src" "$_latest"
  echo "exported: $_out"
}

export_claude() {
  _transcript="${1:-}"
  _sid="${2:-}"
  _cwd="${3:-$PWD}"
  if [ -z "$_transcript" ] && [ ! -t 0 ]; then
    _input=$(cat 2>/dev/null || true)
    if command -v jq >/dev/null 2>&1 && [ -n "$_input" ]; then
      _sid=$(printf '%s' "$_input" | jq -r '.session_id // empty')
      _transcript=$(printf '%s' "$_input" | jq -r '.transcript_path // empty')
      _jcwd=$(printf '%s' "$_input" | jq -r '.cwd // empty')
      [ -n "$_jcwd" ] && _cwd="$_jcwd"
    fi
  fi
  _transcript=$(expand "${_transcript:-}")
  if [ -n "$_transcript" ] && [ -f "$_transcript" ]; then
    copy_one "$_transcript" "$_cwd/.session" "claude" "$_sid"
    return 0
  fi
  _enc=$(printf '%s' "$_cwd" | sed 's/[^A-Za-z0-9]/-/g')
  _dir="$HOME/.claude/projects/$_enc"
  if [ ! -d "$_dir" ]; then
    _dir=$(ls -dt "$HOME"/.claude/projects/* 2>/dev/null | head -n 1 || true)
  fi
  [ -n "${_dir:-}" ] && [ -d "$_dir" ] || return 0
  _latest=$(ls -t "$_dir"/*.jsonl 2>/dev/null | head -n 1 || true)
  [ -n "$_latest" ] && copy_one "$_latest" "$_cwd/.session" "claude" "$(basename "$_latest" .jsonl)"
}

export_codex() {
  _key="${1:-}"
  _cwd="${2:-$PWD}"
  _src=""
  if [ -n "$_key" ] && [ -f "$(expand "$_key")" ]; then
    _src=$(expand "$_key")
  elif [ -n "$_key" ] && [ -d "$HOME/.codex/sessions" ]; then
    _src=$(find "$HOME/.codex/sessions" -type f -name "*${_key}*" 2>/dev/null | head -n 1 || true)
  fi
  if [ -z "$_src" ]; then
    _src=$(latest_file "$HOME/.codex/sessions" "*.jsonl" "*.jsonl.zst" "*.json")
  fi
  [ -n "$_src" ] && copy_one "$_src" "$_cwd/.session" "codex" ""
}

export_pi() {
  _key="${1:-}"
  _cwd="${2:-$PWD}"
  _src=""
  if [ -n "$_key" ] && [ -f "$(expand "$_key")" ]; then
    _src=$(expand "$_key")
  else
    for _r in \
      "$HOME/.pi/sessions" \
      "$HOME/.pi/agent/sessions" \
      "$HOME/Library/Application Support/pi/sessions"
    do
      [ -d "$_r" ] || continue
      if [ -n "$_key" ]; then
        _src=$(find "$_r" -type f -name "*${_key}*" 2>/dev/null | head -n 1 || true)
      else
        _src=$(latest_file "$_r" "*.jsonl" "*.json")
      fi
      [ -n "$_src" ] && break
    done
  fi
  [ -n "$_src" ] && copy_one "$_src" "$_cwd/.session" "pi" ""
}

export_auto() {
  _cwd="${1:-$PWD}"
  export_claude "" "" "$_cwd" || true
  export_codex "" "$_cwd" || true
  export_pi "" "$_cwd" || true
}

case "$agent" in
  claude)   export_claude "${2:-}" "${3:-}" "${4:-$PWD}" ;;
  codex)    export_codex "${2:-}" "${3:-$PWD}" ;;
  pi)       export_pi "${2:-}" "${3:-$PWD}" ;;
  auto)     export_auto "${2:-$PWD}" ;;
  *)
    echo "usage: agent-session-export {claude|codex|pi|auto} ..." >&2
    exit 1
    ;;
esac
SCRIPT
chmod +x "$BIN"
echo "==> installed $BIN"

# ---------------------------------------------------------------------------
# 2) Claude SessionEnd 包装
# ---------------------------------------------------------------------------
cat > "$HOOK_SH" << EOF
#!/usr/bin/env bash
exec "$BIN" claude
EOF
chmod +x "$HOOK_SH"
echo "==> installed $HOOK_SH"

# ---------------------------------------------------------------------------
# 3) SessionEnd → settings.json
# ---------------------------------------------------------------------------
if command -v python3 >/dev/null 2>&1; then
  SETTINGS="$SETTINGS" HOOK_CMD="$HOOK_SH" python3 << 'PY'
import json, os
from pathlib import Path
path = Path(os.environ["SETTINGS"])
hook_cmd = os.environ["HOOK_CMD"]
data = {}
if path.exists():
    try:
        data = json.loads(path.read_text(encoding="utf-8") or "{}")
    except Exception:
        data = {}
hooks = data.setdefault("hooks", {})
se = hooks.setdefault("SessionEnd", [])
se.append({
    "hooks": [{
        "type": "command",
        "command": hook_cmd,
        "timeout": 30
    }]
})
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print("==> wrote SessionEnd ->", path)
PY
else
  echo "==> python3 missing; add SessionEnd manually: $HOOK_SH"
fi

# ---------------------------------------------------------------------------
# 4) shell 函数：启动 resume（若有 .session）+ 退出导出
# ---------------------------------------------------------------------------
append_rc() {
  _rc="$1"
  touch "$_rc"
  if grep -q 'agent-session-export >>>' "$_rc" 2>/dev/null; then
    _tmp=$(mktemp "${TMPDIR:-/tmp}/ase.XXXXXX")
    awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
      $0 == b { skip=1; next }
      $0 == e { skip=0; next }
      !skip { print }
    ' "$_rc" > "$_tmp"
    mv "$_tmp" "$_rc"
  fi

  {
    echo ""
    echo "$BLOCK_BEGIN"
    echo "export PATH=\"$BIN_DIR:\$PATH\""
    # 单引号 heredoc：保证 "$@" 不被安装时展开、不出现多余引号
    cat << 'FUNCS'
session-snap() { agent-session-export auto "${1:-$PWD}"; }

# ASE_FRESH=1 强制新开，不 resume
# 从 .session/latest-<tag>.* 解析 session id
_ase_latest_id() {
  _tag="$1"
  _dir="${2:-$PWD}/.session"
  [ -d "$_dir" ] || return 1
  _f=
  for _c in "$_dir/latest-${_tag}.jsonl" "$_dir/latest-${_tag}.json" "$_dir/latest-${_tag}.jsonl.zst"; do
    [ -f "$_c" ] && _f="$_c" && break
  done
  if [ -z "$_f" ]; then
    _f=$(ls -t "$_dir"/*-"${_tag}"-* 2>/dev/null | head -n 1 || true)
  fi
  [ -n "$_f" ] && [ -f "$_f" ] || return 1
  _base=$(basename "$_f")
  case "$_base" in
    latest-*)
      if command -v jq >/dev/null 2>&1; then
        _id=$(head -n 50 "$_f" 2>/dev/null | jq -r 'select(.sessionId!=null)|.sessionId' 2>/dev/null | head -n 1)
        # codex rollout: 首行 session_meta 的 id 在 .payload.id
        if [ -z "$_id" ] || [ "$_id" = "null" ]; then
          _id=$(head -n 50 "$_f" 2>/dev/null | jq -r 'select(.type=="session_meta")|.payload.id // empty' 2>/dev/null | head -n 1)
        fi
        if [ -n "$_id" ] && [ "$_id" != "null" ]; then
          printf '%s' "$_id"
          return 0
        fi
      fi
      _id=$(printf '%s' "$_base" | sed 's/^latest-//;s/\.jsonl\.zst$//;s/\.jsonl$//;s/\.json$//')
      # codex: rollout-<ts>-<uuid> → 只要 uuid
      case "$_id" in
        rollout-*) _id=${_id#rollout-}; _id=${_id#*-*-*-*-*-} ;;
      esac
      printf '%s' "$_id"
      return 0
      ;;
    *)
      _id=$(printf '%s' "$_base" | sed "s/^[0-9]\{8\}-[0-9]\{6\}-${_tag}-//;s/\.jsonl\.zst$//;s/\.jsonl$//;s/\.json$//")
      # codex: 剩 rollout-<ts>-<uuid>，剥到 uuid
      if [ "$_tag" = "codex" ]; then
        _id=${_id#rollout-}
        _id=${_id#*-*-*-*-*-}
      fi
      printf '%s' "$_id"
      return 0
      ;;
  esac
}

# 从 stdin 的单对象 JSON 里取字段值（jq 缺失时用 sed 兜底）
_ase_json_field() {
  _k="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg k "$_k" '.[$k] // empty' 2>/dev/null
  else
    sed -n "s/.*\"${_k}\": *\"\([^\"]*\)\".*/\1/p" | head -n 1
  fi
}

# <tag> <id>：该 agent 原生会话目录里是否已有此会话
# <tag> <id> <cwd>：该 agent 原生会话存储里是否已有此会话
# 注意 claude 按目录（project）隔离，只查当前 cwd 对应的项目目录
_ase_native_has() {
  _t="$1"; _i="$2"; _c="${3:-$PWD}"
  case "$_t" in
    claude)
      _enc=$(printf '%s' "$_c" | sed 's/[^A-Za-z0-9]/-/g')
      _d="$HOME/.claude/projects/$_enc"
      if [ -d "$_d" ]; then
        [ -f "$_d/$_i.jsonl" ]
      else
        # 项目目录不存在 → 本 cwd 下不可能有该会话
        return 1
      fi ;;
    codex)    [ -n "$(find "$HOME/.codex/sessions" -name "*$_i*" 2>/dev/null | head -n 1)" ] ;;
    pi)       [ -n "$(find "$HOME/.pi" -name "*$_i*" 2>/dev/null | head -n 1)" ] ;;
    *) return 1 ;;
  esac
}

# 确保 <tag> 有可 resume 的原生会话，成功时 stdout 输出 session id：
# 1) .session 无目录 → 失败，正常新开
# 2) 有该 tag 文件，但原生目录没有（新 agent/新机器）→ import 导入原生目录
# 3) 无该 tag 文件 → 从 .session 内其他 agent 最新文件迁移导入
# 进度信息走 stderr，不污染 stdout 的 id
_ase_ensure_native() {
  _tag="$1"
  _cwd="${2:-$PWD}"
  _dir="$_cwd/.session"
  [ -d "$_dir" ] || return 1
  _sm=""
  if command -v smigrate >/dev/null 2>&1; then
    _sm="smigrate"
  elif command -v session-migrate >/dev/null 2>&1; then
    _sm="session-migrate"
  else
    return 1
  fi

  # 统一入口：选定源文件后导入目标 agent，stdout 输出新 session id
  _ase_import_to() {
    _isrc="$1"
    _icwd="$2"
    _out=$("$_sm" import "$_isrc" --to "$_tag" --cwd "$_icwd" 2>&1)
    _ec=$?
    [ $_ec -ne 0 ] && echo "[session-migrate] import failed: $_out" >&2
    _new=$(printf '%s' "$_out" | _ase_json_field session_id)
    [ -n "$_new" ] || return 1
    printf '%s' "$_new"
    return 0
  }

  _src=""
  for _f in "$_dir/latest-${_tag}.jsonl" "$_dir/latest-${_tag}.json" "$_dir/latest-${_tag}.jsonl.zst"; do
    [ -f "$_f" ] && _src="$_f" && break
  done

  if [ -n "$_src" ]; then
    _sid=$(_ase_latest_id "$_tag" "$_cwd" 2>/dev/null || true)
    if [ -n "$_sid" ] && _ase_native_has "$_tag" "$_sid" "$_cwd"; then
      printf '%s' "$_sid"
      return 0
    fi
    # 情况2：文件在、原生会话不在 → 导入
    echo "[session-migrate] import $_src -> $_tag" >&2
    _new=$(_ase_import_to "$_src" "$_cwd")
    if [ -n "$_new" ]; then
      printf '%s' "$_new"
      return 0
    fi
    # 导入失败（可能原生目录已存在同名会话）→ 用原 id 兜底
    if [ -n "$_sid" ]; then
      printf '%s' "$_sid"
      return 0
    fi
    return 1
  fi

  # 情况3：无该 tag → 其他 agent 最新文件迁移
  _osrc=""; _otag=""
  for _t in claude codex pi; do
    [ "$_t" = "$_tag" ] && continue
    for _f in "$_dir/latest-${_t}.jsonl" "$_dir/latest-${_t}.json" "$_dir/latest-${_t}.jsonl.zst"; do
      [ -f "$_f" ] || continue
      if [ -z "$_osrc" ] || [ "$_f" -nt "$_osrc" ]; then
        _osrc="$_f"
        _otag="$_t"
      fi
    done
  done
  [ -n "$_osrc" ] || return 1
  echo "[session-migrate] no $_tag session; migrate $_otag -> $_tag" >&2
  _new=$(_ase_import_to "$_osrc" "$_cwd")
  [ -n "$_new" ] || return 1
  printf '%s' "$_new"
  return 0
}

_ase_user_handles_session() {
  [ -n "${ASE_FRESH:-}" ] && return 0
  for _a in "$@"; do
    case "$_a" in
      -h|--help|help) return 0 ;;
      --resume|--continue|resume|continue) return 0 ;;
      --session|--session-id) return 0 ;;
    esac
  done
  return 1
}

claude-s() {
  if ! _ase_user_handles_session "$@"; then
    _id=$(_ase_ensure_native claude "$PWD" || true)
    if [ -n "${_id:-}" ]; then
      echo "[claude-s] resume: $_id"
      command claude --resume "$_id" "$@"
      _ec=$?
      trap '' INT
      agent-session-export claude "" "" "$PWD" || true
      trap - INT
      return $_ec
    fi
    # 迁移无可用会话；本机原生目录有历史才试 --continue，
    # 否则直接新开（避免 "No conversation found" 报错后无法进入交互）
    if command claude --help 2>&1 | grep -q -- '--continue' \
       && [ -n "$(find "$HOME/.claude/projects" -name "*.jsonl" -type f 2>/dev/null | head -n 1)" ]; then
      echo "[claude-s] try --continue"
      command claude --continue "$@"
      _ec=$?
      trap '' INT
      agent-session-export claude "" "" "$PWD" || true
      trap - INT
      return $_ec
    fi
  fi
  command claude "$@"
  _ec=$?
  trap '' INT
  agent-session-export claude "" "" "$PWD" || true
  trap - INT
  return $_ec
}

codex-s() {
  if ! _ase_user_handles_session "$@"; then
    _id=$(_ase_ensure_native codex "$PWD" || true)
    if [ -n "${_id:-}" ]; then
      echo "[codex-s] resume: $_id"
      if command codex resume -h >/dev/null 2>&1 || command codex help resume >/dev/null 2>&1; then
        command codex resume "$_id" "$@"
      else
        command codex --resume "$_id" "$@"
      fi
      _ec=$?
      trap '' INT
      agent-session-export codex "" "$PWD" || true
      trap - INT
      return $_ec
    fi
  fi
  command codex "$@"
  _ec=$?
  trap '' INT
  agent-session-export codex "" "$PWD" || true
  trap - INT
  return $_ec
}

pi-s() {
  if ! _ase_user_handles_session "$@"; then
    _id=$(_ase_ensure_native pi "$PWD" || true)
    if [ -n "${_id:-}" ]; then
      echo "[pi-s] resume: $_id"
      # 先探测 pi 支持的 resume 参数，只启动一次（TUI 不可 || 链式重试）
      if command pi --help 2>&1 | grep -q -- '--session'; then
        command pi --session "$_id" "$@"
      elif command pi --help 2>&1 | grep -q -- 'resume'; then
        command pi resume "$_id" "$@"
      else
        command pi "$@"
      fi
      _ec=$?
      trap '' INT
      agent-session-export pi "" "$PWD" || true
      trap - INT
      return $_ec
    fi
  fi
  command pi "$@"
  _ec=$?
  trap '' INT
  agent-session-export pi "" "$PWD" || true
  trap - INT
  return $_ec
}
FUNCS
    echo "$BLOCK_END"
  } >> "$_rc"
  echo "==> wrote functions -> $_rc"
}

append_rc "$HOME/.bashrc"
append_rc "$HOME/.zshrc"

echo
echo "Install finished."
echo "  source ~/.bashrc     # Linux bash"
echo "  source ~/.zshrc      # macOS / zsh"
echo
echo "  session-snap              # 手动导出"
echo "  claude-s | codex-s | pi-s"
echo "    - 有 .session/latest-* 则自动 resume"
echo "    - 没有? 自动用 session-migrate 从其他 agent 迁移"
echo "    - 退出后自动导出到 \$PWD/.session/"
echo "  ASE_FRESH=1 codex-s       # 强制新开，不 resume、不迁移"
echo
echo "Agent CLI 未安装的话:"
echo "  npm install -g @anthropic-ai/claude-code"
echo "  npm install -g @openai/codex"
echo "  npm install -g --ignore-scripts @earendil-works/pi-coding-agent"
echo
echo "✔ 安装成功，祝使用愉快！"


