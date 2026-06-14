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

# --- Per-file diff capture (G148/W719 contract, Option D semantic) ---
# Emits a JSON array of `{path, diff}` entries to stdout, one per file that
# differs between $1 (base ref) and the agent's WORKING TREE at the time the
# function runs. The snapshot captures committed-since-base, staged-but-
# uncommitted, modified-but-unstaged, AND untracked-but-not-gitignored changes
# in a single pass — so reviewers see the agent's full working state at
# completion time, regardless of whether the agent committed before calling
# /complete. Truncates diffs over 500 lines with the contract marker; emits
# the binary placeholder for files git reports as binary in --numstat (tracked)
# or that contain a NUL byte (untracked). Falls back to HEAD~1 when the
# provided base is empty or unresolvable. Returns an empty array (and exit 0)
# for any degraded path (jq missing, git missing, not in a repo, no commits to
# diff) so callers can treat this strictly as "best-effort capture".
capture_changed_files() {
  local base="${1:-}"
  local max_lines=500
  local trunc_marker="[diff truncated at 500 lines]"
  local bin_placeholder="[binary file — no diff captured]"

  if ! command -v jq > /dev/null 2>&1 || ! command -v git > /dev/null 2>&1; then
    printf '[]\n'
    return 0
  fi

  if [ -z "$base" ] || ! git rev-parse --verify "$base" > /dev/null 2>&1; then
    if git rev-parse --verify "HEAD~1" > /dev/null 2>&1; then
      base="HEAD~1"
    else
      printf '[]\n'
      return 0
    fi
  fi

  # Tracked files that differ between base and the working tree (committed,
  # staged, and unstaged changes all surface in a single `git diff <base>`).
  local tracked_files
  tracked_files=$(git diff --name-only "$base" 2>/dev/null || printf '')

  # Untracked files not covered by .gitignore.
  local untracked_files
  untracked_files=$(git ls-files --others --exclude-standard 2>/dev/null || printf '')

  # Combine; dedupe by path. Untracked entries should not overlap tracked
  # (git would report a path as one OR the other, not both), but the awk
  # `!seen` guard makes a single-entry-per-path invariant explicit.
  local all_files
  all_files=$(printf '%s\n%s\n' "$tracked_files" "$untracked_files" \
    | awk 'NF && !seen[$0]++')

  if [ -z "$all_files" ]; then
    printf '[]\n'
    return 0
  fi

  # numstat for tracked changes — used to detect binaries among tracked files
  # via the `- - <path>` marker. Untracked files are not in numstat; their
  # binary detection runs separately on file contents.
  local numstat
  numstat=$(git diff --numstat "$base" 2>/dev/null || printf '')

  local jsonl_file
  jsonl_file=$(mktemp)

  local file
  while IFS= read -r file; do
    [ -z "$file" ] && continue

    # Determine whether this path is in the untracked list (membership lookup,
    # not just empty check — tracked_files and untracked_files were merged
    # above with dedupe).
    local is_untracked=0
    if [ -n "$untracked_files" ]; then
      local u
      while IFS= read -r u; do
        if [ "$u" = "$file" ]; then
          is_untracked=1
          break
        fi
      done <<< "$untracked_files"
    fi

    local is_binary=0
    local diff_text=""

    if [ "$is_untracked" -eq 1 ]; then
      # Untracked: synthesize a new-file unified patch by diffing the file
      # against /dev/null. `git diff --no-index` exits 1 when files differ —
      # that is the expected path here, so we ignore the exit code and
      # capture whatever stdout it produced. --no-color guards against
      # pager/color being inherited from the user's git config.
      #
      # Binary detection uses git's own determination: when --no-index sees
      # a binary file, it emits "Binary files /dev/null and <path> differ"
      # instead of a unified patch. Sniffing that prefix is more reliable
      # than a NUL-byte grep (bash truncates $'\0' to an empty pattern,
      # which matches every line and falsely flags text files as binary).
      diff_text=$(git diff --no-index --no-color /dev/null "$file" 2>/dev/null)
      # For new files, --no-index emits a header (`diff --git`,
      # `new file mode`, `index ...`) BEFORE the "Binary files ... differ"
      # sentinel line, so we have to check anywhere in the output rather
      # than just the prefix.
      if printf '%s\n' "$diff_text" | grep -q '^Binary files .* differ$'; then
        is_binary=1
      fi
    elif [ -n "$numstat" ]; then
      local nl added rest deleted path
      while IFS= read -r nl; do
        added="${nl%%	*}"
        rest="${nl#*	}"
        deleted="${rest%%	*}"
        path="${rest#*	}"
        if [ "$added" = "-" ] && [ "$deleted" = "-" ] && [ "$path" = "$file" ]; then
          is_binary=1
          break
        fi
      done <<< "$numstat"
    fi

    if [ "$is_binary" -eq 1 ]; then
      diff_text="$bin_placeholder"
    else
      if [ "$is_untracked" -eq 0 ]; then
        # Tracked: working-tree diff vs base (committed + staged + unstaged
        # changes all in one diff).
        diff_text=$(git diff "$base" -- "$file" 2>/dev/null || printf '')
      fi
      # diff_text for untracked was already captured above.
      local line_count=0
      if [ -n "$diff_text" ]; then
        local _no_nl="${diff_text//$'\n'/}"
        line_count=$(( ${#diff_text} - ${#_no_nl} + 1 ))
      fi
      if [ "$line_count" -gt "$max_lines" ]; then
        local truncated
        truncated=$(printf '%s\n' "$diff_text" | head -n $((max_lines - 1)))
        diff_text="${truncated}
${trunc_marker}"
      fi
    fi

    jq -n --arg path "$file" --arg diff "$diff_text" '{path: $path, diff: $diff}' >> "$jsonl_file"
  done <<< "$all_files"

  if [ -s "$jsonl_file" ]; then
    jq -s '.' < "$jsonl_file"
  else
    printf '[]\n'
  fi
  rm -f "$jsonl_file"
}

# Helper: resolve the Stride API base URL for the changed_files upload.
# Primary source is $PROJECT_DIR/.stride_auth.md (the same file the agent
# reads) — its `**API URL:** `<url>`` line. Falls back to a literal URL in the
# intercepted $COMMAND for back-compat when the auth file is absent. Prints the
# URL (or empty) on stdout.
resolve_stride_api_url() {
  local _auth="$PROJECT_DIR/.stride_auth.md" _url=""
  if [ -f "$_auth" ]; then
    _url=$(grep -E '\*\*API URL:\*\*' "$_auth" | grep -oE 'https?://[A-Za-z0-9._:/-]+' | head -n 1 || true)
  fi
  if [ -z "$_url" ]; then
    _url=$(printf '%s' "${COMMAND:-}" | grep -oE 'https?://[A-Za-z0-9._-]+(:[0-9]+)?' | head -n 1 || true)
  fi
  printf '%s' "$_url"
}

# Helper: resolve the Stride API bearer token for the changed_files upload.
# Primary source is the production `**API Token:** `<token>`` line in
# $PROJECT_DIR/.stride_auth.md — deliberately NOT the `**Local API Token:**`
# line (the `**API Token:**` pattern does not match `**Local API Token:**`).
# Falls back to a literal `Bearer <token>` in the intercepted $COMMAND. Prints
# the token (or empty) on stdout; never logs it.
resolve_stride_api_token() {
  local _auth="$PROJECT_DIR/.stride_auth.md" _tok=""
  if [ -f "$_auth" ]; then
    _tok=$(grep -E '\*\*API Token:\*\*' "$_auth" | grep -oE '`[^`]+`' | head -n 1 | tr -d '`' || true)
  fi
  if [ -z "$_tok" ]; then
    _tok=$(printf '%s' "${COMMAND:-}" | grep -oE 'Bearer +[A-Za-z0-9._+/=-]+' | head -n 1 | sed 's/^Bearer  *//' || true)
  fi
  printf '%s' "$_tok"
}

# Helper: PUT the on-disk snapshot ($PROJECT_DIR/.stride-changed-files.json)
# to /api/tasks/<id>/changed_files. We send the transport-encoded envelope
# {"changed_files":{"encoding":"base64","data":"<b64>"}} rather than the raw
# array so an edge request filter does not misread a code diff as an attack
# and drop the upload (D61). The server decodes it back to the same list. The
# base64 MUST be single-line so the value is valid inside the JSON string
# (strip any wrap newlines). When base64 is unavailable we fall back to the
# raw {"changed_files":[...]} shape — a bare top-level array would land at
# params['_json'] and persist as NULL. Prints the HTTP code on stdout ('000'
# on transport failure), warns on stderr for non-2xx, always returns 0.
# Shared by finalize_after_doing and the before_review self-heal (W1094) —
# callers MUST capture stdout or the code would leak into the hook's
# structured-JSON stdout contract.
upload_changed_files_snapshot() {
  local _task_id="$1" _api_base="$2" _token="$3"
  local _b64="" _http_code
  if command -v base64 > /dev/null 2>&1; then
    _b64=$(base64 < "$PROJECT_DIR/.stride-changed-files.json" 2>/dev/null | tr -d '\r\n')
  fi

  if [ -n "$_b64" ]; then
    _http_code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
      -H "Authorization: Bearer $_token" \
      -H 'Content-Type: application/json' \
      -d "{\"changed_files\":{\"encoding\":\"base64\",\"data\":\"$_b64\"}}" \
      "$_api_base/api/tasks/$_task_id/changed_files" 2>/dev/null || printf '000')
  else
    _http_code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
      -H "Authorization: Bearer $_token" \
      -H 'Content-Type: application/json' \
      -d "{\"changed_files\":$(cat "$PROJECT_DIR/.stride-changed-files.json")}" \
      "$_api_base/api/tasks/$_task_id/changed_files" 2>/dev/null || printf '000')
  fi

  # Surface a failed upload instead of dropping it silently. The diff is
  # non-fatal to completion, so we warn rather than abort.
  case "$_http_code" in
    2*) : ;;
    *)
      printf 'stride-hook: changed_files upload failed (HTTP %s) for task %s\n' \
        "$_http_code" "$_task_id" >&2
      ;;
  esac
  printf '%s' "$_http_code"
  return 0
}

