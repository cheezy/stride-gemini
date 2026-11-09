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
# (W2144) The loop-state record the Stop/AfterAgent gate reads. THE HOOK writes
# this, never the agent: an agent-written marker is exactly as skippable as the
# instruction it replaces, which is the whole reason the gate reads a file the
# agent never touches. Path is identical to the Claude Code original (W2123) —
# both ports must interoperate on one path.
LOOP_STATE_FILE="$PROJECT_DIR/.stride/.loop-state.json"

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
  #
  # Exclude the hook's OWN bookkeeping artifacts (D67): the upload-state file
  # and the on-disk snapshot live at the project/repo root and otherwise pass
  # both nets — .stride-diff-upload-state as an untracked entry, and either of
  # them as a tracked diff once a project's after_doing auto-commit has staged
  # them. git's name-only/ls-files output is repo-root-relative, so the exact
  # whole-line match anchors to the ROOT artifacts only; a same-named file in a
  # subdirectory (e.g. sub/.stride-changed-files.json) has a path prefix and is
  # still captured.
  # (W1457) Also hard-exclude by name: .stride.md (the hook script config,
  # routinely dirty in working repos), .stride_auth.md (credentials — must
  # NEVER be uploaded, tracked, untracked, or edited), and the claim-time
  # dirty-baseline state file (a hook artifact like the two above).
  local all_files
  all_files=$(printf '%s\n%s\n' "$tracked_files" "$untracked_files" \
    | awk 'NF && $0 != ".stride-diff-upload-state" && $0 != ".stride-changed-files.json" && $0 != ".stride-dirty-baseline" && $0 != ".stride.md" && $0 != ".stride_auth.md" && !seen[$0]++')

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

  # (W1457) Claim-time dirty baseline: paths that were already modified or
  # untracked when the task was claimed are excluded from the snapshot
  # UNLESS the file changed again after claim (blob hash differs). When in
  # doubt — unhashable, deleted-after-claim, hash mismatch — include: one
  # extra diff beats silently losing task work. A missing/empty baseline
  # (older claim, non-git dir) falls back to the unfiltered behavior.
  local _baseline_file="${PROJECT_DIR:-.}/.stride-dirty-baseline"

  # (D142) Paths that differ between base and HEAD are COMMITTED task work —
  # the task's auto-commit contains them, so the baseline filter below must
  # never drop them. D137 silently lost 4 tracked edits and an untracked
  # migration exactly this way: they were dirty at claim time, the auto-commit
  # committed that same content, and the unchanged-since-claim blob hash then
  # excluded them from the snapshot.
  local committed_range
  committed_range=$(git diff --name-only "$base" HEAD 2>/dev/null || printf '')

  local file
  while IFS= read -r file; do
    [ -z "$file" ] && continue

    if [ -s "$_baseline_file" ]; then
      local _bl _bl_hash _bl_path _cur_hash _bl_excluded=0
      while IFS= read -r _bl; do
        _bl_hash="${_bl%% *}"
        _bl_path="${_bl#* }"
        if [ "$_bl_path" = "$file" ]; then
          if [ -f "$file" ]; then
            _cur_hash=$(git hash-object -- "$file" 2>/dev/null || echo "unhashable-now")
          else
            _cur_hash="absent"
          fi
          if [ "$_cur_hash" = "$_bl_hash" ] && [ "$_bl_hash" != "unhashable" ]; then
            _bl_excluded=1
          fi
          break
        fi
      done < "$_baseline_file"
      # (D142) Committed-range override: a path the task's commits contain is
      # task work by definition — never baseline-excluded.
      if [ "$_bl_excluded" -eq 1 ] && [ -n "$committed_range" ]; then
        local _cr
        while IFS= read -r _cr; do
          if [ "$_cr" = "$file" ]; then
            _bl_excluded=0
            break
          fi
        done <<< "$committed_range"
      fi
      [ "$_bl_excluded" -eq 1 ] && continue
    fi

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
# before_review self-heal can verify it on a fresh timeout budget. Task id,
# HTTP code, and (D142) the trust-guard-resolved snapshot base ONLY — never the
# URL or bearer token (the file lives untracked in the project root alongside
# the other .stride artifacts). The base lets the self-heal reuse the
# after_doing-time judgment instead of re-resolving against origin refs the
# section's own `git push` may have moved.
record_diff_upload_state() {
  {
    printf 'task_id=%s\n' "$1"
    printf 'http_code=%s\n' "$2"
    if [ -n "${3:-}" ]; then
      printf 'base=%s\n' "$3"
    fi
  } > "$PROJECT_DIR/.stride-diff-upload-state" 2>/dev/null || true
}

# (D127) Resolve the authoritative task id for the CURRENT completion from the
# /complete or /mark_reviewed URL in the command, independent of the env cache.
# Those URLs always carry /api/tasks/<id>/<action>, so the changed_files upload
# targets the task the agent is actually completing even when a hidden claim
# response left a STALE TASK_ID in the env cache — the confirmed empty-
# changed_files root cause (G321/D126: the diff was PUT to the previous task).
# Returns empty when the command carries no such URL (e.g. the claim path, whose
# URL has no id); callers fall back to the env-cache TASK_ID in that case.
task_id_from_command() {
  local _rest
  case "$1" in
    */api/tasks/*/complete*|*/api/tasks/*/mark_reviewed*)
      _rest="${1#*/api/tasks/}"
      _rest="${_rest%%/*}"
      case "$_rest" in
        "" | *[!0-9]*) printf '' ;;
        *) printf '%s' "$_rest" ;;
      esac
      ;;
    *) printf '' ;;
  esac
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
# (D142) Trust guard for the snapshot base ref. TASK_BASE_REF is supposed to
# be the task branch point — the commit HEAD pointed at right after the
# ## before_doing section finished (post-pull). A value inherited from a
# previous task or session can predate commits that arrived via the
# before_doing pull; diffing from it would span ANOTHER clone's completed
# task (the D132/W1678 incident). Rules, in order:
#   1. empty or unresolvable base            → recompute from the branch point
#   2. base is not an ancestor of HEAD       → recompute (e.g. rebased away)
#   3. base is a STRICT ancestor of the task branch point → recompute — the
#      range base..HEAD would include commits pulled from origin. A plain
#      is-ancestor-of-HEAD check cannot catch this: the D132 stale base WAS
#      an ancestor of HEAD.
# "Task branch point" = merge-base of HEAD and the origin default branch.
# Without an origin branch there is no branch point to judge against (and no
# cross-clone pull is possible), so the base passes through unchanged and
# capture_changed_files keeps its own HEAD~1 fallback. Recomputes are
# announced on stderr — never silently. Prints the base to use on stdout.
resolve_snapshot_base() {
  local _base="${1:-}" _bp="" _remote_head="" _c _reason="" _base_sha=""
  if ! command -v git > /dev/null 2>&1 \
    || ! git rev-parse --verify --quiet HEAD > /dev/null 2>&1; then
    printf '%s' "$_base"
    return 0
  fi
  _remote_head=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)
  _remote_head="${_remote_head#refs/remotes/}"
  if [ -z "$_remote_head" ]; then
    for _c in origin/main origin/master; do
      if git rev-parse --verify --quiet "$_c" > /dev/null 2>&1; then
        _remote_head="$_c"
        break
      fi
    done
  fi
  [ -n "$_remote_head" ] && _bp=$(git merge-base HEAD "$_remote_head" 2>/dev/null || true)
  if [ -z "$_bp" ]; then
    printf '%s' "$_base"
    return 0
  fi

  if [ -z "$_base" ] || ! _base_sha=$(git rev-parse --verify --quiet "$_base^{commit}" 2>/dev/null); then
    _reason="empty or unresolvable"
  elif ! git merge-base --is-ancestor "$_base_sha" HEAD 2>/dev/null; then
    _reason="not an ancestor of HEAD"
  elif [ "${TASK_BASE_REF_TRUSTED:-}" != "1" ] \
    && [ "$_base_sha" != "$_bp" ] \
    && git merge-base --is-ancestor "$_base_sha" "$_bp" 2>/dev/null; then
    # Rule 3 judges only INHERITED bases (no trust marker): a base the
    # current claim's post-before_doing capture wrote IS the branch point by
    # construction, and origin/main may legitimately have advanced past it
    # when the workflow pushes its own task commits before completing.
    _reason="older than the task branch point, so the diff would span commits pulled from origin"
  fi
  if [ -z "$_reason" ]; then
    printf '%s' "$_base"
    return 0
  fi
  printf 'stride-hook: TASK_BASE_REF %s is not trustworthy (%s); recomputed the snapshot base from the task branch point: %s\n' \
    "${_base:-<empty>}" "$_reason" "$_bp" >&2
  printf '%s' "$_bp"
}

finalize_after_doing() {
  local snapshot _tid
  if [ -n "${TASK_BASE_REF:-}" ]; then
    # (D142) Run the base through the trust guard ONCE per process and memoize
    # the judgment. The refresh call runs AFTER the section's commands — an
    # ## after_doing that pushes the default branch moves origin/main to HEAD,
    # which would make a CORRECT base look like a strict ancestor of the branch
    # point and recompute it to HEAD (empty snapshot overwriting the good early
    # upload). The early pre-command resolution sees the pre-push origin refs,
    # so it is the authoritative judgment for the whole task window; its
    # recompute notice stays on stderr so it reaches the hook output.
    if [ "${SNAP_BASE_RESOLVED_DONE:-false}" != "true" ]; then
      SNAP_BASE_RESOLVED=$( (cd "$PROJECT_DIR" 2>/dev/null && resolve_snapshot_base "${TASK_BASE_REF:-}") || printf '%s' "${TASK_BASE_REF:-}")
      SNAP_BASE_RESOLVED_DONE=true
    fi
    snapshot=$(capture_changed_files "${SNAP_BASE_RESOLVED:-}" 2>/dev/null || printf '[]')
    printf '%s\n' "$snapshot" > "$PROJECT_DIR/.stride-changed-files.json" 2>/dev/null || true

    # (D127) Target the task id from the /complete URL, not the env cache, so a
    # stale TASK_ID from a hidden claim response cannot route the diff to the
    # wrong task. Fall back to the env-cache TASK_ID only if the URL carries no id.
    _tid=$(task_id_from_command "${COMMAND:-}")
    [ -n "$_tid" ] || _tid="${TASK_ID:-}"

    # No-op silently if any prerequisite is missing — preserves the on-disk
    # snapshot for legacy --argjson cf consumers.
    if [ "${HAS_JQ:-false}" = "true" ] && command -v curl > /dev/null 2>&1 && [ -n "$_tid" ]; then
      local _api_base _token
      _api_base=$(resolve_stride_api_url)
      _token=$(resolve_stride_api_token)
      if [ -n "$_api_base" ] && [ -n "$_token" ]; then
        # Upload via the shared D61 transport-envelope helper.
        local _http_code
        _http_code=$(upload_changed_files_snapshot "$_tid" "$_api_base" "$_token")
        # (W1094) Record the outcome after EVERY PUT attempt so the
        # before_review self-heal can verify it on a fresh timeout budget.
        # A skipped PUT (missing preconditions) deliberately writes nothing:
        # missing state means "no healthy upload on record" and the retry
        # re-checks the same preconditions itself. (D142) The resolved base
        # rides along so the self-heal reuses this task window's judgment.
        record_diff_upload_state "$_tid" "$_http_code" "${SNAP_BASE_RESOLVED:-}"
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

  # (D127) Prefer the task id from the /complete URL over the env-cache TASK_ID
  # so the self-heal re-PUTs to the CORRECT task even when a hidden claim left a
  # stale TASK_ID behind. Fall back to the env cache only if the URL has no id.
  local _tid
  _tid=$(task_id_from_command "${COMMAND:-}")
  [ -n "$_tid" ] || _tid="${TASK_ID:-}"
  [ -n "$_tid" ] || return 0

  # Healthy 2xx recorded for THIS task → do not re-upload (snapshot
  # semantics anchor at after_doing time; avoid pointless API load).
  # Missing file, different task id, or non-2xx/empty code → retry.
  local _state_file="$PROJECT_DIR/.stride-diff-upload-state"
  local _state_task="" _state_code="" _state_base=""
  if [ -f "$_state_file" ]; then
    _state_task=$(grep '^task_id=' "$_state_file" 2>/dev/null | head -n 1 | cut -d= -f2- || true)
    _state_code=$(grep '^http_code=' "$_state_file" 2>/dev/null | head -n 1 | cut -d= -f2- || true)
    _state_base=$(grep '^base=' "$_state_file" 2>/dev/null | head -n 1 | cut -d= -f2- || true)
  fi
  if [ "$_state_task" = "$_tid" ]; then
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
  # (D142) Prefer the base finalize_after_doing resolved and persisted for THIS
  # task — re-resolving here would re-judge against origin refs the after_doing
  # section's own `git push` may have moved (a correct base would look stale and
  # recompute to HEAD, emptying the snapshot). Only when no persisted judgment
  # exists (process killed before any PUT) run the trust guard fresh — the retry
  # must never resurrect a stale base the primary capture would have refused.
  local _snapshot _http_code _snap_base
  if [ "$_state_task" = "$_tid" ] && [ -n "$_state_base" ]; then
    _snap_base="$_state_base"
  else
    _snap_base=$( (cd "$PROJECT_DIR" 2>/dev/null && resolve_snapshot_base "${TASK_BASE_REF:-}") || printf '%s' "${TASK_BASE_REF:-}")
  fi
  _snapshot=$( (cd "$PROJECT_DIR" && capture_changed_files "$_snap_base") 2>/dev/null || printf '[]')
  printf '%s\n' "$_snapshot" > "$PROJECT_DIR/.stride-changed-files.json" 2>/dev/null || true
  _http_code=$(upload_changed_files_snapshot "$_tid" "$_api_base" "$_token")
  record_diff_upload_state "$_tid" "$_http_code" "$_snap_base"
  # (W1658) before_review is the LAST retry. If it still did not land, the diff
  # is definitively lost for this task — surface it LOUDLY (distinct from the
  # per-attempt warning in upload_changed_files_snapshot) and mark the state file
  # unresolved so the failure is actionable and never silently swallowed. A later
  # successful PUT overwrites the state file, clearing the mark.
  case "$_http_code" in
    2*) : ;;
    *)
      printf 'stride-hook: CHANGED_FILES UPLOAD UNRESOLVED for task %s (HTTP %s) after the before_review retry — the review will show NO file diffs. Re-run the changed_files PUT to recover.\n' \
        "$_tid" "$_http_code" >&2
      printf 'unresolved=yes\n' >> "$PROJECT_DIR/.stride-diff-upload-state" 2>/dev/null || true
      ;;
  esac
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

