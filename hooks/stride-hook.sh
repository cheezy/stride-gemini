#!/usr/bin/env bash
# stride-hook.sh — Bridges Gemini CLI hooks to Stride .stride.md hook execution
#
# Called by Gemini CLI's BeforeTool/AfterTool hooks (configured in hooks.json).
# Receives hook JSON on stdin, determines if the shell command is a Stride API call,
# and if so, parses and executes the corresponding .stride.md section.
#
# IMPORTANT: Gemini CLI requires JSON-only stdout. All debug/progress output
# must go to stderr. Only the final structured JSON result goes to stdout.
#
# Usage: echo '{"tool_input":{"command":"curl ..."}}' | stride-hook.sh <pre|post>
#
# Exit codes:
#   0 — Success (or not a Stride API call)
#   2 — Hook command failed (blocks the tool call in BeforeTool context)

set -uo pipefail

PHASE="${1:-}"
PROJECT_DIR="${GEMINI_PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-.}}"
STRIDE_MD="$PROJECT_DIR/.stride.md"
ENV_CACHE="$PROJECT_DIR/.stride-env-cache"

# --- Platform detection: delegate to PowerShell on native Windows ---
# Git Bash (OSTYPE=msys*) and WSL have full bash — run directly.
# Native Windows without bash (COMSPEC set, no OSTYPE) → delegate to .ps1
_delegate_to_ps1=false
if [ -z "${OSTYPE:-}" ] && [ -n "${COMSPEC:-}" ]; then
  _delegate_to_ps1=true
fi