# Helper: record the outcome of a changed_files PUT attempt (W1094) so the
# before_review self-heal can verify it on a fresh timeout budget. Task id
# and HTTP code ONLY — never the URL or bearer token (the file lives
# untracked in the project root alongside the other .stride artifacts).
record_diff_upload_state() {
  {
    printf 'task_id=%s\n' "$1"
    printf 'http_code=%s\n' "$2"
  } > "$PROJECT_DIR/.stride-diff-upload-state" 2>/dev/null || true
}

# Writes the changed-files snapshot to $PROJECT_DIR/.stride-changed-files.json,
# then fire-and-forget PUTs it to the Stride server. Invoked from every
# after_doing exit path (no-commands branch, all-comments branch, and the
# post-command-loop success branch) so the file exists when the subsequent
# /complete curl reads it inline. The function is a no-op when TASK_BASE_REF
# is unset (e.g. the test harness sources the script without claiming a
# task first). URL and token for the PUT are resolved by resolve_stride_api_url /
# resolve_stride_api_token — preferring $PROJECT_DIR/.stride_auth.md so the
# upload works whether the agent's completion curl used literal values or shell
# variables ($STRIDE_API_URL / $STRIDE_API_TOKEN), with the $COMMAND literal
# extraction kept as a back-compat fallback.
finalize_after_doing() {
  local snapshot
  if [ -n "${TASK_BASE_REF:-}" ]; then
    snapshot=$(capture_changed_files "${TASK_BASE_REF:-}" 2>/dev/null || printf '[]')
    printf '%s\n' "$snapshot" > "$PROJECT_DIR/.stride-changed-files.json" 2>/dev/null || true

    # No-op silently if any prerequisite is missing — preserves the on-disk
    # snapshot for legacy --argjson cf consumers.
    if [ "${HAS_JQ:-false}" = "true" ] && command -v curl > /dev/null 2>&1 && [ -n "${TASK_ID:-}" ]; then
      local _api_base _token
      _api_base=$(resolve_stride_api_url)
      _token=$(resolve_stride_api_token)
      if [ -n "$_api_base" ] && [ -n "$_token" ]; then
        # Upload via the shared D61 transport-envelope helper.
        local _http_code
        _http_code=$(upload_changed_files_snapshot "$TASK_ID" "$_api_base" "$_token")
        # (W1094) Record the outcome after EVERY PUT attempt so the
        # before_review self-heal can verify it on a fresh timeout budget.
        # A skipped PUT (missing preconditions) deliberately writes nothing:
        # missing state means "no healthy upload on record" and the retry
        # re-checks the same preconditions itself.
        record_diff_upload_state "$TASK_ID" "$_http_code"
      fi
    fi
  fi
}