# (W1457) Record the set of paths already modified or untracked at claim time,
# each with its current blob hash, so capture_changed_files can exclude changes
# that predate the claim. Persisted on disk (claim and completion can happen in
# different sessions) and cleaned up with the other hook artifacts. Best-effort:
# any failure leaves an absent/empty baseline, which capture treats as "no
# exclusion".
record_dirty_baseline() {
  local _base="$1"
  local _bl_file="$PROJECT_DIR/.stride-dirty-baseline"
  rm -f "$_bl_file" 2>/dev/null || true
  command -v git > /dev/null 2>&1 || return 0
  [ -n "$_base" ] || return 0
  local _paths _p _h
  _paths=$( (cd "$PROJECT_DIR" 2>/dev/null && {
    git diff --name-only "$_base" 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  } | awk 'NF && !seen[$0]++') || true )
  [ -n "$_paths" ] || return 0
  while IFS= read -r _p; do
    [ -z "$_p" ] && continue
    if [ -f "$PROJECT_DIR/$_p" ]; then
      _h=$( (cd "$PROJECT_DIR" && git hash-object -- "$_p") 2>/dev/null || echo "unhashable")
    else
      _h="absent"
    fi
    printf '%s %s\n' "$_h" "$_p" >> "$_bl_file" 2>/dev/null || true
  done <<< "$_paths"
  return 0
}

# (D142) Rewrite TASK_BASE_REF — and re-record the dirty baseline — AFTER the
# ## before_doing section has run. The section's `git pull` moves HEAD, so a
# base captured before it anchors the after_doing diff at the PRE-pull commit
# and the snapshot spans another clone's pulled work (the D132/W1678 incident).
# Called from the main flow right after run_stride_section returns for the
# before_doing route, regardless of the section's exit code (the claim already
# succeeded — AfterTool cannot veto it, and a partially-run section still leaves
# HEAD more accurate than the pre-pull value) and with no jq dependency (the
# identity refresh is jq-gated; this must not be). Skips silently when HEAD is
# unresolvable (not a git repo) — the pre-section strip already removed any
# inherited TASK_BASE_REF in that case.
finalize_before_doing() {
  [ "${HOOK_NAME:-}" = "before_doing" ] || return 0
  local _base_ref _preserved
  _base_ref=$( (cd "$PROJECT_DIR" && git rev-parse HEAD) 2>/dev/null || true)
  [ -n "$_base_ref" ] || return 0
  # TASK_BASE_REF_TRUSTED marks a base written by THIS post-before_doing
  # capture: it is the task branch point by construction, so the trust guard's
  # branch-point rule (rule 3) does not second-guess it — a workflow that
  # pushes its own task commits before completing would otherwise make a
  # correct base look like it predates the branch point. Inherited caches
  # (older plugin, previous session) lack the marker and get the full guard.
  _preserved=$(grep -v -e '^TASK_BASE_REF=' -e '^TASK_BASE_REF_TRUSTED=' "$ENV_CACHE" 2>/dev/null || true)
  {
    [ -n "$_preserved" ] && printf '%s\n' "$_preserved"
    echo "TASK_BASE_REF=$(sq_escape "$_base_ref")"
    echo "TASK_BASE_REF_TRUSTED='1'"
  } > "$ENV_CACHE" 2>/dev/null || true
  export TASK_BASE_REF="$_base_ref"
  export TASK_BASE_REF_TRUSTED="1"
  # (W1457→D142) The dirty baseline moves with the base capture: post-pull
  # paths hashed against the post-pull tree, so the exclusion set and the diff
  # anchor can never disagree.
  record_dirty_baseline "$_base_ref"
  return 0
}

# (W1456) True when the accumulated LOGICAL line ends in a backslash that
# escapes the newline — i.e. the backslash is unescaped and not inside single
# quotes. Mirrors real shell rules: outside quotes and inside double quotes,
# backslash-newline is a continuation; inside single quotes a backslash is a
# literal character; `\\` at end of line is an escaped backslash, not a
# continuation. Callers pass the accumulated logical line so quote state
# carries across joins.
line_continues() {
  # NOTE: _len must be declared in a SEPARATE local statement — the words of a
  # single `local a=$1 b=${#a}` command are expanded before any assignment
  # lands, so ${#_line} would read the (unset) outer variable and abort under
  # `set -u`.
  local _line="$1"
  local _i=0 _len=${#_line} _state="none" _c
  while [ "$_i" -lt "$_len" ]; do
    _c="${_line:_i:1}"
    if [ "$_state" = "single" ]; then
      [ "$_c" = "'" ] && _state="none"
      _i=$((_i + 1))
    elif [ "$_c" = "\\" ]; then
      # Backslash escapes the next char; with no next char it escapes the
      # newline — that IS the continuation marker.
      [ $((_i + 1)) -eq "$_len" ] && return 0
      _i=$((_i + 2))
    elif [ "$_state" = "double" ]; then
      [ "$_c" = '"' ] && _state="none"
      _i=$((_i + 1))
    else
      case "$_c" in
        "'") _state="single" ;;
        '"') _state="double" ;;
      esac
      _i=$((_i + 1))
    fi
  done
  return 1
}

# (W1455) Portable millisecond clock. GNU date supports %N (nanoseconds);
# BSD/macOS date prints a literal trailing 'N', so probe once and fall back to
# perl Time::HiRes (ships with macOS), then to whole-second granularity times
# 1000. STRIDE_HOOK_TIME_SOURCE forces the source for tests: ns|perl|seconds.
STRIDE_TIME_SOURCE_RESOLVED=""
resolve_time_source() {
  if [ -z "$STRIDE_TIME_SOURCE_RESOLVED" ]; then
    case "${STRIDE_HOOK_TIME_SOURCE:-}" in
      ns|perl|seconds) STRIDE_TIME_SOURCE_RESOLVED="${STRIDE_HOOK_TIME_SOURCE}" ;;
      *)
        if [[ "$(date +%s%N 2>/dev/null)" =~ ^[0-9]+$ ]]; then
          STRIDE_TIME_SOURCE_RESOLVED="ns"
        elif command -v perl >/dev/null 2>&1 && \
             [[ "$(perl -MTime::HiRes=time -e 'printf "%d", time()*1000' 2>/dev/null)" =~ ^[0-9]+$ ]]; then
          STRIDE_TIME_SOURCE_RESOLVED="perl"
        else
          STRIDE_TIME_SOURCE_RESOLVED="seconds"
        fi ;;
    esac
  fi
  printf '%s' "$STRIDE_TIME_SOURCE_RESOLVED"
}

# Current wall-clock time in integer milliseconds via the resolved source.
# Callers invoke this through $(now_ms), a subshell — so the cache only helps
# when the PARENT shell warmed it first (run_stride_section does) and the
# subshell inherits the resolved value.
now_ms() {
  resolve_time_source > /dev/null
  case "$STRIDE_TIME_SOURCE_RESOLVED" in
    ns)
      local _ns
      _ns=$(date +%s%N)
      printf '%s' $(( _ns / 1000000 ))
      ;;
    perl)
      perl -MTime::HiRes=time -e 'printf "%d", time()*1000'
      ;;
    *)
      printf '%s' $(( $(date +%s) * 1000 ))
      ;;
  esac
}

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
  local _cmd_list _pending
  _cmd_list=()
  _pending=""
  # (W1456) Physical lines are joined into LOGICAL lines first: a line ending
  # in an unquoted, unescaped backslash continues onto the next physical line
  # (the backslash-newline pair is removed, per shell semantics). Trimming and
  # comment/blank skipping apply to logical lines AFTER joining — a `#` on a
  # continuation line is part of the joined command (where the shell treats it
  # as a trailing comment), never a skip. One command per logical line remains
  # the model.
  while IFS= read -r _cmd; do
    _cmd="${_cmd%$'\r'}"
    if [ -n "$_pending" ]; then
      _cmd="${_pending}${_cmd}"
      _pending=""
    else
      # Comments never continue: `#` lexes to end-of-line in shell, so a
      # trailing backslash on a standalone comment line is inert — skip the
      # line here so it cannot swallow the next command. (A `#` on a
      # continuation body line still joins, handled above.)
      case "${_cmd#"${_cmd%%[![:space:]]*}"}" in
        \#*) continue ;;
      esac
    fi
    if line_continues "$_cmd"; then
      _pending="${_cmd%\\}"
      continue
    fi
    _trimmed="${_cmd#"${_cmd%%[![:space:]]*}"}"
    [ -z "$_trimmed" ] && continue
    case "$_trimmed" in \#*) continue ;; esac
    _cmd_list+=("$_trimmed")
  done <<< "$_commands"
  # A trailing backslash on the section's last line: emit the accumulated
  # command with the continuation marker already stripped — never hang or
  # drop it.
  if [ -n "$_pending" ]; then
    _trimmed="${_pending#"${_pending%%[![:space:]]*}"}"
    if [ -n "$_trimmed" ]; then
      case "$_trimmed" in \#*) : ;; *) _cmd_list+=("$_trimmed") ;; esac
    fi
  fi

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

  local _completed_file _output_file
  _completed_file=$(mktemp)
  # Parallel to _completed_file: one JSON object per successful command holding
  # its tail-truncated stdout/stderr, slurped into the success JSON's
  # commands_output array (D65). Keeps passing-gate output off fd 2 so the host
  # does not render it under a false hook-error label.
  _output_file=$(mktemp)
  local _start_secs
  _start_secs=$(date +%s)
  # (W1455) Millisecond wall clock for duration_ms reporting; the seconds clock
  # above stays for any whole-second bookkeeping. Warm the time-source cache in
  # THIS shell first — $(now_ms) runs in a subshell, so without this the probe
  # would repeat on every call.
  local _start_ms
  resolve_time_source > /dev/null
  _start_ms=$(now_ms)
  local _cmd_index=0
  local _cmd_total=${#_cmd_list[@]}
  local _cmd_stdout_file _cmd_stderr_file _cmd_exit _cmd_stdout _cmd_stderr
  local _remaining_file _completed_json _remaining_json _output_json _end_secs _duration _i

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
      # Do NOT cat the passing command's output to fd 2: the host renders any
      # hook stderr under a red hook-error label even on exit 0 (D65), so a
      # passing gate would show its own success output as a scary error.
      # Instead capture a tail-truncated copy — same -50 cap as the failure
      # path — into _output_file as a JSON object, folded into the success
      # JSON's commands_output array below so agents keep visibility.
      if [ "$HAS_JQ" = "true" ]; then
        _cmd_stdout=$(tail -50 "$_cmd_stdout_file")
        _cmd_stderr=$(tail -50 "$_cmd_stderr_file")
        jq -n \
          --arg command "$_trimmed" \
          --arg stdout "$_cmd_stdout" \
          --arg stderr "$_cmd_stderr" \
          '{command: $command, stdout: $stdout, stderr: $stderr}' >> "$_output_file"
      fi
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
      rm -f "$_completed_file" "$_remaining_file" "$_output_file"
      return 2
    fi

    rm -f "$_cmd_stdout_file" "$_cmd_stderr_file"
    _cmd_index=$((_cmd_index + 1))
  done

  _end_secs=$(date +%s)
  _duration=$((_end_secs - _start_secs))
  # (W1455) duration_ms is the hook-execution.md contract field. Guard against
  # clock weirdness — never emit a negative duration.
  local _duration_ms
  _duration_ms=$(( $(now_ms) - _start_ms ))
  [ "$_duration_ms" -lt 0 ] && _duration_ms=0

  if [ "$HAS_JQ" = "true" ]; then
    _completed_json=$(jq -R . < "$_completed_file" | jq -s . 2>/dev/null || echo "[]")
    _output_json=$(jq -s . < "$_output_file" 2>/dev/null || echo "[]")

    # duration_seconds is DEPRECATED in favor of duration_ms (the
    # hook-execution.md field name) — kept for one release for any consumer
    # still parsing it.
    jq -n \
      --arg hook "$_section" \
      --argjson duration "$_duration" \
      --argjson duration_ms "$_duration_ms" \
      --argjson completed "$_completed_json" \
      --argjson outputs "$_output_json" \
      '{
        hook: $hook,
        status: "success",
        commands_completed: $completed,
        commands_output: $outputs,
        duration_ms: $duration_ms,
        duration_seconds: $duration
      }'
  fi

  rm -f "$_completed_file" "$_output_file"

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

# --- Server-supplied hook env forwarding (W1519, mirrors stride W1453) ---
# The Step 6 env matrix (skills/stride-workflow/SKILL.md) declares the
# server's hook env block the single source of truth for the variables the
# executor exports. The helpers below extract the `env` object from the hook
# entry of an intercepted response (singular `.hook` on claim responses,
# `.hooks[]` on /complete and /mark_reviewed), escape each value, export it
# into the running shell (set -a), and append it to the env cache so
# follow-up agent commands (e.g. the after_goal PATCH) can still read the
# values. Keys the server omits export as empty strings.

# Single-quote a value for a file sourced by the shell. Embedded single
# quotes become '\'' — nothing inside single quotes is ever interpreted, so
# a crafted task title cannot inject commands into the executor.
sq_escape() {
  # _q is the 4-char sequence '\'' (close quote, escaped quote, reopen quote).
  local _q="'\\''"
  local _v="${1//\'/$_q}"
  printf "'%s'" "$_v"
}

# Peel the API payload out of the Gemini/Claude hook input: .tool_response may
# wrap the API JSON as {"stdout":"<json>"} (Bash tool) or carry it directly
# (other harnesses). Prints the payload JSON, or nothing when unparseable/no jq.
extract_response_payload() {
  local _hook_input="$1"
  local _response _payload

  [ "$HAS_JQ" = "true" ] || return 0
  [ -n "$_hook_input" ] || return 0

  _response=$(echo "$_hook_input" | jq -r '.tool_response // ""' 2>/dev/null || echo "")
  [ -n "$_response" ] || return 0

  if echo "$_response" | jq -e 'type == "object" and has("stdout")' > /dev/null 2>&1; then
    _payload=$(echo "$_response" | jq -r '.stdout // ""' 2>/dev/null)
  else
    _payload="$_response"
  fi

  printf '%s' "$_payload"
}