if [ "$_delegate_to_ps1" = "true" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  PS1_SCRIPT="$SCRIPT_DIR/stride-hook.ps1"
  if [ ! -f "$PS1_SCRIPT" ]; then
    echo "stride-hook.sh: Windows detected but stride-hook.ps1 not found at $PS1_SCRIPT" >&2
    exit 2
  fi
  if ! command -v powershell.exe > /dev/null 2>&1; then
    echo "stride-hook.sh: Windows detected but powershell.exe not found in PATH" >&2
    exit 2
  fi
  exec powershell.exe -ExecutionPolicy Bypass -File "$PS1_SCRIPT" "$PHASE"
fi

# Exit early if no phase argument or no .stride.md
[ -n "$PHASE" ] || exit 0
[ -f "$STRIDE_MD" ] || exit 0

# Read Gemini CLI hook input from stdin
INPUT=$(cat)

# Detect jq availability once
HAS_JQ=false
command -v jq > /dev/null 2>&1 && HAS_JQ=true

# Extract the Bash command from hook JSON
# Try jq first, fall back to pure bash for environments without jq
if [ "$HAS_JQ" = "true" ]; then
  COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")
else
  # Pure bash JSON extraction: find "command" : "value"
  _tmp="${INPUT#*\"command\"}"
  # If the expansion didn't change, the key wasn't found
  if [ "$_tmp" = "$INPUT" ]; then
    COMMAND=""
  else
    _tmp="${_tmp#*:}"
    _tmp="${_tmp#*\"}"
    COMMAND="${_tmp%%\"*}"
  fi
fi

[ -n "$COMMAND" ] || exit 0

# --- Determine which Stride hook to run ---
# Routing:
#   post + /api/tasks/claim        → before_doing
#   pre  + /api/tasks/:id/complete → after_doing  (blocks completion if it fails)
#   post + /api/tasks/:id/complete → before_review
#   post + /api/tasks/:id/mark_reviewed → after_review

HOOK_NAME=""

case "$PHASE" in
  post)
    case "$COMMAND" in
      */api/tasks/claim*)          HOOK_NAME="before_doing" ;;
      */api/tasks/*/mark_reviewed*) HOOK_NAME="after_review" ;;
      */api/tasks/*/complete*)      HOOK_NAME="before_review" ;;
    esac
    ;;
  pre)
    case "$COMMAND" in
      */api/tasks/*/complete*) HOOK_NAME="after_doing" ;;
    esac
    ;;
esac

# Not a Stride API call — exit cleanly
[ -n "$HOOK_NAME" ] || exit 0

# --- Environment variable caching ---
# After a successful claim (before_doing), extract task metadata from the API
# response and cache it. All subsequent hooks load the cache so .stride.md
# commands can reference $TASK_IDENTIFIER, $TASK_TITLE, etc.

if [ "$HOOK_NAME" = "before_doing" ] && [ "$HAS_JQ" = "true" ]; then
  RESPONSE=$(echo "$INPUT" | jq -r '.tool_response // ""' 2>/dev/null || echo "")
  if [ -n "$RESPONSE" ]; then
    # tool_response may come in three shapes depending on the host:
    #   1. {"stdout": "<api-json-string>", ...} — Bash-tool wrapper (Claude Code)
    #   2. "<api-json-string>" — legacy harnesses that stringify the body
    #   3. {"data": {...}} or {"id": ...} — raw API JSON object
    TASK_JSON=""
    INNER=""

    # Shape 1: wrapper object with .stdout key — peel and parse inner
    if echo "$RESPONSE" | jq -e 'type == "object" and has("stdout")' > /dev/null 2>&1; then
      INNER=$(echo "$RESPONSE" | jq -r '.stdout // ""' 2>/dev/null)
      if [ -n "$INNER" ] && echo "$INNER" | jq -e '.data.id' > /dev/null 2>&1; then
        TASK_JSON=$(echo "$INNER" | jq -c '.data' 2>/dev/null)
      elif [ -n "$INNER" ] && echo "$INNER" | jq -e '.id' > /dev/null 2>&1; then
        TASK_JSON="$INNER"
      fi
    fi

    # Shapes 2 and 3: response itself is the API JSON
    if [ -z "$TASK_JSON" ] && echo "$RESPONSE" | jq -e '.data.id' > /dev/null 2>&1; then
      TASK_JSON=$(echo "$RESPONSE" | jq -c '.data' 2>/dev/null)
    elif [ -z "$TASK_JSON" ] && echo "$RESPONSE" | jq -e '.id' > /dev/null 2>&1; then
      TASK_JSON="$RESPONSE"
    fi

    if [ -n "$TASK_JSON" ]; then
      # Values are single-quoted to handle spaces in titles/descriptions
      {
        echo "TASK_ID='$(echo "$TASK_JSON" | jq -r '.id // empty')'"
        echo "TASK_IDENTIFIER='$(echo "$TASK_JSON" | jq -r '.identifier // empty')'"
        echo "TASK_TITLE='$(echo "$TASK_JSON" | jq -r '.title // empty')'"
        echo "TASK_STATUS='$(echo "$TASK_JSON" | jq -r '.status // empty')'"
        echo "TASK_COMPLEXITY='$(echo "$TASK_JSON" | jq -r '.complexity // empty')'"
        echo "TASK_PRIORITY='$(echo "$TASK_JSON" | jq -r '.priority // empty')'"
      } > "$ENV_CACHE" 2>/dev/null || true
    fi
  fi
fi

# Load cached env vars if available (all hooks benefit from this)
if [ -f "$ENV_CACHE" ]; then
  set -a
  . "$ENV_CACHE" 2>/dev/null || true
  set +a
fi

# --- Parse .stride.md for the hook section ---
# Extracts lines from the first ```bash code block under ## <hook_name>
# Uses pure bash to avoid awk/sed dependency (not available on all platforms)
COMMANDS=""
_found=0
_capture=0
while IFS= read -r _line || [ -n "$_line" ]; do
  # Check for ## heading
  case "$_line" in
    "## "*)
      [ "$_found" -eq 1 ] && break
      _section="${_line#\#\# }"
      # Trim trailing whitespace
      _section="${_section%"${_section##*[![:space:]]}"}"
      [ "$_section" = "$HOOK_NAME" ] && _found=1
      continue
      ;;
  esac
  if [ "$_found" -eq 1 ]; then
    case "$_line" in
      '```bash'*) _capture=1; continue ;;
      '```'*)     [ "$_capture" -eq 1 ] && break; continue ;;
    esac
    [ "$_capture" -eq 1 ] && COMMANDS="${COMMANDS}${_line}
"
  fi
done < "$STRIDE_MD"

# No commands for this hook — exit cleanly
[ -n "$COMMANDS" ] || exit 0

# --- Build command list for tracking ---
# Split commands into an array for structured output
CMD_LIST=()
while IFS= read -r cmd; do
  trimmed="${cmd#"${cmd%%[![:space:]]*}"}"
  [ -z "$trimmed" ] && continue
  case "$trimmed" in \#*) continue ;; esac
  CMD_LIST+=("$trimmed")
done <<< "$COMMANDS"

# Nothing to execute after filtering
if [ ${#CMD_LIST[@]} -eq 0 ]; then
  exit 0
fi

# --- Execute commands with structured output ---
# Use temp files instead of bash arrays to avoid set -u issues with empty arrays
cd "$PROJECT_DIR"
COMPLETED_FILE=$(mktemp)
START_SECS=$(date +%s)
CMD_INDEX=0
CMD_TOTAL=${#CMD_LIST[@]}

for trimmed in "${CMD_LIST[@]}"; do
  # Capture stdout and stderr separately
  CMD_STDOUT_FILE=$(mktemp)
  CMD_STDERR_FILE=$(mktemp)

  # Relax `set -u` and `pipefail` for the user's command so a reference to an
  # unset env var (e.g. $TASK_IDENTIFIER when env-cache failed to write) doesn't
  # silently abort the eval before the actual command runs.
  set +uo pipefail
  eval "$trimmed" > "$CMD_STDOUT_FILE" 2> "$CMD_STDERR_FILE"
  CMD_EXIT=$?
  set -uo pipefail

  if [ "$CMD_EXIT" -eq 0 ]; then
    echo "$trimmed" >> "$COMPLETED_FILE"
    # Print command output to stderr (Gemini requires JSON-only stdout)
    cat "$CMD_STDOUT_FILE" >&2
    cat "$CMD_STDERR_FILE" >&2
  else
    CMD_STDOUT=$(tail -50 "$CMD_STDOUT_FILE")
    CMD_STDERR=$(tail -50 "$CMD_STDERR_FILE")
    rm -f "$CMD_STDOUT_FILE" "$CMD_STDERR_FILE"

    # Build remaining commands as a temp file
    REMAINING_FILE=$(mktemp)
    if [ $((CMD_INDEX + 1)) -lt $CMD_TOTAL ]; then
      for ((i = CMD_INDEX + 1; i < CMD_TOTAL; i++)); do
        echo "${CMD_LIST[$i]}" >> "$REMAINING_FILE"
      done
    fi

    # Emit structured JSON on stdout for Gemini to parse
    if [ "$HAS_JQ" = "true" ]; then
      COMPLETED_JSON=$(jq -R . < "$COMPLETED_FILE" | jq -s . 2>/dev/null || echo "[]")
      REMAINING_JSON=$(jq -R . < "$REMAINING_FILE" | jq -s . 2>/dev/null || echo "[]")

      jq -n \
        --arg hook "$HOOK_NAME" \
        --arg failed "$trimmed" \
        --argjson index "$CMD_INDEX" \
        --argjson exit_code "$CMD_EXIT" \
        --arg stdout "$CMD_STDOUT" \
        --arg stderr "$CMD_STDERR" \
        --argjson completed "$COMPLETED_JSON" \
        --argjson remaining "$REMAINING_JSON" \
        '{
          hook: $hook,
          status: "failed",
          failed_command: $failed,
          command_index: $index,
          exit_code: $exit_code,
          stdout: $stdout,
          stderr: $stderr,
          commands_completed: $completed,
          commands_remaining: $remaining
        }'
    else
      # Fallback: plain text to stderr (Gemini requires JSON-only stdout)
      echo "HOOK=$HOOK_NAME STATUS=failed COMMAND=$trimmed EXIT=$CMD_EXIT" >&2
    fi

    # Human-readable error on stderr for Gemini's feedback
    echo "Stride $HOOK_NAME hook failed on command $((CMD_INDEX + 1))/$CMD_TOTAL: $trimmed" >&2
    [ -n "$CMD_STDERR" ] && echo "$CMD_STDERR" >&2
    rm -f "$COMPLETED_FILE" "$REMAINING_FILE"
    exit 2
  fi

  rm -f "$CMD_STDOUT_FILE" "$CMD_STDERR_FILE"
  CMD_INDEX=$((CMD_INDEX + 1))
done

# --- Success output ---
END_SECS=$(date +%s)
DURATION=$((END_SECS - START_SECS))

if [ "$HAS_JQ" = "true" ]; then
  COMPLETED_JSON=$(jq -R . < "$COMPLETED_FILE" | jq -s . 2>/dev/null || echo "[]")

  jq -n \
    --arg hook "$HOOK_NAME" \
    --argjson duration "$DURATION" \
    --argjson completed "$COMPLETED_JSON" \
    '{
      hook: $hook,
      status: "success",
      commands_completed: $completed,
      duration_seconds: $duration
    }'
fi

rm -f "$COMPLETED_FILE"

# Clean up env cache after the final hook in the lifecycle
if [ "$HOOK_NAME" = "after_review" ] && [ -f "$ENV_CACHE" ]; then
  rm -f "$ENV_CACHE"
fi

exit 0