# --- (W1094) Self-heal for the changed_files upload ---
# The after_doing gate can burn the whole hook budget, killing the process
# before or during the snapshot PUT — or the PUT itself returned non-2xx.
# before_review (AfterTool on the same completion curl) runs on a FRESH
# budget, so it verifies the recorded outcome and re-captures + re-PUTs when
# no healthy upload is on record for the current task. Best-effort: never
# returns non-zero, and never touches the snapshot file unless a retry PUT is
# actually possible (preserves the on-disk snapshot for degraded environments
# and legacy consumers).
self_heal_changed_files_upload() {
  [ "${HOOK_NAME:-}" = "before_review" ] || return 0
  [ "${HAS_JQ:-false}" = "true" ] || return 0
  command -v curl > /dev/null 2>&1 || return 0
  [ -n "${TASK_ID:-}" ] || return 0

  # Healthy 2xx recorded for THIS task → do not re-upload (snapshot
  # semantics anchor at after_doing time; avoid pointless API load).
  # Missing file, different task id, or non-2xx/empty code → retry.
  local _state_file="$PROJECT_DIR/.stride-diff-upload-state"
  local _state_task="" _state_code=""
  if [ -f "$_state_file" ]; then
    _state_task=$(grep '^task_id=' "$_state_file" 2>/dev/null | head -n 1 | cut -d= -f2- || true)
    _state_code=$(grep '^http_code=' "$_state_file" 2>/dev/null | head -n 1 | cut -d= -f2- || true)
  fi
  if [ "$_state_task" = "${TASK_ID:-}" ]; then
    case "$_state_code" in
      2*) return 0 ;;
    esac
  fi

  # Resolve credentials BEFORE overwriting the snapshot — when no PUT is
  # possible the stale on-disk snapshot must be left untouched.
  local _api_base _token
  _api_base=$(resolve_stride_api_url)
  _token=$(resolve_stride_api_token)
  if [ -z "$_api_base" ] || [ -z "$_token" ]; then
    return 0
  fi

  # Re-capture against the claim-time base ref. The subshell cd anchors git
  # to the project repo without disturbing the main script's cwd (the
  # before_review section's own `cd "$PROJECT_DIR"` has not run yet).
  local _snapshot _http_code
  _snapshot=$( (cd "$PROJECT_DIR" && capture_changed_files "${TASK_BASE_REF:-}") 2>/dev/null || printf '[]')
  printf '%s\n' "$_snapshot" > "$PROJECT_DIR/.stride-changed-files.json" 2>/dev/null || true
  _http_code=$(upload_changed_files_snapshot "$TASK_ID" "$_api_base" "$_token")
  record_diff_upload_state "$TASK_ID" "$_http_code"
  return 0
}