# (W2144) Loop-state helpers, ported from the Claude Code original (W2123).
#
# Structurally keep response bodies, task free text and credentials out of the
# file: every string that reaches it must first match a conservative charset.
# A value that fails this is refused rather than sanitised - the file records
# two identifiers, and anything that is not identifier-shaped does not belong
# in it.
loop_state_safe() {
  [ -n "${1:-}" ] || return 1
  [ "${#1}" -le 64 ] || return 1
  # The character set is ENUMERATED, never written as A-Z / a-z ranges. A glob
  # bracket RANGE is collation-ordered rather than codepoint-ordered on bash
  # < 5.0 (macOS ships 3.2) under a UTF-8 locale, so `A-Z` there also swallows
  # accented Latin letters: an identifier of "We\u0301144" passed this gate on
  # POSIX while the PowerShell twin's codepoint-based -cmatch refused it, and
  # the two halves then recorded different things for one input - a split brain
  # in the very gate this file feeds. An explicit enumeration has no collation
  # order to depend on, so both halves agree on every locale.
  case "$1" in
    *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.:-]*) return 1 ;;
  esac
  return 0
}

# A payload describes a SUCCESSFUL completion only when it carries the two
# fields the state file is built from, AT THE RIGHT JSON TYPES. Every
# non-success body the API emits (validation errors, 404s, 422s) lacks `.data`
# entirely, so this is the discriminator - a 422 body lands on stdout exactly
# like a success and would otherwise be indistinguishable from one.
#
# `type ==` is load-bearing, not decoration: `jq -r` prints the STRING "true"
# and the BOOLEAN true identically, so a body carrying `"needs_review":"true"`
# would survive a later text comparison. The PowerShell twin asserts the same
# two types via -isnot [string] / -isnot [bool]; keep the pair in lockstep.
loop_state_payload_ok() {
  printf '%s' "${1:-}" | jq -e '
    try (
      (.data.identifier | type == "string" and length > 0)
      and (.data.needs_review | type == "boolean")
    ) catch false
  ' > /dev/null 2>&1
}

# Atomic and never fatal: the temp file is created in the DESTINATION directory
# so the rename is same-fs, a failure at any point leaves no temp behind, and
# the function still returns 0. This is a gate input, not a correctness
# dependency - a completion must never fail because the loop state could not
# be recorded.
write_loop_state() {
  local _json="$1" _tmp
  # `mv` into a DIRECTORY succeeds by relocating the temp inside it, so the
  # failure branch below would never run: the record would land where no reader
  # looks and the temp would survive indefinitely. Refuse any destination that
  # exists and is not a regular file, rather than assuming mv fails when it is
  # unusable.
  if [ -e "$LOOP_STATE_FILE" ] && [ ! -f "$LOOP_STATE_FILE" ]; then
    printf 'stride-hook: loop-state path is not a regular file; not recording\n' >&2
    return 0
  fi
  # This is the first artifact this port writes into a .stride/ SUBDIRECTORY -
  # every other hook state file is a flat .stride-* dotfile at the project root
  # - so the directory may legitimately not exist yet.
  mkdir -p "$PROJECT_DIR/.stride" 2>/dev/null || {
    printf 'stride-hook: could not create .stride/ for the loop state; continuing\n' >&2
    return 0
  }
  _tmp=$(mktemp "$PROJECT_DIR/.stride/loop-state.XXXXXX" 2>/dev/null) || {
    printf 'stride-hook: could not stage the loop state; continuing\n' >&2
    return 0
  }
  if printf '%s\n' "$_json" > "$_tmp" 2>/dev/null; then
    mv -f "$_tmp" "$LOOP_STATE_FILE" 2>/dev/null || {
      printf 'stride-hook: could not move the loop state into place; continuing\n' >&2
      rm -f "$_tmp" 2>/dev/null
    }
  else
    printf 'stride-hook: could not write the loop state; continuing\n' >&2
    rm -f "$_tmp" 2>/dev/null
  fi
  return 0
}

# --- The claimed task file (W2463, the port of stride W2248) ----------------
# A successful claim leaves the task's `data` object in
# .stride/.task-<stem>.json, so the workflow can hand subagents a path instead
# of retyping the task's fields into every dispatch prompt. A retyped copy
# drifts; a file the hook wrote from the response cannot.
#
# Everything in the file is task free text. Readers treat it as data. Nothing
# here evaluates it, and the file NAME is never taken from free text without
# passing the anchored charset test below.

# The file name stem for a task object: its identifier when that is 1-64
# characters of [A-Za-z0-9_-] (a whole-string \A...\z test - `^...$` in jq lets
# a trailing newline through), otherwise its non-negative integer id, otherwise
# nothing at all.
task_file_stem() { # $1 = task object JSON -> stem on stdout, or empty
  printf '%s' "${1:-}" | jq -r '
    if (.identifier | type) == "string"
       and (.identifier | test("\\A[A-Za-z0-9_-]{1,64}\\z")) then .identifier
    elif (.id | type) == "number" and .id >= 0 and (.id | floor) == .id
       then (.id | tostring)
    elif (.id | type) == "string" and (.id | test("\\A[0-9]{1,20}\\z")) then .id
    else empty end' 2>/dev/null
}

# Does the claim response belong to the claim this command asked for?
#
# The command text arrives on STDIN, never as an argument: it carries the
# Authorization header, and argv is visible to every local process (and is
# length-capped). $1 is the task object; $2 is "require" when the command MUST
# name the identifier it asked for.
#
# The requested identifier is read from the claim body in the command. Two
# spellings are recognised, in order: the plain `"identifier":"W1"` of a
# single-quoted -d body, and the backslash-escaped `\"identifier\":\"W1\"` of a
# double-quoted one. The escaped spelling is consulted only when the plain one
# is absent, because inside a plain body an escaped key is just text inside
# some other string value (a before_doing_result output, say) and must not
# count as a second request. Within the spelling in use, EVERY occurrence of
# the key has to carry a clean string value equal to the response's
# identifier; a null, a number or a value that cannot be read cleanly leaves
# the claim unproven rather than letting it slip through.
#
# When the command names no identifier at all (a next-available claim, or a
# body sent with -d @file) the response itself is the proof, and that holds by
# construction in this port: TASK_JSON is only ever parsed from THIS call's own
# tool_response, and there is no response file that outlives a call. The one
# exception is the persisted-output path, whose file path is read out of
# response text; there the caller passes "require".
claim_identity_proven() {
  local _rid _need="${2:-}"
  _rid=$(printf '%s' "${1:-}" | jq -c '.identifier' 2>/dev/null) || return 1
  [ -n "$_rid" ] || return 1
  jq -Rse --argjson rid "$_rid" --arg need "$_need" '
    def tier(key; val):
      ([scan(key)] | length) as $k
      | if $k == 0 then null
        else ([scan(val) | .[0]]) as $v
          | (($v | length) == $k and ($v | all(. == $rid)))
        end;
    tier("\"identifier\"[ \t\r\n]*:";
         "\"identifier\"[ \t\r\n]*:[ \t\r\n]*\"([^\"\\\\]*)\"") as $plain
    | if $plain != null then $plain
      else
        tier("\\\\\"identifier\\\\\"[ \t\r\n]*:";
             "\\\\\"identifier\\\\\"[ \t\r\n]*:[ \t\r\n]*\\\\\"([^\"\\\\]*)\\\\\"") as $esc
        | if $esc != null then $esc
          else ($need != "require")
          end
      end' > /dev/null 2>&1
}

# Write the task object to .stride/.task-<stem>.json. Same mechanics as
# write_loop_state above - staged beside the destination so the rename stays on
# one filesystem, no temp survives any failure, a destination that is not a
# regular file is refused, and nothing here can fail the claim. Writes nothing
# to stdout: Gemini parses that stream as the hook's control document.
write_task_file() {
  local _json _stem _dest _tmp
  # Compact it. The data-wrapped shapes are already `jq -c`, but a bare task
  # object arrives as the response text exactly as the server sent it.
  _json=$(printf '%s' "${1:-}" | jq -c '.' 2>/dev/null)
  [ -n "$_json" ] || return 0
  _stem=$(task_file_stem "$_json")
  if [ -z "$_stem" ]; then
    printf 'stride-hook: the claimed task has no usable identifier or id; not writing the task file\n' >&2
    return 0
  fi
  _dest="$PROJECT_DIR/.stride/.task-$_stem.json"
  if [ -e "$_dest" ] && [ ! -f "$_dest" ]; then
    printf 'stride-hook: task-file path is not a regular file; not writing the task file\n' >&2
    return 0
  fi
  mkdir -p "$PROJECT_DIR/.stride" 2>/dev/null || {
    printf 'stride-hook: could not create .stride/ for the task file; continuing\n' >&2
    return 0
  }
  _tmp=$(mktemp "$PROJECT_DIR/.stride/task-file.XXXXXX" 2>/dev/null) || {
    printf 'stride-hook: could not stage the task file; continuing\n' >&2
    return 0
  }
  if printf '%s\n' "$_json" > "$_tmp" 2>/dev/null; then
    mv -f "$_tmp" "$_dest" 2>/dev/null || {
      printf 'stride-hook: could not move the task file into place; continuing\n' >&2
      rm -f "$_tmp" 2>/dev/null
    }
  else
    printf 'stride-hook: could not write the task file; continuing\n' >&2
    rm -f "$_tmp" 2>/dev/null
  fi
  return 0
}

# (W2524) Task attachments: download each file the proven claim lists into
# .stride/attachments/<STEM>/, then write manifest.json LAST. A port of
# stride's download_task_attachments (W2522), which is the source of record;
# the contract is stride's docs/porting-attachments.md, and every name, cap,
# reason code and manifest field below comes from it. The two halves of this
# port write byte-identical manifests for the same claim.
#
# Runs only from the claim route, only when THIS call's own response proved the
# task identity (claim_identity_proven, the same gate write_task_file sits
# behind), and only after the ## before_doing section has finished, so a slow download can neither shrink
# that section's budget nor change its blocking result. Never fatal: every
# failure is a manifest entry or one stderr line, the hook's exit code and its
# stdout are never touched, and nothing here prints to stdout.
#
# The bearer token reaches curl on STDIN (`-H @-`, fed by the printf builtin),
# so it never appears in an argv that `ps` can read. It is never logged and
# never written to a file. Redirects are NOT followed (no -L): a 3xx is
# recorded as http_<code>, which is how the token is kept off every other host.
ATTACHMENT_FILE_BYTES=26214400
ATTACHMENT_MAX_FILES=20
ATTACHMENT_TOTAL_BYTES=104857600
ATTACHMENT_BUDGET_SECONDS=120

# The plan: one entry per server entry, in server order, with the five
# pre-download checks applied in the contract's order. count_cap and total_cap
# count ACCEPTED entries only. `pending` marks an accepted entry; the download
# loop settles it. $tid is the claimed task's numeric id as a string, or null.
ATTACHMENT_PLAN_JQ='
def att_name:
  (if type == "string" then . else "" end)
  | (split("/") | last // "") | (split("\\") | last // "")
  | explode
  | map(if (. >= 48 and . <= 57) or (. >= 65 and . <= 90) or (. >= 97 and . <= 122)
           or . == 45 or . == 46 or . == 95 then . else 95 end)
  | implode
  | sub("\\A\\.+"; "")
  | if length > 100 then
      (rindex(".")) as $d
      | if $d != null and $d > 0 and (length - $d) <= 16
        then .[0:(100 - (length - $d))] + .[$d:]
        else .[0:100] end
    else . end
  | if . == "" then "attachment" else . end;
def att_id:
  # A number id must render as plain digits: jq 1.7 prints 1e3 as "1E+3" where
  # the PowerShell half would keep the literal, so anything else is refused in
  # both halves rather than kept in one.
  if type == "number" then (tostring | if test("\\A[0-9]{1,64}\\z") then . else null end)
  elif type == "string" and test("\\A[A-Za-z0-9-]{1,64}\\z") then .
  else null end;
(.id | if type == "number" then (tostring | if test("\\A[0-9]{1,20}\\z") then . else null end)
       elif type == "string" and test("\\A[0-9]{1,20}\\z") then . else null end) as $tid
| (.attachments | if type == "array" then . else [] end) as $list
| reduce range(0; $list | length) as $i ({n: 0, total: 0, seen: {}, names: {}, out: []};
    ($list[$i] | if type == "object" then . else {} end) as $o
    | ($o.id | att_id) as $sid
    | (if $sid == null then null else ($sid + "-" + ($o.filename | att_name)) end) as $local
    | ($o.download_url
       | if $tid != null and type == "string"
            and test("\\A/api/tasks/" + $tid + "/attachments/[0-9]{1,20}\\z")
         then . else null end) as $path
    # A byte_size must be written as plain digits. jq 1.7 keeps the literal
    # of a number, so 64.0 or 64.00000000000000001 (which a double rounds to 64)
    # is refused here exactly as the PowerShell half refuses it (W2524).
    | ($o.byte_size
       | if type == "number" and (tostring | test("\\A[0-9]{1,20}\\z")) then . else null end) as $size
    # An id, or a saved name, already taken by an accepted entry,
    # case-insensitively, would give two entries one local file, so it is
    # refused as unsafe_id (W2524). The name matters on its own: id "a" with
    # "b-x" and id "a-b" with "x" both save as a-b-x.
    | (if $sid == null or (.seen[$sid | ascii_downcase] // false)
          or (.names[$local | ascii_downcase] // false) then "unsafe_id"
       elif $path == null then "unsafe_url"
       elif $size == null or $size > $file_bytes then "too_large"
       elif .n >= $max_files then "count_cap"
       elif .total + $size > $total_bytes then "total_cap"
       else null end) as $reason
    | .out += [{
        id: $o.id, filename: $o.filename,
        local_file: (if $reason == null then $local else null end),
        content_type: $o.content_type, byte_size: $o.byte_size, sha256: $o.sha256,
        comment_id: $o.comment_id, uploaded_at: $o.uploaded_at, download_path: $path,
        status: (if $reason == null then "pending" else "skipped" end), reason: $reason }]
    | if $reason == null then .n += 1 | .total += $size | .seen[$sid | ascii_downcase] = true
        | .names[$local | ascii_downcase] = true else . end)
| .out'

# The wall-clock budget. STRIDE_ATTACHMENT_BUDGET_SECONDS may only SHORTEN it
# (tests use 0); anything else, including a larger value, is ignored, so no
# environment can push the download past the AfterTool timeout.
attachment_budget_seconds() {
  local _b="${STRIDE_ATTACHMENT_BUDGET_SECONDS:-}"
  case "$_b" in
    '' | *[!0-9]*) printf '%s' "$ATTACHMENT_BUDGET_SECONDS"; return 0 ;;
  esac
  if [ "${#_b}" -gt 3 ] || [ "$((10#$_b))" -gt "$ATTACHMENT_BUDGET_SECONDS" ]; then
    printf '%s' "$ATTACHMENT_BUDGET_SECONDS"
  else
    printf '%s' "$((10#$_b))"
  fi
}

# SHA-256 of $1 as 64 lowercase hex characters, or empty when no tool exists.
attachment_sha256() {
  local _out=""
  if command -v shasum > /dev/null 2>&1; then
    _out=$(shasum -a 256 "$1" 2>/dev/null) || _out=""
  elif command -v sha256sum > /dev/null 2>&1; then
    _out=$(sha256sum "$1" 2>/dev/null) || _out=""
  elif command -v openssl > /dev/null 2>&1; then
    _out=$(openssl dgst -sha256 -r "$1" 2>/dev/null) || _out=""
  fi
  _out="${_out%%[!0-9a-fA-F]*}"
  [ "${#_out}" -eq 64 ] || return 0
  printf '%s' "$_out" | tr 'A-F' 'a-f'
}

# A directory this function may write into: absent, or a real directory that
# is not a symlink. Anything else refuses the whole download.
attachment_dir_ok() {
  [ -L "$1" ] && return 1
  [ -e "$1" ] && [ ! -d "$1" ] && return 1
  return 0
}

download_task_attachments() {
  local _task="${1:-}" _stem _root _adir _tdir _plan _count _api _tok _proto _ua
  local _budget _deadline _left _results="" _idx _path _size _sha _local _part
  local _code _codef _rc _reason _got _actual _ok=0 _skip=0 _fail=0 _tmp _tmeta
  [ "${HAS_JQ:-false}" = "true" ] || return 0
  [ -n "$_task" ] || return 0
  _stem=$(task_file_stem "$_task")
  [ -n "$_stem" ] || return 0
  _root="$PROJECT_DIR/.stride"
  _adir="$_root/attachments"
  _tdir="$_adir/$_stem"
  _count=$(printf '%s' "$_task" | jq -r '.attachments | if type == "array" then length else 0 end' 2>/dev/null)
  case "$_count" in '' | *[!0-9]*) _count=0 ;; esac
  if ! attachment_dir_ok "$_root" || ! attachment_dir_ok "$_adir" || ! attachment_dir_ok "$_tdir"; then
    [ "$_count" -eq 0 ] || printf 'stride: attachments %s: a .stride, .stride/attachments or task directory is a symlink or not a directory; nothing written\n' "$_stem" >&2
    return 0
  fi
  if [ "$_count" -eq 0 ]; then
    # No attachments: create nothing. A directory left by an EARLIER claim of
    # this task is removed, manifest first, so its manifest can never describe
    # this claim.
    if [ -d "$_tdir" ]; then
      rm -f "$_tdir/manifest.json" 2>/dev/null
      rm -rf "$_tdir" 2>/dev/null
    fi
    return 0
  fi
  _plan=$(printf '%s' "$_task" | jq -c \
    --argjson file_bytes "$ATTACHMENT_FILE_BYTES" --argjson max_files "$ATTACHMENT_MAX_FILES" \
    --argjson total_bytes "$ATTACHMENT_TOTAL_BYTES" "$ATTACHMENT_PLAN_JQ" 2>/dev/null)
  if [ -z "$_plan" ]; then
    printf 'stride: attachments %s: could not read the attachment list; nothing written\n' "$_stem" >&2
    return 0
  fi
  # .gitignore first, staged and renamed so a symlinked .gitignore is replaced
  # rather than written through.
  if ! mkdir -p "$_adir" 2>/dev/null || ! attachment_dir_ok "$_adir"; then
    printf 'stride: attachments %s: could not create .stride/attachments; nothing written\n' "$_stem" >&2
    return 0
  fi
  # A .gitignore that is a symlink is removed rather than renamed onto (mv
  # onto a link to a directory would move the temp INTO that directory); one
  # that is a directory refuses the run.
  [ -L "$_adir/.gitignore" ] && rm -f "$_adir/.gitignore" 2>/dev/null
  if [ -e "$_adir/.gitignore" ] && [ ! -f "$_adir/.gitignore" ]; then
    printf 'stride: attachments %s: .stride/attachments/.gitignore is not a regular file; nothing downloaded\n' "$_stem" >&2
    return 0
  fi
  # A staging file an interrupted earlier run left is not ignored until the
  # .gitignore exists, so a later git add -A would commit it: sweep both
  # halves' staging names (regular files only; find -type f skips links).
  find "$_adir" -maxdepth 1 -type f \( -name '.gitignore.??????' -o -name '.stage.????????.???' \) \
    -exec rm -f {} + 2>/dev/null
  # A missing .gitignore is created in place with noclobber (O_EXCL, never
  # through a link), so no staging file exists in the window before it; one
  # that already holds exactly '*' is left alone. Only a wrong one is staged.
  if [ ! -e "$_adir/.gitignore" ] && [ ! -L "$_adir/.gitignore" ]; then
    ( set -C; printf '*\n' > "$_adir/.gitignore" ) 2>/dev/null
  fi
  _tmp=""
  if printf '*\n' | cmp -s - "$_adir/.gitignore" 2>/dev/null && [ ! -L "$_adir/.gitignore" ]; then
    :
  elif ! _tmp=$(mktemp "$_adir/.gitignore.XXXXXX" 2>/dev/null) || ! printf '*\n' > "$_tmp" 2>/dev/null || ! mv -f "$_tmp" "$_adir/.gitignore" 2>/dev/null; then
    [ -n "$_tmp" ] && rm -f "$_tmp" 2>/dev/null
    printf 'stride: attachments %s: could not write .stride/attachments/.gitignore; nothing downloaded\n' "$_stem" >&2
    return 0
  fi
  # A re-claim replaces the directory. The old manifest goes FIRST, so a
  # reader never sees a manifest naming files that are already gone.
  if [ -d "$_tdir" ]; then
    rm -f "$_tdir/manifest.json" 2>/dev/null
    rm -rf "$_tdir" 2>/dev/null
  fi
  if ! mkdir "$_tdir" 2>/dev/null || ! attachment_dir_ok "$_tdir"; then
    printf 'stride: attachments %s: could not create the task directory; nothing downloaded\n' "$_stem" >&2
    return 0
  fi

  # The URL and token come from .stride_auth.md ONLY. Both resolvers fall
  # back to text in the intercepted command, which is right for the
  # changed_files upload but not here: the contract joins download paths to
  # the configured API URL and nothing else. Plain http is allowed only for a
  # loopback API URL; anything else, or no token, fetches nothing.
  _api=$(COMMAND='' resolve_stride_api_url)
  _api="${_api%/}"
  _tok=$(COMMAND='' resolve_stride_api_token)
  _proto=''
  case "$_api" in
    https://?*) _proto='=https' ;;
    http://*)
      if printf '%s' "$_api" | grep -Eq '^http://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]*)?$'; then
        _proto='=http'
      fi
      ;;
  esac
  [ -n "$_tok" ] || _proto=
  _ua=$(curl --version 2>/dev/null | head -n 1)
  _ua="${_ua#curl }"; _ua="${_ua%% *}"
  case "$_ua" in '' | *[!0-9.]*) _ua='8' ;; esac
  _ua="curl/$_ua"

  _budget=$(attachment_budget_seconds)
  # The manifest reports the contract budget; the deadline is ALSO held inside
  # Gemini's 300 s AfterTool timeout (hooks/hooks.json; $SECONDS is this
  # hook's own age), because the before_doing section has no timeout of its
  # own here and may have used most of it, and a hook killed mid-download
  # loses its stdout -- the structured result Gemini reads.
  _left=$(( 285 - SECONDS ))
  [ "$_left" -lt "$_budget" ] || _left="$_budget"
  _deadline=$(( $(date +%s) + _left ))
  while IFS="$(printf '\t')" read -r _idx _path _size _sha _local; do
    [ -n "$_idx" ] || continue
    _left=$(( _deadline - $(date +%s) ))
    if [ "$_left" -le 0 ]; then
      _results="${_results}${_idx} skipped time_budget"$'\n'
      continue
    fi
    _part=$(mktemp "$_tdir/.part.XXXXXX" 2>/dev/null) || _part=""
    if [ -z "$_part" ]; then
      _results="${_results}${_idx} failed transport"$'\n'
      continue
    fi
    # The body goes through `head -c <byte_size + 1>`, so no more than one
    # byte past the declared size ever reaches the disk, whatever curl's
    # version: before curl 8.4.0, --max-filesize does nothing for a body whose
    # length is not announced (chunked). The extra byte is how an over-long
    # body is told from an exact one. -w writes the status to curl's stderr
    # (%{stderr}), captured in its own file because stdout is the body; -s
    # without -S keeps curl's error text out of that file. A 0-byte entry
    # still gets --max-filesize 1, so no entry runs uncapped.
    if [ -z "$_proto" ]; then
      _code=000; _rc=6
    else
      _codef=$(mktemp "$_tdir/.code.XXXXXX" 2>/dev/null) || _codef=""
      if [ -z "$_codef" ]; then
        _code=000; _rc=6
      else
        printf 'Authorization: Bearer %s\n' "$_tok" | curl -q -s --globoff --proto "$_proto" \
          --max-time "$_left" --max-filesize "$(( _size > 0 ? _size : 1 ))" -A "$_ua" -H @- \
          -w '%{stderr}%{http_code}' -o - "$_api$_path" 2> "$_codef" \
          | head -c "$(( _size + 1 ))" > "$_part" 2>/dev/null
        _rc=${PIPESTATUS[1]}
        _code=$(cat "$_codef" 2>/dev/null)
        rm -f "$_codef" 2>/dev/null
      fi
    fi
    # The status decides first, so a 500 whose error body is longer than the
    # file is http_500 rather than size_mismatch (curl's --max-filesize trips
    # on the error body's Content-Length too). Within a 200, a body past
    # byte_size is size_mismatch however curl stopped (exit 63 is its own cap,
    # 23 the write error once head has closed the pipe); then 28 is the
    # per-request limit, which is whatever was left of the budget.
    _reason=""
    case "$_code" in
      200)
        _got=$(wc -c < "$_part" 2>/dev/null | tr -d ' ')
        case "$_got" in '' | *[!0-9]*) _got=0 ;; esac
        if [ "$_rc" -eq 63 ] || [ "$_got" -gt "$_size" ]; then
          _reason=size_mismatch
        elif [ "$_rc" -eq 28 ]; then
          _reason=time_budget
        elif [ "$_rc" -ne 0 ]; then
          _reason=transport
        elif [ "$_got" != "$_size" ]; then
          _reason=size_mismatch
        else
          _actual=$(attachment_sha256 "$_part")
          # No hash tool at all fails closed: an unverified file is never kept.
          [ -n "$_actual" ] && [ "$_actual" = "$_sha" ] || _reason=sha256_mismatch
        fi
        ;;
      [1-9][0-9][0-9]) _reason="http_$_code" ;;
      *)
        if [ "$_rc" -eq 28 ]; then _reason=time_budget; else _reason=transport; fi
        ;;
    esac
    if [ -z "$_reason" ] && mv -f "$_part" "$_tdir/$_local" 2>/dev/null; then
      _results="${_results}${_idx} downloaded -"$'\n'
    else
      rm -f "$_part" 2>/dev/null
      _results="${_results}${_idx} failed ${_reason:-transport}"$'\n'
    fi
  done <<EOF_PLAN
$(printf '%s' "$_plan" | jq -r 'to_entries[] | select(.value.status == "pending")
  | [(.key | tostring), .value.download_path, (.value.byte_size | floor | tostring),
     (.value.sha256 | if type == "string" and test("\\A[0-9a-f]{64}\\z") then . else "-" end),
     .value.local_file] | @tsv' 2>/dev/null)
EOF_PLAN

  # The manifest, LAST: staged in the task directory and renamed into place,
  # so its presence means every entry is settled. Compact, key order fixed by
  # the contract, one trailing LF, no timestamp of its own, no URL, no token.
  _tmeta=$(printf '%s' "$_task" | jq -c '{
      id: (.id | if type == "number" then . else null end),
      identifier: (.identifier | if type == "string" then . else null end)}' 2>/dev/null)
  [ -n "$_tmeta" ] || _tmeta='{"id":null,"identifier":null}'
  _tmp=$(mktemp "$_tdir/.manifest.XXXXXX" 2>/dev/null) || _tmp=""
  if [ -z "$_tmp" ]; then
    printf 'stride: attachments %s: could not stage manifest.json\n' "$_stem" >&2
    return 0
  fi
  if printf '%s' "$_plan" | jq -c \
      --arg results "$_results" --argjson task "$_tmeta" --argjson budget "$_budget" \
      --argjson file_bytes "$ATTACHMENT_FILE_BYTES" --argjson max_files "$ATTACHMENT_MAX_FILES" \
      --argjson total_bytes "$ATTACHMENT_TOTAL_BYTES" '
      ($results | split("\n") | map(select(length > 0) | split(" ")
        | {key: .[0], value: {status: .[1], reason: (if .[2] == "-" then null else .[2] end)}})
        | from_entries) as $r
      | {manifest_version: 1, task: $task,
         caps: {file_bytes: $file_bytes, files: $max_files, total_bytes: $total_bytes,
                budget_seconds: $budget},
         attachments: (to_entries | map(
           (.key | tostring) as $k
           | .value
           | if .status != "pending" then .
             elif $r[$k] then . + $r[$k]
             else . + {status: "failed", reason: "transport"} end
           | if .status == "downloaded" then . else .local_file = null end))}' \
      > "$_tmp" 2>/dev/null && mv -f "$_tmp" "$_tdir/manifest.json" 2>/dev/null; then
    :
  else
    rm -f "$_tmp" 2>/dev/null
    printf 'stride: attachments %s: could not write manifest.json\n' "$_stem" >&2
    return 0
  fi
  _ok=$(jq '[.attachments[] | select(.status == "downloaded")] | length' "$_tdir/manifest.json" 2>/dev/null)
  _skip=$(jq '[.attachments[] | select(.status == "skipped")] | length' "$_tdir/manifest.json" 2>/dev/null)
  _fail=$(jq '[.attachments[] | select(.status == "failed")] | length' "$_tdir/manifest.json" 2>/dev/null)
  printf 'stride: attachments %s: %s downloaded, %s skipped, %s failed\n' \
    "$_stem" "${_ok:-0}" "${_skip:-0}" "${_fail:-0}" >&2
  return 0
}