# --- Parse and execute one .stride.md hook section ---
# Takes a single section name (e.g. "before_doing", "after_goal") and:
#   1. Parses the first `## <section>` block from .stride.md (first-wins,
#      single ```bash fence, identical to the four-hook routes).
#   2. Returns 0 immediately when the section is missing OR the fenced body
#      is empty — back-compat no-op. The finalize_after_doing snapshot
#      write only fires when the section IS "after_doing" so calls for
#      "after_goal" don't trigger an unrelated snapshot.
#   3. Otherwise executes each command sequentially; on the first non-zero
#      exit, emits the structured failed-JSON (or the plain-text fallback
#      when $HAS_JQ=false, routed to stderr per Gemini's JSON-only stdout
#      contract) and returns 2.
#   4. On all-success, emits the structured success-JSON (jq-only) and
#      returns 0.
# Placed alongside capture_changed_files / finalize_after_doing so tests
# can source the script and invoke the function in isolation.
run_stride_section() {
  local _section="$1"
  local _commands=""
  local _found=0
  local _capture=0
  local _line _heading

  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      "## "*)
        [ "$_found" -eq 1 ] && break
        _heading="${_line#\#\# }"
        _heading="${_heading%"${_heading##*[![:space:]]}"}"
        [ "$_heading" = "$_section" ] && _found=1
        continue
        ;;
    esac
    if [ "$_found" -eq 1 ]; then
      case "$_line" in
        '```bash'*) _capture=1; continue ;;
        '```'*)     [ "$_capture" -eq 1 ] && break; continue ;;
      esac
      [ "$_capture" -eq 1 ] && _commands="${_commands}${_line}