# Self-gates on before_review - the hook that fires AFTER a /complete succeeds
# (the routing below maps post + /api/tasks/:id/complete to it). Never writes
# to stdout: Gemini CLI parses this script's stdout as one JSON document, so
# every diagnostic here goes to stderr.
record_loop_state_for_completion() {
  local _payload _ident _needs _sid _json

  [ "${HOOK_NAME:-}" = "before_review" ] || return 0
  [ "${HAS_JQ:-false}" = "true" ] || return 0

  # Reuse the RESPONSE_PAYLOAD already computed for THIS call. The Claude Code
  # original needs its own unwrap_tool_response here because its
  # extract_response_payload is canonical-file-first (D118) and can resolve a
  # PREVIOUS call's snapshot; this port's helper reads .tool_response off
  # $INPUT and nothing else, so it is inherently scoped to this call and there
  # is no staleness to guard against.
  #
  # That is also why the original's Tier 2 snapshot-recovery branch is
  # deliberately NOT ported: this port has neither .stride/.last-api-response
  # .json nor STRIDE_ROUTE_TASK_ID, so there is nothing to fall back to. A
  # harness-truncated success simply records nothing, which is the safe
  # direction and the same miss the original accepts everywhere else.
  _payload="${RESPONSE_PAYLOAD:-}"

  if ! loop_state_payload_ok "$_payload"; then
    # A 422 legitimately records nothing, and announcing every failed
    # completion would be noise. An UNPARSABLE body is the different case: the
    # completion may well have succeeded server-side and the evidence is simply
    # lost, which is indistinguishable from "nothing to record" unless said.
    # `jq empty`, not `jq -e .`: -e sets its exit status from the VALUE, so a
    # body of `false` or `null` - both perfectly well-formed - would be
    # announced as unparsable, and an ABSENT body would exit 4 on no input and
    # be announced as a parse failure that never happened. `empty` fails only
    # on a genuine parse error, and the -n guard keeps "no body at all" out of
    # a channel that claims a body failed to parse.
    if [ -z "$_payload" ]; then
      # W2183 OVERTURNS THE SILENCE HERE, and the comment above is what makes
      # the case: the 422 excuse does not cover an ABSENT body. A 422 arrives
      # WITH a well-formed body that parses and correctly records nothing --
      # nothing failed, so nothing is said. An absent body is the opposite: the
      # response never reached this hook at all, so the completion may well have
      # landed server-side while no loop state exists, and the AfterAgent gate
      # reads a missing file as "nothing to gate on" and PERMITS. A session can
      # then end with claimable work still in Ready and not one line saying why.
      #
      # Order matters: this arm sits BEFORE the `jq empty` test for the reason
      # that test's own comment gives -- `jq empty` exits 4 on no input, so an
      # absent body would otherwise be announced as a parse failure that never
      # happened. Absent and empty are treated alike because they are the same
      # condition reached by two routes, and the operator's fix is identical.
      #
      # The advice is deliberately "let the body print": this port has no tee
      # shape of its own to name, and inventing one would be worse than silence.
      printf 'stride-hook: no completion response reached this hook; no loop state recorded, so the AfterAgent gate cannot tell this task was completed -- send the completion curl with its stdout intact\n' >&2
    elif ! printf '%s' "$_payload" | jq empty > /dev/null 2>&1; then
      printf 'stride-hook: completion response was unparsable; no loop state recorded\n' >&2
    fi
    return 0
  fi

  _ident=$(printf '%s' "$_payload" | jq -r '.data.identifier' 2>/dev/null || echo "")
  _needs=$(printf '%s' "$_payload" | jq -r '.data.needs_review' 2>/dev/null || echo "")
  loop_state_safe "$_ident" || return 0
  case "$_needs" in true|false) ;; *) return 0 ;; esac

  # The session id is the ONLY field read out of $INPUT, which also carries the
  # Bearer token in .tool_input.command - never widen this read. GEMINI_ is
  # preferred over CLAUDE_ for the same reason PROJECT_DIR prefers
  # GEMINI_PROJECT_DIR at the top of this file; the twin uses the same order.
  _sid=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
  [ -n "$_sid" ] || _sid="${GEMINI_SESSION_ID:-}"
  [ -n "$_sid" ] || _sid="${CLAUDE_SESSION_ID:-}"
  loop_state_safe "$_sid" || _sid="unknown"

  # --argjson (never --arg) for needs_review: it is already proven to be
  # exactly `true` or `false` above, and --arg would stringify it, which is
  # precisely the cross-half type divergence this task exists to avoid.
  _json=$(jq -nc \
    --arg ident "$_ident" \
    --argjson needs "$_needs" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg sid "$_sid" \
    '{identifier: $ident, needs_review: $needs, completed_at: $ts, session_id: $sid}' \
    2>/dev/null) || return 0
  [ -n "$_json" ] || return 0

  write_loop_state "$_json"
  return 0
}

# Print escaped KEY='value' assignment lines for the env object of the named
# hook entry in the payload. Keys must be valid shell identifiers — anything
# else is dropped, because an unquoted key left of `=` in a sourced file is
# the real injection vector. HOOK_NAME is excluded: the executor routes on
# its own script-global and a cached HOOK_NAME line would misroute every
# later invocation. TASK_BASE_REF is excluded: it is a client-only diff
# anchor owned by the claim branch (W1086). Values go through jq's @sh so
# embedded quotes and newlines cannot escape the single-quoting.
extract_hook_env() {
  local _payload="$1" _name="$2"
  [ "$HAS_JQ" = "true" ] || return 0
  [ -n "$_payload" ] || return 0
  printf '%s' "$_payload" | jq -r --arg name "$_name" '
    (
      (.hooks // []) + (if (has("hook") and (.hook | type == "object")) then [.hook] else [] end)
      | map(select(type == "object" and .name == $name))
      | (first // {})
      | (.env // {})
    )
    | if type == "object" then . else {} end
    | to_entries[]
    | select(.key | test("^[A-Za-z_][A-Za-z0-9_]*$"))
    | select(.key != "HOOK_NAME" and .key != "TASK_BASE_REF")
    | .key + "=" + (.value | tostring | @sh)
  ' 2>/dev/null || true
}

# Export assignment lines into the running shell and append them to the env
# cache (best-effort) so the values survive for follow-up agent commands.
# Every line is KEY='escaped-value' (see extract_hook_env / sq_escape), so
# the eval is confined to plain assignments. Appending — not rewriting — is
# deliberate: sourcing is last-wins, and a line-based rewrite would corrupt
# values with embedded newlines. The next claim truncates the cache anyway,
# bounding growth. Never echoes values to stdout/stderr (they may contain
# task descriptions or other sensitive content).
apply_env_lines() {
  local _lines="$1"
  [ -n "$_lines" ] || return 0
  set -a
  eval "$_lines" 2>/dev/null || true
  set +a
  printf '%s\n' "$_lines" >> "$ENV_CACHE" 2>/dev/null || true
}

# after_goal env: export what the server supplied, default every documented
# GOAL_* key it omitted to an empty string (defined-but-empty, never an
# error), and fall back to the completed task's parent_id from the same
# response payload when GOAL_ID itself is missing or empty. The fallback is
# response-local — the executor still never queries the API for goal state.
export_after_goal_env() {
  local _payload="$1"
  local _lines _supplied _key _parent
  _lines=$(extract_hook_env "$_payload" "after_goal")

  # Which keys did the server actually supply? Asked of jq directly (one key
  # name per line) rather than grepped out of the assignment text — a value
  # with an embedded newline could otherwise masquerade as a KEY= line and
  # suppress an omitted key's empty-string default.
  _supplied=""
  if [ "$HAS_JQ" = "true" ] && [ -n "$_payload" ]; then
    _supplied=$(printf '%s' "$_payload" | jq -r '
      (
        (.hooks // []) + (if (has("hook") and (.hook | type == "object")) then [.hook] else [] end)
        | map(select(type == "object" and .name == "after_goal"))
        | (first // {})
        | (.env // {})
      )
      | if type == "object" then . else {} end
      | keys[]
    ' 2>/dev/null || true)
  fi

  for _key in GOAL_ID GOAL_IDENTIFIER GOAL_TITLE GOAL_DESCRIPTION; do
    if ! printf '%s\n' "$_supplied" | grep -qx "$_key"; then
      _lines="${_lines}
${_key}=''"
    fi
  done

  apply_env_lines "$_lines"

  # Parent-id fallback: the server built the after_goal env from the completed
  # child task and omitted GOAL_ID (or sent it empty). The parent id in the
  # same response's data object IS the goal id.
  if [ -z "${GOAL_ID:-}" ] && [ "$HAS_JQ" = "true" ] && [ -n "$_payload" ]; then
    _parent=$(printf '%s' "$_payload" | jq -r '.data.parent_id // .parent_id // empty' 2>/dev/null || true)
    if [ -n "$_parent" ] && [ "$_parent" != "null" ]; then
      apply_env_lines "GOAL_ID=$(sq_escape "$_parent")"
    fi
  fi
}

# =========================================================================
# The stdout-preservation guard (W2183)
# =========================================================================
#
# WHY, IN THIS PORT'S TERMS. `extract_response_payload` above reads
# `.tool_response` and NOTHING ELSE -- this port has no canonical response file
# and no route-id fallback, and says so in as many words. So the stdout of a
# `run_shell_command` call -- this runtime's tool, and the literal matcher the
# BeforeTool entry in hooks.json carries -- is the ONE channel a Stride response
# can arrive on. A command that
# takes it anywhere else leaves the recorder with nothing: no loop state is
# written, the AfterAgent gate cannot see that the task was completed, and
# `changed_files` lands empty. Every part of that is silent.
#
# SO THE RULE HERE IS THE STRICT ONE: every hiding form is refused, with no
# exemption for any target. A sibling port (stride-copilot) is FILE-FIRST and
# therefore permits `--output <its canonical response file>`, and allows a
# transformer after a `tee` into that file. NEITHER EXEMPTION TRANSFERS HERE,
# because there is no such file to read back -- do not import that reasoning,
# and do not copy that port's messages, which name a path this port never
# touches.
#
# (W2524) The one -o this guard allows is unrelated to that reasoning: a GET of
# a task ATTACHMENT, /api/tasks/<id>/attachments/<id>, into this project's
# .stride/attachments/<dir>/<file> (gemini_guard_attachment_exempt). An
# attachment body is not a Stride response the recorder reads, and the
# exemption exists for an operator's manual re-fetch only: the claim hook
# downloads attachments itself, never through this guard.
#
# SCOPE. The routing case further down routes exactly three endpoints:
# /api/tasks/claim, /api/tasks/<id>/complete and /api/tasks/<id>/mark_reviewed.
# All three carry the literal `/api/tasks/`, which is the prefilter. The
# creation POST to `$STRIDE_API_URL/api/tasks` -- no trailing slash, and written
# unquoted in skills/stride-enriching-tasks -- is DELIBERATELY out of scope: it
# is not routed and not recorded, so hiding its response costs this port
# nothing, while widening the prefilter to a bare `/api/tasks` would refuse the
# enrichment calls our own skills document, for no benefit.
#
# THE CONTRACT, stated as honestly as it is known. docs/HOOK_RESEARCH.md
# documents TWO equivalent forms for `BeforeTool`: exit 2 with the message on
# stderr (its "preferred system-block form"), and a stdout document carrying
# `{"decision":"deny",...}`. This handler emits BOTH, because neither has been
# measured against a live Gemini CLI from this repository -- emitting both is
# the hedge, not a claim that either is settled. The token is `deny`; `block`
# belongs to other runtimes in this fleet and would mean no refusal at all here.
# Note the stop gate's own R1 caveat is about `AfterAgent`, a DIFFERENT event,
# and is not restated as though it governed this one.
#
# CROSS-PORT AGREEMENT (W2184, which drove the three hardened guards over one
# corpus rather than trusting three green suites). The three refuse and permit
# the same set of shapes, with SIX deliberate exceptions -- all of them the
# file-first exemption named two paragraphs up, and its mirror: `tee -a` onto
# that canonical file is refused in stride-copilot, because appending corrupts
# the single JSON document its Tier 1 parses, and permitted here, because `tee -a`
# still passes the body through on the stdout this port reads. Those six are
# contract differences, not drift, and stride-codex's guard header carries the
# same record. Everything else agrees on both sides of the scan ceiling, which
# is why the whole-mode scope cut below is written the way the siblings write it.
#
# The command text carries a Bearer token on every call this guard matches, so
# nothing derived from it may reach a message, a log or a file: all four
# messages are fixed literals selected by a `case`.

GEMINI_GUARD_MAX_SCAN=65536

# awk does the quote blanking, the pairing and the redirect walk, so without it
# the guard cannot judge anything. The port's own convention elsewhere is to name
# a missing dependency and take the safe direction (HAS_JQ below, and the stop
# gate's explicit "curl is not available" permit), so this is named rather than
# left to a fallback that would return its input verbatim and quietly permit.
#
# It fails CLOSED: on a Stride call that matches the cheap prefilter, no awk
# means the guard refuses rather than guesses. A refusal is loud and recoverable;
# a guess in the other direction loses the task silently, which is the whole
# failure this guard exists to prevent.
GEMINI_GUARD_HAS_AWK=false
command -v awk > /dev/null 2>&1 && GEMINI_GUARD_HAS_AWK=true

# Join backslash-newline continuations so a command split across lines is read
# as the one command it is. The documented completion call is multi-line.
gemini_guard_join_continuations() {
  printf '%s' "$1" | awk 'BEGIN{RS="\036"} {gsub(/\\\n/, " "); printf "%s", $0}'
}

# Blank quoted spans to spaces, carrying quote state ACROSS NEWLINES.
#
# The whole text is one record deliberately: this port's documented completion
# payload is a multi-line `jq -n` program, and a per-line pass would reset the
# quote state at every newline and read that payload as live shell syntax --
# refusing an ordinary completion whose review prose contains a `>`. A newline
# INSIDE quotes is payload; outside, it is a separator and is preserved as one.
#
# Backslash escapes follow the shell's asymmetry: inside double quotes `\"` does
# not close the run; inside single quotes a backslash is literal.
#
# Length-preserving by construction -- one byte out per byte in -- so the caller
# may cut this view and the raw view at shared offsets. LC_ALL=C on both sides
# keeps awk and bash counting the same units, which matters because the
# documented payload carries em dashes.
gemini_guard_blank() {
  LC_ALL=C printf '%s' "$1" | LC_ALL=C awk '
    BEGIN { RS = "\036" }
    {
      n = length($0); out = ""; q = ""; i = 1
      while (i <= n) {
        c = substr($0, i, 1)
        if (q == "") {
          if (c == "\\") { out = out " "; if (i + 1 <= n) { out = out " "; i += 2 } else { i += 1 }; continue }
          if (c == "\"" || c == "'"'"'") { q = c; out = out " "; i += 1; continue }
          out = out c; i += 1; continue
        }
        if (q == "\"" && c == "\\") { out = out " "; if (i + 1 <= n) { out = out " "; i += 2 } else { i += 1 }; continue }
        if (c == q) { q = ""; out = out " "; i += 1; continue }
        out = out " "; i += 1
      }
      printf "%s", out
    }
  ' 2>/dev/null || printf '%s' "$1"
}

# The command word of a pipeline stage: the first word that is not a leading
# assignment, a wrapper, or a compound-command keyword.
#
# The keyword skips are not decoration. `RESP=$(curl ... -o x)` fuses the
# assignment and the command into one word; `( curl ... > f )` and
# `if curl ... -o f; then ...; fi` put `(` or `if` in command position. Each made
# the stage's command word something other than curl, which skipped the segment
# entirely -- the redirect rule included. The caller additionally neutralises
# the grouping characters.
gemini_guard_cmd_word() {
  local _w
  for _w in $1; do
    case "$_w" in
      '') continue ;;
      *=*) continue ;;
      env|command|builtin|exec|nohup|time) continue ;;
      if|then|elif|else|fi|while|until|do|done|'!') continue ;;
      *) printf '%s' "${_w##*/}"; return 0 ;;
    esac
  done
  return 0
}

# Is this text a Stride API call at all? Judged on RAW text, never the blanked
# copy: the documented calls QUOTE their URL, so asking this of the blanked view
# answers "no" for every real Stride call and the guard would permit exactly
# what it exists to refuse.
gemini_guard_is_stride_call() {
  case "$1" in
    *"/api/tasks/"*) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *curl*) return 0 ;;
  esac
  return 1
}

# Stdout redirects. Emits `redirect` or nothing.
#
#   refused  : >  >>  1>  1>>  >|  &>  &>>  >&2
#   permitted: 2>  2>>  2>&1   -- stderr only, so the body still prints, and
#              refusing one would be a false positive
#
# No target exemption and so no `append` kind: unlike a file-first sibling,
# this port has no file to write to in the first place.
gemini_guard_redirect_kind() {
  printf '%s' "$1" | LC_ALL=C awk '
    {
      n = length($0)
      for (i = 1; i <= n; i++) {
        if (substr($0, i, 1) != ">") continue
        # The stderr-only exemption is tested FIRST, before the `>&2` rule. The
        # other order refuses `2>&2` -- a stderr-to-stderr redirect that leaves
        # the body on stdout, so refusing it is exactly the false positive the
        # pitfall names. `>&2` with no fd word before it still moves stdout TO
        # stderr and is still refused.
        prev = (i > 1) ? substr($0, i - 1, 1) : " "
        if (prev == ">") continue
        if (prev == "2") {
          before = (i > 2) ? substr($0, i - 2, 1) : " "
          if (before ~ /[ \t]/ || i == 2) continue
        }
        if (substr($0, i, 3) == ">&2") { print "redirect"; exit }
        if (prev == "&") { print "redirect"; exit }
        print "redirect"; exit
      }
    }
  ' 2>/dev/null
}

# A `>` the shell never reads as an operator, neutralised so no rule reads it as
# one either. `--data-urlencode n=a\>` carries a BACKSLASH-ESCAPED `>`: the shell
# passes it to curl as a literal character and redirects nothing. Both walks over
# the operator view used to take it for syntax, and the two failures point in
# opposite directions:
#
#   * the scope pass blanks the word AFTER a redirect operator, so an escaped `>`
#     standing just before the URL blanked the URL out of the scope view. With
#     the only endpoint gone the segment fell out of scope and the call was
#     PERMITTED -- on the one branch this port builds to over-refuse
#   * the redirect rule read the same character as a stdout redirect and REFUSED
#     a command that redirects nothing at all, which is the false positive that
#     teaches an agent to route around the guard.
#
# Both are fixed here rather than in either walk, because one neutralisation
# upstream cannot disagree with itself the way two independent escape tests can.
# ODD/EVEN MATTERS: `\>` is a literal `>`, but `\\>` is an escaped BACKSLASH
# followed by a real operator, so only an odd run of backslashes escapes the `>`.
# Counting the run is the whole difference between this and a `tr`.
#
# Length-preserving like every other pass over this view: the escaping backslash
# and the `>` become two spaces, so the raw/blanked pairing offsets still line up.
# Quote state is untouched -- a backslash is only ever blanked when a `>` follows
# it, never when a quote does.
#
# Fails OPEN to the unchanged text if awk is unavailable, matching the scope
# helper beside it: that restores the previous behaviour rather than inventing a
# new failure mode on a host the guard already could not fully serve.
gemini_guard_blank_escaped_gt() {
  GEMINI_EGT="$1" LC_ALL=C awk '
    BEGIN {
      s = ENVIRON["GEMINI_EGT"]; n = length(s); out = s; i = 1
      while (i <= n) {
        if (substr(s, i, 1) != "\\") { i++; continue }
        k = 0
        while (i + k <= n && substr(s, i + k, 1) == "\\") k++
        if ((k % 2) == 1 && i + k <= n && substr(s, i + k, 1) == ">") {
          out = substr(out, 1, i + k - 2) "  " substr(out, i + k + 1)
        }
        i = i + k
      }
      printf "%s", out
    }
  ' 2>/dev/null || printf '%s' "$1"
}

# Raw text with every REDIRECT TARGET blanked out, for the scope test only.
#
# Without this, `curl https://example.test/x > /tmp/api/tasks/9/complete` is
# refused: the segment carries curl and a redirect, and `/api/tasks/` appears --
# but only inside the redirect's own target, which says nothing about the
# endpoint being called. The endpoint has to appear somewhere a request could
# actually go.
#
# Target spans are located in the BLANKED view (so a path inside a quoted
# payload is not mistaken for one) and blanked in the RAW view at the same
# offsets, which stays sound because every substitution is a space for a byte.
gemini_guard_scope_text() {
  GEMINI_SC_RAW="$1" GEMINI_SC_BL="$2" LC_ALL=C awk '
    BEGIN {
      raw = ENVIRON["GEMINI_SC_RAW"]; bl = ENVIRON["GEMINI_SC_BL"]
      n = length(bl); out = raw
      i = 1
      while (i <= n) {
        if (substr(bl, i, 1) != ">") { i++; continue }
        j = i + 1
        # step over the rest of the operator
        while (j <= n && (substr(bl, j, 1) == ">" || substr(bl, j, 1) == "|" || substr(bl, j, 1) == "&")) j++
        # step over separating blanks
        while (j <= n && substr(bl, j, 1) ~ /[ \t]/) j++
        # blank the target word in the RAW copy
        while (j <= n && substr(bl, j, 1) !~ /[ \t\n;|&]/) {
          out = substr(out, 1, j - 1) " " substr(out, j + 1)
          j++
        }
        i = j
      }
      printf "%s", out
    }
  ' 2>/dev/null || printf '%s' "$1"
}

# Cut both views into segments at ONE set of offsets and emit them paired as
# `<raw>\037<blanked>\036`.
#
# Boundaries are located in the BLANKED view so a separator inside a quoted
# payload cannot split a command; the same offsets then cut the raw view, which
# is sound only because blanking is length-preserving (the caller checks).
#
# Both strings reach awk through the ENVIRONMENT, never `awk -v`, which
# processes backslash escapes in its value -- a command containing `\n` would
# arrive transformed and the offsets would stop lining up.
gemini_guard_split_pairs() {
  GEMINI_SP_RAW="$1" GEMINI_SP_BL="$2" LC_ALL=C awk '
    function emit(s, e,   r, b) {
      if (e < s) return
      r = substr(raw, s, e - s + 1)
      b = substr(bl,  s, e - s + 1)
      printf "%s\037%s\036", r, b
    }
    BEGIN {
      raw = ENVIRON["GEMINI_SP_RAW"]; bl = ENVIRON["GEMINI_SP_BL"]
      n = length(bl); start = 1; i = 1
      while (i <= n) {
        c  = substr(bl, i, 1)
        c2 = substr(bl, i, 2)
        if (c2 == "&&" || c2 == "||") { emit(start, i - 1); i += 2; start = i; continue }
        if (c == ";" || c == "\n")    { emit(start, i - 1); i += 1; start = i; continue }
        i++
      }
      emit(start, n)
    }
  ' 2>/dev/null
}

# (W2524) The ONE exemption from the -o/--output refusal: a GET of a task
# attachment, /api/tasks/<id>/attachments/<id>, whose -o/--output target is an
# absolute path under this project's .stride/attachments/<dir>/<file>. Ported
# from stride's stride_guard_attachment_exempt (W2522) and DELIBERATELY
# NARROWER than it (W2524 exploratory findings): this port also refuses
# -w/--write-out, an @file header value, manifest.json in any letter case, a
# target that is itself a symlink, and a tree with no .gitignore yet. Never
# re-sync it to stride's rules without keeping those five refusals. The
# contract is stride's docs/porting-attachments.md, "Curl-guard exemption". It
# exists for an operator's manual re-fetch only: the claim hook downloads
# attachments itself, and the agent rules forbid an agent from running curl -o
# at all. An attachment body is not a Stride response the recorder reads, so
# sending it to a file hides nothing this guard protects.
#
# Deliberately narrow, and judged on the WHOLE command rather than a segment,
# so nothing else can ride along with it:
#   * one simple command and nothing else: no pipe, redirect, `;`, `&`, `(`,
#     `)`, newline, backtick or command substitution anywhere (even inside
#     double quotes), no unquoted glob or brace character (`* ? [ ] { } ~`),
#     no unquoted `$` (a $NAME base must be double-quoted, so the shell
#     cannot split its value into extra words), no `$` inside double quotes
#     except a plain $NAME or ${NAME} (a quoted "$@", "${a[@]}" or "$*" can
#     expand to zero or several words and re-pair the words after it), and no
#     empty word, so every word judged here is exactly one word the shell will
#     pass. The flag, pipe and redirect rules therefore have nothing left to
#     judge, so returning early cannot hide a pipe or a redirect;
#   * the command word is curl itself, with no wrapper or assignment before it;
#   * every option is on an ALLOWLIST, so an option this code does not know
#     (--location-trusted, --proxy, -K, --next, -v, ...) means no exemption
#     rather than a pass. Flags: -s -S -f -g, --silent --show-error --fail
#     --fail-with-body --globoff --no-progress-meter --compressed
#     --create-dirs. Options with a value: -o/--output, -H/--header (never
#     an @file value), -A/--user-agent, -m/--max-time, --connect-timeout,
#     --retry, --max-filesize, --proto, and -X/--request only as GET.
#     -w/--write-out is NOT allowed: its %output{} directive writes a second
#     file anywhere (W2524 exploratory finding);
#   * exactly one -o/--output, and exactly one other word: the attachments
#     path with no query, fragment or percent-encoding, after a scheme and host
#     (an optional port) or a double-quoted $NAME / ${NAME} base; no other word mentions /api/;
#   * the target is an ABSOLUTE literal path: the project root as this hook
#     sees it, then .stride/attachments/<dir>/<file>, <dir> matching
#     [A-Za-z0-9_-]{1,64} and <file> [A-Za-z0-9_-][A-Za-z0-9._-]{0,163}, not
#     manifest.json in any letter case (APFS and NTFS fold case). A $NAME prefix is refused: the guard cannot know what the
#     shell running the command will expand it to (an unset $GEMINI_PROJECT_DIR
#     writes to /.stride/...), so it cannot say where the file lands;
#   * neither .stride, .stride/attachments, <dir> nor the <file> itself is a
#     symlink, and .stride/attachments/.gitignore already exists as a regular
#     file, so a re-fetch never creates a tree that git would commit.
# Anything that misses a single rule is judged by gemini_guard_reason exactly
# as before. Prints nothing; returns 0 only for an exempt command.
# stride-hook.ps1's Test-GeminiGuardAttachmentExempt is its twin, rule for rule.
#
# The body is a SUBSHELL: it changes IFS and noglob, and its caller runs the
# whole scan under `set -f`, so restoring either by hand on every return path
# would turn globbing back ON for the rest of the guard.
gemini_guard_attachment_exempt() (
  local _cmd="$1" _words _w _expect="" _outs=0 _target="" _api=0 _pos=0 _url_ok=0
  local _root _rest _dir _file _cluster _ch _first=1 _oldifs="$IFS"
  [ "${#_cmd}" -le 4000 ] || return 1
  # Tokenise quote-aware. Exit status 1 means a shape this exemption never
  # admits (an operator, a substitution, a glob, an unterminated quote).
  _words=$(GEMINI_GX="$_cmd" LC_ALL=C awk '
    BEGIN {
      s = ENVIRON["GEMINI_GX"]; n = length(s); w = ""; have = 0; q = ""; bad = 0
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\n" || c == "\r" || c == "`") { bad = 1; break }
        if (q == "s") { if (c == "\047") q = ""; else w = w c; continue }
        if (q == "d") {
          if (c == "\"") { q = ""; continue }
          if (c == "\\" && i < n) { d = substr(s, i + 1, 1)
            if (d == "\"" || d == "\\" || d == "$") { w = w d; i++; continue } }
          # Inside double quotes only a plain $NAME or ${NAME} is one word
          # for certain; "$@", "${a[@]}", "$*" and the rest are refused.
          if (c == "$" && substr(s, i + 1) !~ /^([A-Za-z_]|\{[A-Za-z_][A-Za-z0-9_]*\})/) { bad = 1; break }
          w = w c; continue
        }
        if (c == " " || c == "\t") {
          # An empty word ('' or "") is refused: the loop below could not
          # see it, and curl would treat it as a second URL.
          if (have && w == "") { bad = 1; break }
          if (have) { print w; w = ""; have = 0 }
          continue
        }
        have = 1
        if (c == "\047") { q = "s"; continue }
        if (c == "\"") { q = "d"; continue }
        if (c == "\\") { if (i < n) { w = w substr(s, i + 1, 1); i++ }; continue }
        # An unquoted $ is refused: the shell would split its expansion into
        # words this function never sees. A variable base must be quoted.
        if (index("|&;<>()*?[]{}~$", c) > 0) { bad = 1; break }
        w = w c
      }
      if (q != "") bad = 1
      if (have && w == "") bad = 1
      if (bad) exit 1
      if (have) print w
    }') || return 1
  _root=$(cd "${PROJECT_DIR:-.}" 2>/dev/null && pwd) || return 1
  IFS='
'
  set -f
  for _w in $_words; do
    IFS="$_oldifs"
    if [ "$_first" = "1" ]; then
      _first=0
      [ "$_w" = "curl" ] || return 1
      continue
    fi
    case "$_w" in */api/*) _api=$((_api + 1)) ;; esac
    if [ -n "$_expect" ]; then
      case "$_expect" in
        output) _target="$_w" ;;
        method) [ "$_w" = "GET" ] || return 1 ;;
        # curl reads -H @file as headers FROM that file; never allowed.
        header) case "$_w" in @*) return 1 ;; esac ;;
      esac
      _expect=""
      continue
    fi
    case "$_w" in
      --output) _outs=$((_outs + 1)); _expect=output ;;
      --output=*) _outs=$((_outs + 1)); _target="${_w#--output=}" ;;
      --request) _expect=method ;;
      --request=*) [ "${_w#--request=}" = "GET" ] || return 1 ;;
      --silent | --show-error | --fail | --fail-with-body | --globoff \
        | --no-progress-meter | --compressed | --create-dirs) : ;;
      --header) _expect=header ;;
      --header=@*) return 1 ;;
      --user-agent | --max-time | --connect-timeout \
        | --retry | --max-filesize | --proto) _expect=value ;;
      --header=* | --user-agent=* | --max-time=* | --connect-timeout=* \
        | --retry=* | --max-filesize=* | --proto=*) : ;;
      -) return 1 ;;
      -*)
        _cluster="${_w#-}"
        case "$_cluster" in -*) return 1 ;; esac
        while [ -n "$_cluster" ]; do
          _ch="${_cluster%"${_cluster#?}"}"
          _cluster="${_cluster#?}"
          case "$_ch" in
            s | S | f | g) : ;;
            o) _outs=$((_outs + 1))
               if [ -n "$_cluster" ]; then _target="$_cluster"; else _expect=output; fi
               break ;;
            X) if [ -n "$_cluster" ]; then
                 [ "$_cluster" = "GET" ] || return 1
               else _expect=method; fi
               break ;;
            # A value-taking short option consumes the rest of the cluster, or
            # the next word, so a value is never read as an option.
            H) case "$_cluster" in @*) return 1 ;; esac
               [ -n "$_cluster" ] || _expect=header
               break ;;
            A | m) [ -n "$_cluster" ] || _expect=value
               break ;;
            *) return 1 ;;
          esac
        done
        ;;
      *)
        _pos=$((_pos + 1))
        if printf '%s' "$_w" | grep -Eq '^(https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?|\$[A-Za-z_][A-Za-z0-9_]*|\$\{[A-Za-z_][A-Za-z0-9_]*\})/api/tasks/[0-9]{1,20}/attachments/[0-9]{1,20}$'; then
          _url_ok=1
        fi
        ;;
    esac
    IFS='
'
  done
  IFS="$_oldifs"
  [ "$_first" = "0" ] && [ -z "$_expect" ] || return 1
  [ "$_outs" -eq 1 ] && [ "$_api" -eq 1 ] && [ "$_pos" -eq 1 ] && [ "$_url_ok" = "1" ] || return 1
  case "$_target" in
    "$_root"/.stride/attachments/*) _rest="${_target#"$_root"/.stride/attachments/}" ;;
    *) return 1 ;;
  esac
  _dir="${_rest%%/*}"
  _file="${_rest#*/}"
  [ "$_dir" != "$_rest" ] || return 1
  printf '%s' "$_dir" | grep -Eq '^[A-Za-z0-9_-]{1,64}$' || return 1
  printf '%s' "$_file" | grep -Eq '^[A-Za-z0-9_-][A-Za-z0-9._-]{0,163}$' || return 1
  [ "$(printf '%s' "$_file" | tr 'A-Z' 'a-z')" != "manifest.json" ] || return 1
  [ ! -L "$_root/.stride" ] && [ ! -L "$_root/.stride/attachments" ] \
    && [ ! -L "$_root/.stride/attachments/$_dir" ] \
    && [ ! -L "$_root/.stride/attachments/$_dir/$_file" ] || return 1
  [ -f "$_root/.stride/attachments/.gitignore" ] \
    && [ ! -L "$_root/.stride/attachments/.gitignore" ] || return 1
  return 0
)

# The decider. Prints one of flag|remote|pipe|redirect, or nothing.
gemini_guard_reason() {
  local _raw="$1" _joined _scan _seg _seg_raw _pair _stage _rest _word _first _sawcurl _target _next
  local _whole=0

  gemini_guard_is_stride_call "$_raw" || return 0

  # No awk, no judgement. Fail CLOSED rather than let the blanking fallback
  # return its input verbatim and quietly permit -- see GEMINI_GUARD_HAS_AWK.
  #
  # Its OWN kind, not `flag`: reusing that one told the operator the command
  # "writes the Stride response to a file with -o/--output" when it may have done
  # no such thing, and offered a remedy that cannot clear the refusal. A refusal
  # an operator cannot act on is barely better than a silent permit.
  if [ "${GEMINI_GUARD_HAS_AWK:-false}" != "true" ]; then
    printf 'noawk'
    return 0
  fi

  # (W2524) The one sanctioned -o: a manual re-fetch of a task attachment into
  # .stride/attachments/. Judged on the RAW whole command (the blanked view
  # hides a quoted target), and only a single simple curl with no pipe or
  # redirect can pass, so the rules below have nothing left to judge when this
  # returns early. Printing nothing is the permit.
  if gemini_guard_attachment_exempt "$_raw"; then
    return 0
  fi

  _joined=$(gemini_guard_join_continuations "$_raw")

  if [ "$(LC_ALL=C printf '%s' "$_joined" | LC_ALL=C wc -c | tr -d ' ')" -le "$GEMINI_GUARD_MAX_SCAN" ]; then
    _scan=$(gemini_guard_blank "$_joined")
  else
    # Above the ceiling: stateless, AND judged as one unit. Segmenting unblanked
    # text shatters the command on the `;` inside its own payload and drops a
    # hiding flag into a fragment carrying no endpoint -- a false PERMIT, which
    # is the one direction this path must not fail in.
    _scan="$_joined"
    _whole=1
  fi

  # Neutralise the shell's grouping characters in the OPERATOR view only, each
  # replaced by a space so the substitution is length-preserving and the pairing
  # offsets still hold. Quoted spans are already blanked, so a `(` surviving
  # here is real syntax rather than payload. The raw view is untouched, so
  # endpoint scoping is unaffected.
  _scan=$(printf '%s' "$_scan" | LC_ALL=C tr '()`{}' '     ')

  # An escaped `>` goes the same way, but it needs a backslash-run count to tell
  # `\>` from `\\>`, so it cannot ride on the `tr` above. One pass, and both the
  # scope test and the redirect rule inherit it.
  _scan=$(gemini_guard_blank_escaped_gt "$_scan")

  # FAIL CLOSED on any length drift: scan the raw text as its own operator view.
  # Never pad or truncate to "repair" it -- that shifts the very offsets the
  # pairing depends on, turning a loud over-refusal into a silent bypass.
  if [ "$(LC_ALL=C printf '%s' "$_scan" | LC_ALL=C wc -c)" -ne "$(LC_ALL=C printf '%s' "$_joined" | LC_ALL=C wc -c)" ]; then
    _scan="$_joined"
    _whole=1
  fi

  local _segs
  if [ "$_whole" = "1" ]; then
    _segs=$(printf '%s\037%s\036' "$_joined" "$_scan")
  else
    _segs=$(gemini_guard_split_pairs "$_joined" "$_scan")
  fi

  while IFS= read -r -d $'\036' _pair; do
    _seg_raw="${_pair%%$'\037'*}"
    _seg="${_pair#*$'\037'}"
    [ -n "$_seg_raw" ] || continue
    # Raw half decides whether the segment is OURS; the blanked half decides
    # what it does. The scope text is the raw half with redirect targets blanked,
    # which is why `curl https://x/y > /tmp/api/tasks/9/complete` stays
    # permitted: the endpoint appears only where the output was going, never
    # where the request was.
    # ...but only on the SEGMENTED path. In whole mode `$_seg` is the unblanked
    # command, so a `>` inside a live payload reads as a real operator and the
    # token after it -- possibly the URL carrying the only endpoint -- is blanked
    # out of the scope view, which PERMITS the call on the one branch built to
    # over-refuse. Above the ceiling the raw text is the scope text. W2184: all
    # three hardened ports cut here, so an above-ceiling shape cannot be refused
    # in one and permitted in another.
    if [ "$_whole" = "1" ]; then
      case "$_seg_raw" in
        *"/api/tasks/"*) ;;
        *) continue ;;
      esac
    else
      case "$(gemini_guard_scope_text "$_seg_raw" "$_seg")" in
        *"/api/tasks/"*) ;;
        *) continue ;;
      esac
    fi

    _sawcurl=0
    _first=1
    _rest="$_seg"
    while [ -n "$_rest" ]; do
      case "$_rest" in
        *"|"*) _stage="${_rest%%|*}"; _rest="${_rest#*|}" ;;
        *)     _stage="$_rest";       _rest="" ;;
      esac
      _word=$(gemini_guard_cmd_word "$_stage")
      if [ "$_word" = "curl" ] || { [ "$_whole" = "1" ] && case " $_stage " in *" curl "*) true ;; *) false ;; esac; }; then
        _sawcurl=1
        # Rule 1 -- the response is written to a file instead of printed. No
        # target is acceptable here, because no file is read back.
        _next=""
        for _word in $_stage; do
          if [ -n "$_next" ]; then _next=""; printf 'flag'; return 0; fi
          case "$_word" in
            -O|--remote-name) printf 'remote'; return 0 ;;
            # --remote-name-all writes bodies to local files exactly as -O does.
            # It has to be named BEFORE the generic `--*) continue` arm, which is
            # what let it through: a long option is skipped wholesale there, so
            # the `-*O*` cluster arm below never sees it.
            --remote-name-all) printf 'remote'; return 0 ;;
            -o|--output)      _next=1 ;;
            --output=*)       printf 'flag';  return 0 ;;
            --)               break ;;
            --*)              continue ;;
            -*O*)             printf 'remote'; return 0 ;;
            -*o*)             printf 'flag';   return 0 ;;
          esac
        done
        [ -z "$_next" ] || { printf 'flag'; return 0; }
        _first=0
        continue
      fi
      # Rule 2 -- an ALLOWLIST, not a denylist. Anything downstream of curl
      # that is not `tee` consumes the body before the recorder sees it, and a
      # fixed list of known transformers silently permits every consumer nobody
      # thought to name (`python3 -m json.tool`, `xargs`, `cat`). `tee` is the
      # one pass-through, and -- unlike a file-first sibling -- it earns no
      # follow-on exemption here, because nothing reads the file it writes.
      if [ "$_first" = "0" ] && [ "$_sawcurl" = "1" ] && [ -n "$_word" ] && [ "$_word" != "tee" ]; then
        printf 'pipe'; return 0
      fi
      [ "$_first" = "1" ] && _first=0
    done

    [ "$_sawcurl" = "1" ] || continue
    _target=$(gemini_guard_redirect_kind "$_seg")
    [ -n "$_target" ] && { printf '%s' "$_target"; return 0; }
  done < <(printf '%s' "$_segs")

  return 0
}