"
    fi
  done < "$STRIDE_MD"

  if [ -z "$_commands" ]; then
    [ "$_section" = "after_doing" ] && finalize_after_doing
    return 0
  fi

  local _cmd _trimmed
  local _cmd_list
  _cmd_list=()
  while IFS= read -r _cmd; do
    _trimmed="${_cmd#"${_cmd%%[![:space:]]*}"}"
    [ -z "$_trimmed" ] && continue
    case "$_trimmed" in \#*) continue ;; esac
    _cmd_list+=("$_trimmed")
  done <<< "$_commands"

  if [ ${#_cmd_list[@]} -eq 0 ]; then
    [ "$_section" = "after_doing" ] && finalize_after_doing
    return 0
  fi

  cd "$PROJECT_DIR"

  # Early per-file diff snapshot (W1093) — the after_doing section runs the
  # full quality gate, and the hook timeout can kill this process mid-loop,
  # silently losing the diff upload. Capture and PUT the snapshot BEFORE the
  # first command executes; the post-loop call below is KEPT as a refresh
  # once the gate succeeds. Gated on $_section like the other call sites so
  # the before_review / after_review / after_goal reuse of this function
  # stays inert. finalize_after_doing is idempotent, emits nothing on stdout,
  # and never returns non-zero — a degraded capture still writes a best-effort
  # [] snapshot. Placed after the cd so capture_changed_files diffs the repo.
  [ "$_section" = "after_doing" ] && finalize_after_doing

  local _completed_file
  _completed_file=$(mktemp)
  local _start_secs
  _start_secs=$(date +%s)
  local _cmd_index=0
  local _cmd_total=${#_cmd_list[@]}
  local _cmd_stdout_file _cmd_stderr_file _cmd_exit _cmd_stdout _cmd_stderr
  local _remaining_file _completed_json _remaining_json _end_secs _duration _i

  for _trimmed in "${_cmd_list[@]}"; do
    _cmd_stdout_file=$(mktemp)
    _cmd_stderr_file=$(mktemp)

    # Relax `set -u` and `pipefail` for the user's command so that a reference
    # to an unset env var doesn't silently abort the eval before the actual
    # command runs; restore the strict flags immediately afterward.
    set +uo pipefail
    eval "$_trimmed" > "$_cmd_stdout_file" 2> "$_cmd_stderr_file"
    _cmd_exit=$?
    set -uo pipefail

    if [ "$_cmd_exit" -eq 0 ]; then
      echo "$_trimmed" >> "$_completed_file"
      # Gemini requires JSON-only stdout — command output goes to stderr.
      cat "$_cmd_stdout_file" >&2
      cat "$_cmd_stderr_file" >&2
    else
      _cmd_stdout=$(tail -50 "$_cmd_stdout_file")
      _cmd_stderr=$(tail -50 "$_cmd_stderr_file")
      rm -f "$_cmd_stdout_file" "$_cmd_stderr_file"

      _remaining_file=$(mktemp)
      if [ $((_cmd_index + 1)) -lt $_cmd_total ]; then
        for ((_i = _cmd_index + 1; _i < _cmd_total; _i++)); do
          echo "${_cmd_list[$_i]}" >> "$_remaining_file"
        done
      fi

      if [ "$HAS_JQ" = "true" ]; then
        _completed_json=$(jq -R . < "$_completed_file" | jq -s . 2>/dev/null || echo "[]")
        _remaining_json=$(jq -R . < "$_remaining_file" | jq -s . 2>/dev/null || echo "[]")

        jq -n \
          --arg hook "$_section" \
          --arg failed "$_trimmed" \
          --argjson index "$_cmd_index" \
          --argjson exit_code "$_cmd_exit" \
          --arg stdout "$_cmd_stdout" \
          --arg stderr "$_cmd_stderr" \
          --argjson completed "$_completed_json" \
          --argjson remaining "$_remaining_json" \
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
        # Gemini-specific: plain-text fallback goes to stderr, never stdout.
        echo "HOOK=$_section STATUS=failed COMMAND=$_trimmed EXIT=$_cmd_exit" >&2
      fi

      echo "Stride $_section hook failed on command $((_cmd_index + 1))/$_cmd_total: $_trimmed" >&2
      [ -n "$_cmd_stderr" ] && echo "$_cmd_stderr" >&2
      rm -f "$_completed_file" "$_remaining_file"
      return 2
    fi

    rm -f "$_cmd_stdout_file" "$_cmd_stderr_file"
    _cmd_index=$((_cmd_index + 1))
  done

  _end_secs=$(date +%s)
  _duration=$((_end_secs - _start_secs))

  if [ "$HAS_JQ" = "true" ]; then
    _completed_json=$(jq -R . < "$_completed_file" | jq -s . 2>/dev/null || echo "[]")

    jq -n \
      --arg hook "$_section" \
      --argjson duration "$_duration" \
      --argjson completed "$_completed_json" \
      '{
        hook: $hook,
        status: "success",
        commands_completed: $completed,
        duration_seconds: $duration
      }'
  fi

  rm -f "$_completed_file"

  # Snapshot capture is gated on the section being after_doing — matches
  # gemini's pre-W783 convention of guarding at every finalize call site.
  # (W1093) This is the REFRESH of the early pre-loop snapshot — keep it: the
  # gate's commands may modify files, and this re-captures the final tree.
  [ "$_section" = "after_doing" ] && finalize_after_doing

  return 0
}

# Detect an `after_goal` entry in the response's `hooks` array. Handles
# Claude/Gemini-style wrapped form (`tool_response.stdout` is a JSON
# string) and raw-API-JSON form. Returns 0 when an entry with
# name == "after_goal" is found, 1 otherwise. Gated on $HAS_JQ —
# environments without jq cannot parse the response and degrade cleanly.
response_has_after_goal() {
  local _hook_input="$1"
  local _response _payload

  [ "$HAS_JQ" = "true" ] || return 1
  [ -n "$_hook_input" ] || return 1

  _response=$(echo "$_hook_input" | jq -r '.tool_response // ""' 2>/dev/null || echo "")
  [ -n "$_response" ] || return 1

  if echo "$_response" | jq -e 'type == "object" and has("stdout")' > /dev/null 2>&1; then
    _payload=$(echo "$_response" | jq -r '.stdout // ""' 2>/dev/null)
  else
    _payload="$_response"
  fi

  [ -n "$_payload" ] || return 1

  echo "$_payload" \
    | jq -e '(.hooks // []) | map(select(.name == "after_goal")) | length > 0' \
        > /dev/null 2>&1
}

# Exit early if no phase argument or no .stride.md. Placed AFTER the
# capture_changed_files, finalize_after_doing, run_stride_section, and
# response_has_after_goal definitions so tests can source this script to
# use the functions in isolation.
if [ -z "$PHASE" ]; then
  return 0 2>/dev/null || exit 0
fi
if [ ! -f "$STRIDE_MD" ]; then
  return 0 2>/dev/null || exit 0
fi

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
      # Capture the current git HEAD as TASK_BASE_REF so capture_changed_files
      # has an anchor pointing at when the task was claimed (consumed by
      # finalize_after_doing at the end of every after_doing exit path).
      # cd into the project dir first so HEAD comes from the project's repo
      # regardless of the hook process's current working directory.
      _base_ref=$(cd "$PROJECT_DIR" && git rev-parse HEAD 2>/dev/null || printf '')

      # Values are single-quoted to handle spaces in titles/descriptions
      {
        echo "TASK_ID='$(echo "$TASK_JSON" | jq -r '.id // empty')'"
        echo "TASK_IDENTIFIER='$(echo "$TASK_JSON" | jq -r '.identifier // empty')'"
        echo "TASK_TITLE='$(echo "$TASK_JSON" | jq -r '.title // empty')'"
        echo "TASK_STATUS='$(echo "$TASK_JSON" | jq -r '.status // empty')'"
        echo "TASK_COMPLEXITY='$(echo "$TASK_JSON" | jq -r '.complexity // empty')'"
        echo "TASK_PRIORITY='$(echo "$TASK_JSON" | jq -r '.priority // empty')'"
        echo "TASK_BASE_REF='$_base_ref'"
      } > "$ENV_CACHE" 2>/dev/null || true

      # Clear any stale changed-files snapshot left over from a prior task so
      # the new task's after_doing capture starts from a clean slate.
      rm -f "$PROJECT_DIR/.stride-changed-files.json" 2>/dev/null || true
      # (W1094) Clear the previous task's upload state — a stale 2xx would
      # suppress the before_review self-heal retry for the new task.
      rm -f "$PROJECT_DIR/.stride-diff-upload-state" 2>/dev/null || true
    fi
  fi
fi

# Load cached env vars if available (all hooks benefit from this)
if [ -f "$ENV_CACHE" ]; then
  set -a
  . "$ENV_CACHE" 2>/dev/null || true
  set +a
fi

# (W1094) Verify-and-retry the changed_files upload before the primary
# before_review section runs — fresh AfterTool budget; TASK_ID and
# TASK_BASE_REF are in scope from the env cache. Self-gates on
# HOOK_NAME=before_review; best-effort, never fails the hook.
self_heal_changed_files_upload || true

# --- Execute the primary hook ---
# run_stride_section emits structured JSON itself and (for after_doing) writes
# the per-file diff snapshot via finalize_after_doing. Failure exits 2 here
# to preserve the existing PreToolUse blocking semantic for after_doing.
run_stride_section "$HOOK_NAME"
PRIMARY_RC=$?

if [ "$PRIMARY_RC" -ne 0 ]; then
  exit "$PRIMARY_RC"
fi

# --- After-goal routing (W783 / mirrors stride v1.17.1 W504) ---
# When the server bundles an `after_goal` entry in the response of /complete
# or /mark_reviewed, run the local `## after_goal` section as a blocking
# hook. Missing `## after_goal` in .stride.md is a clean no-op. Non-zero
# exits surface via the same structured JSON shape as the primary hook;
# we do NOT propagate as a non-zero script exit because the primary curl
# already succeeded — failure is captured in stdout for the agent to
# forward via PATCH /api/tasks/:goal_id/after_goal.
if [ "$PHASE" = "post" ]; then
  case "$COMMAND" in
    */api/tasks/*/complete*|*/api/tasks/*/mark_reviewed*)
      if response_has_after_goal "$INPUT"; then
        run_stride_section "after_goal" || true
      fi
      ;;
  esac
fi

# Clean up env cache and changed-files snapshot after the final hook in the
# lifecycle so the next task starts from a clean slate.
if [ "$HOOK_NAME" = "after_review" ]; then
  rm -f "$ENV_CACHE" "$PROJECT_DIR/.stride-changed-files.json" 2>/dev/null || true
  rm -f "$PROJECT_DIR/.stride-diff-upload-state" 2>/dev/null || true
fi

exit 0