# Emit the refusal and stop the call. Both documented BeforeTool forms, for the
# reason given in the header: the stdout document AND exit 2 with the same text
# on stderr.
gemini_guard_refuse() {
  local _kind="$1" _msg _doc
  case "$_kind" in
    flag)
      _msg='Refused by Gemini BeforeTool deny: this writes the Stride response to a file with -o/--output, so it never reaches stdout. This port reads a response off the tool stdout and nowhere else -- there is no canonical response file here to fall back to -- so hiding it means no loop state is recorded, the AfterAgent gate cannot see that the task was completed, and changed_files lands empty, none of it with an error. Let the body print.'
      ;;
    remote)
      _msg='Refused by Gemini BeforeTool deny: -O/--remote-name writes the Stride response to a local file named after the URL, so it never reaches stdout. This port reads a response off the tool stdout and nowhere else -- there is no canonical response file here to fall back to -- so hiding it means no loop state is recorded, the AfterAgent gate cannot see that the task was completed, and changed_files lands empty, none of it with an error. Let the body print.'
      ;;
    pipe)
      _msg='Refused by Gemini BeforeTool deny: piping the Stride response into another command consumes it before this hook reads it. This port reads a response off the tool stdout and nowhere else, so a consumer leaves nothing behind: no loop state is recorded, the AfterAgent gate cannot see that the task was completed, and changed_files lands empty, silently. tee is the only pipe permitted here, because it passes stdout through unchanged; every other command is refused rather than matched against a list of known ones. To inspect a field, let the body print and read it from the response you already have.'
      ;;
    redirect)
      _msg='Refused by Gemini BeforeTool deny: this redirect takes the Stride response off stdout. This port reads a response off the tool stdout and nowhere else, so redirecting it means no loop state is recorded, the AfterAgent gate cannot see that the task was completed, and changed_files lands empty, with no error anywhere. A stderr-only redirect (2>, 2>>, 2>&1) is fine and is NOT refused, because it leaves the body where this hook reads it. Let the body print.'
      ;;
    noawk)
      _msg='Refused by Gemini BeforeTool deny: this hook needs awk to tell a Stride API call that hides its response from one that does not, and awk is not available here, so it cannot judge this command either way. It refuses rather than guesses, because this port reads a response off a run_shell_command call'"'"'s stdout and nowhere else -- a wrong guess in the other direction records no loop state and loses the task silently. Install awk, or set the command aside until it is available; nothing about the command itself is wrong.'
      ;;
    *) return 0 ;;
  esac

  if [ "${HAS_JQ:-false}" = "true" ]; then
    _doc=$(printf '%s' "$_msg" | jq -Rsc '{decision:"deny",reason:.}' 2>/dev/null) || _doc=""
  fi
  if [ -z "${_doc:-}" ]; then
    _doc="{\"decision\":\"deny\",\"reason\":\"${_msg//\"/\\\"}\"}"
  fi
  printf '%s\n' "$_doc"
  printf '%s\n' "$_msg" >&2
  exit 2
}

# Exit early if no phase argument or no .stride.md. Placed AFTER the
# capture_changed_files, finalize_after_doing, run_stride_section,
# response_has_after_goal, and hook-env forwarding definitions so tests can
# source this script to use the functions in isolation.
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

# --- The stdout-preservation guard (W2183) --------------------------------
# BEFORE the routing case, deliberately: routing maps only `pre` + /complete to
# a hook name, so a claim or mark_reviewed curl exits at the `[ -n "$HOOK_NAME" ]`
# gate below and would escape a guard placed after it -- yet both of those
# responses are exactly what the recorder needs.
#
# STDOUT DISCIPLINE: Gemini parses this phase's stdout as one control document.
# The guard writes to fd 1 exactly once, inside the refusal branch, and exits
# immediately -- control never reaches routing, so it cannot collide with
# anything the `pre` path emits later. On the permit path it writes NOTHING.
if [ "$PHASE" = "pre" ]; then
  # Pathname expansion off for the whole scan: word splitting is wanted, but a
  # glob surviving quote blanking must not be expanded against whatever
  # directory the hook happens to run in. A guard's verdict may not depend on
  # the contents of a directory.
  set -f
  _gemini_guard_hit=$(gemini_guard_reason "$COMMAND")
  set +f
  [ -n "$_gemini_guard_hit" ] && gemini_guard_refuse "$_gemini_guard_hit"
fi

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

# (W2524) Assigned unconditionally, so a value inherited from the environment
# can never stand in for a proven claim and trigger the attachment download.
ATTACHMENT_TASK_JSON=""

if [ "$HOOK_NAME" = "before_doing" ]; then
  # (D142) This block refreshes IDENTITY only. TASK_BASE_REF is deliberately
  # NOT written here: the ## before_doing section has not run yet, and its
  # `git pull` moves HEAD — a base captured now would anchor the diff at the
  # PRE-pull commit and span another clone's pulled work (D132/W1678).
  # finalize_before_doing writes the base (and the dirty baseline) after the
  # section finishes.
  RESPONSE=""
  TASK_JSON=""
  INNER=""
  # (W2463) Set when TASK_JSON came from the persisted-output file (Shape 4).
  _task_from_persisted=""

  if [ "$HAS_JQ" = "true" ]; then
  RESPONSE=$(echo "$INPUT" | jq -r '.tool_response // ""' 2>/dev/null || echo "")

  if [ -n "$RESPONSE" ]; then
    # tool_response may come in several shapes depending on the host:
    #   1. {"stdout": "<api-json-string>", ...} — Bash-tool wrapper (Claude Code)
    #   2. "<api-json-string>" — legacy harnesses that stringify the body
    #   3. {"data": {...}} or {"id": ...} — raw API JSON object
    # then a persisted-output file fallback for oversized responses.

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

    # Shape 4: persisted-output file fallback (W1086). When the claim response
    # is large (e.g. a task already carrying a previous attempt's changed_files
    # snapshot), the host writes the tool output to a file and leaves only a
    # notice — "Full output saved to: <absolute path>" — in stdout. Recover the
    # API JSON by reading that file. The path is harness-controlled, so we
    # require it to be an existing regular file and parse it with jq only —
    # never source, eval, execute, or write to it.
    if [ -z "$TASK_JSON" ]; then
      _notice="$INNER"
      [ -z "$_notice" ] && _notice="$RESPONSE"
      if printf '%s' "$_notice" | grep -qi 'saved to'; then
        # Keep the path from its first "/" to end of the notice line so a path
        # containing spaces survives; tolerate the notice wrapping it in quotes.
        _persist_line=$(printf '%s\n' "$_notice" | grep -i 'saved to' | head -1)
        _persist_path="/${_persist_line#*/}"
        _persist_path="${_persist_path%\"}"
        if [ -n "$_persist_line" ] && [ -f "$_persist_path" ]; then
          _persist_json=$(cat "$_persist_path" 2>/dev/null || echo "")
          if [ -n "$_persist_json" ] && echo "$_persist_json" | jq -e '.data.id' > /dev/null 2>&1; then
            TASK_JSON=$(echo "$_persist_json" | jq -c '.data' 2>/dev/null)
          elif [ -n "$_persist_json" ] && echo "$_persist_json" | jq -e '.id' > /dev/null 2>&1; then
            TASK_JSON="$_persist_json"
          fi
          [ -n "$TASK_JSON" ] && _task_from_persisted=1
        fi
      fi
    fi
  fi

  fi

  if [ -n "$TASK_JSON" ]; then
    # (W2463) The claimed task file, written only when this response is proven
    # to belong to the claim this command made (see claim_identity_proven). A
    # persisted-output response must also match an identifier the command
    # named, because that file's path was read out of response text. The
    # identity check is this port's counterpart of stride's D226 gate.
    _task_file_need=""
    [ -n "$_task_from_persisted" ] && _task_file_need="require"
    if printf '%s' "$COMMAND" | claim_identity_proven "$TASK_JSON" "$_task_file_need"; then
      write_task_file "$TASK_JSON" > /dev/null
      # (W2524) The attachment list is read from this same proven object, and
      # only here: a claim whose response is not proven downloads nothing.
      ATTACHMENT_TASK_JSON="$TASK_JSON"
    else
      printf 'stride-hook: the claim response is not proven to be the task this claim asked for; not writing the task file\n' >&2
    fi

    # Identity lines ONLY — no TASK_BASE_REF / TASK_BASE_REF_TRUSTED
    # (finalize_before_doing writes those post-section); overwriting the whole
    # cache here also strips any inherited base/trust marker.
    # Every value goes through sq_escape: this file is dot-sourced below, and
    # the title is task-author text. Wrapping a raw value in '...' let a title
    # carrying a single quote close the quoting and run the rest of itself as
    # shell when the cache was sourced. Port of stride's claim-time writer.
    {
      echo "TASK_ID=$(sq_escape "$(echo "$TASK_JSON" | jq -r '.id // empty')")"
      echo "TASK_IDENTIFIER=$(sq_escape "$(echo "$TASK_JSON" | jq -r '.identifier // empty')")"
      echo "TASK_TITLE=$(sq_escape "$(echo "$TASK_JSON" | jq -r '.title // empty')")"
      echo "TASK_STATUS=$(sq_escape "$(echo "$TASK_JSON" | jq -r '.status // empty')")"
      echo "TASK_COMPLEXITY=$(sq_escape "$(echo "$TASK_JSON" | jq -r '.complexity // empty')")"
      echo "TASK_PRIORITY=$(sq_escape "$(echo "$TASK_JSON" | jq -r '.priority // empty')")"
    } > "$ENV_CACHE" 2>/dev/null || true
  elif [ -f "$ENV_CACHE" ]; then
    # (W1086/D142) No parseable response and no usable persisted file: keep the
    # existing TASK_ identity lines (a later completion can still recover
    # TASK_ID) but STRIP the inherited TASK_BASE_REF (and its trust marker) NOW
    # — even if this process dies before finalize_before_doing rewrites it, a
    # base from a previous task or session must never survive a claim.
    _preserved=$(grep -v -e '^TASK_BASE_REF=' -e '^TASK_BASE_REF_TRUSTED=' "$ENV_CACHE" 2>/dev/null || true)
    if [ -n "$_preserved" ]; then
      printf '%s\n' "$_preserved" > "$ENV_CACHE" 2>/dev/null || true
    else
      rm -f "$ENV_CACHE" 2>/dev/null || true
    fi
  fi

  # A claim always opens a new task window: clear the previous task's snapshot,
  # upload state (W1094 — a stale 2xx would suppress the before_review self-heal
  # retry), and dirty baseline unconditionally. The dirty baseline is re-recorded
  # by finalize_before_doing against the post-pull tree.
  rm -f "$PROJECT_DIR/.stride-changed-files.json" 2>/dev/null || true
  rm -f "$PROJECT_DIR/.stride-diff-upload-state" 2>/dev/null || true
  rm -f "$PROJECT_DIR/.stride-dirty-baseline" 2>/dev/null || true

  # (W2144) The completion record belongs to the task window too, and the clear
  # is UNCONDITIONAL - it runs on a failed claim, an empty-queue claim and an
  # unparsable claim body alike. The most common failed claim is against an
  # empty Ready queue, which is how essentially every session ends; a record
  # preserved there is byte-identical to one left by an agent that completed
  # and never claimed again, yet a gate must refuse in the second case and must
  # not in the first, and none of the four keys can tell them apart. That is
  # the same false gate this file exists to avoid, reached through the
  # failed-claim branch instead. An over-eager clear costs only a missed gate,
  # and missed is the safe side.
  #
  # The removal is best-effort but NOT silent, unlike the three siblings above:
  # their staleness is benign, whereas a stale loop state is the one direction
  # this design calls dangerous.
  if [ -e "$LOOP_STATE_FILE" ]; then
    rm -f "$LOOP_STATE_FILE" 2>/dev/null || true
    if [ -e "$LOOP_STATE_FILE" ]; then
      printf 'stride-hook: could not clear the loop state at %s; a stale completion record remains\n' \
        "$LOOP_STATE_FILE" >&2
    fi
  fi
fi

# Load cached env vars if available (all hooks benefit from this)
if [ -f "$ENV_CACHE" ]; then
  set -a
  . "$ENV_CACHE" 2>/dev/null || true
  set +a
fi

# (W1519) Forward the server-supplied hook env for the routed hook. The
# response's hook entry (singular `.hook` on claim, `.hooks[]` on complete/
# mark_reviewed) carries the authoritative env block. Applied AFTER the cache
# load so server-supplied keys (e.g. TASK_DESCRIPTION, TASK_NEEDS_REVIEW,
# BOARD_*/COLUMN_*/AGENT_NAME on a before_doing claim response) override stale
# cached values; keys the server does not supply keep their cached values.
# The pre phase has no tool_response yet, so this is post-only.
RESPONSE_PAYLOAD=""
AFTER_GOAL_ROUTED=false
if [ "$PHASE" = "post" ]; then
  RESPONSE_PAYLOAD=$(extract_response_payload "$INPUT")
  apply_env_lines "$(extract_hook_env "$RESPONSE_PAYLOAD" "$HOOK_NAME")"
fi

# (W1094) Verify-and-retry the changed_files upload before the primary
# before_review section runs — fresh AfterTool budget; TASK_ID and
# TASK_BASE_REF are in scope from the env cache. Self-gates on
# HOOK_NAME=before_review; best-effort, never fails the hook.
self_heal_changed_files_upload || true

# (W2144) Record the loop state for a successful completion. Self-gates on
# HOOK_NAME=before_review and is best-effort: a failure to record is logged to
# stderr and swallowed, never fatal to the completion. Placed BEFORE the
# primary section runs because the record is built only from $INPUT and
# $RESPONSE_PAYLOAD - nothing the section produces - so a before_review section
# that fails (and exits below) must not cost us the record. The completion
# already succeeded server-side by then; AfterTool cannot un-complete it.
record_loop_state_for_completion || true

# --- Execute the primary hook ---
# run_stride_section emits structured JSON itself and (for after_doing) writes
# the per-file diff snapshot via finalize_after_doing. Failure exits 2 here
# to preserve the existing PreToolUse blocking semantic for after_doing.
run_stride_section "$HOOK_NAME"
PRIMARY_RC=$?

# (D142) Capture TASK_BASE_REF only now — AFTER ## before_doing ran its
# `git pull` / branch checkout — so the base is the post-pull branch point.
# Runs even when the section failed: the claim already succeeded (AfterTool
# cannot veto it) and a partially-run section still leaves HEAD more accurate
# than the pre-pull value. No-op for every other hook route.
finalize_before_doing

# (W2524) Download the claimed task's attachments only NOW, after the
# ## before_doing section has finished, so a slow download can neither shrink
# that section's budget nor change its blocking result; and whatever the
# section returned, because AfterTool cannot veto a claim that already
# succeeded. Only a claim whose own response proved the task identity
# (ATTACHMENT_TASK_JSON, set beside write_task_file) downloads. Stdout is
# discarded because Gemini parses this hook's stdout as one JSON document; the
# summary goes to stderr.
if [ "$PHASE" = "post" ] && [ "$HOOK_NAME" = "before_doing" ] \
   && [ -n "${ATTACHMENT_TASK_JSON:-}" ]; then
  download_task_attachments "$ATTACHMENT_TASK_JSON" > /dev/null || true
fi

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
        AFTER_GOAL_ROUTED=true
        # (W1519) Export GOAL_* (server-supplied, with the parent-id fallback
        # for GOAL_ID) before the section runs. The section observes
        # HOOK_NAME=after_goal per the documented contract; the routed value
        # is restored afterwards because the cleanup gate below keys on it.
        export_after_goal_env "$RESPONSE_PAYLOAD"
        _routed_hook_name="$HOOK_NAME"
        export HOOK_NAME="after_goal"
        run_stride_section "after_goal" || true
        HOOK_NAME="$_routed_hook_name"
      fi
      ;;
  esac
fi

# Clean up env cache and changed-files snapshot after the final hook in the
# lifecycle so the next task starts from a clean slate.
if [ "$HOOK_NAME" = "after_review" ]; then
  # (W1519) Keep the env cache when after_goal rode this response — the agent
  # still needs GOAL_ID from it for the follow-up
  # PATCH /api/tasks/:goal_id/after_goal. The next claim rewrites the cache.
  if [ "$AFTER_GOAL_ROUTED" != "true" ]; then
    rm -f "$ENV_CACHE" 2>/dev/null || true
  fi
  rm -f "$PROJECT_DIR/.stride-changed-files.json" 2>/dev/null || true
  rm -f "$PROJECT_DIR/.stride-diff-upload-state" 2>/dev/null || true
  # (W1457) Clear the claim-time dirty baseline alongside the other artifacts.
  rm -f "$PROJECT_DIR/.stride-dirty-baseline" 2>/dev/null || true
fi

exit 0
