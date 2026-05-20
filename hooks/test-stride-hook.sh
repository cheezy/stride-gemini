#!/usr/bin/env bash
# test-stride-hook.sh — Tests for stride-hook.sh pure bash replacements
#
# Tests all code paths without requiring awk, sed, or seq.
# Simulates jq-absent environments to exercise fallback paths.

set -uo pipefail

PASS=0
FAIL=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/stride-hook.sh"

# Colors (if terminal supports them)
RED=""
GREEN=""
RESET=""
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  RESET='\033[0m'
fi

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "  ${GREEN}PASS${RESET}: $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: $label"
    echo "    expected: $(echo "$expected" | head -5)"
    echo "    actual:   $(echo "$actual" | head -5)"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if echo "$haystack" | grep -qF "$needle"; then
    echo -e "  ${GREEN}PASS${RESET}: $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: $label"
    echo "    expected to contain: $needle"
    echo "    actual: $(echo "$haystack" | head -5)"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" -eq "$actual" ]; then
    echo -e "  ${GREEN}PASS${RESET}: $label (exit $actual)"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: $label"
    echo "    expected exit: $expected"
    echo "    actual exit:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

# ============================================================
# Setup: create temp directory with test fixtures
# ============================================================
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# --- Test .stride.md files ---

cat > "$TMPDIR_TEST/basic.stride.md" << 'STRIDE'
## before_doing
```bash
echo "pulling latest"
echo "getting deps"
```

## after_doing
```bash
echo "running tests"
echo "running credo"
```

## before_review
```bash
echo "creating pr"
```

## after_review
```bash
echo "deploying"
```
STRIDE

cat > "$TMPDIR_TEST/with-comments.stride.md" << 'STRIDE'
## before_doing
```bash
# This is a comment
echo "step one"
   echo "indented step"
echo "step three"
# Another comment
```
STRIDE

cat > "$TMPDIR_TEST/no-hook.stride.md" << 'STRIDE'
## before_doing
```bash
echo "only before_doing here"
```
STRIDE

cat > "$TMPDIR_TEST/empty-block.stride.md" << 'STRIDE'
## after_doing
```bash
```
STRIDE

cat > "$TMPDIR_TEST/trailing-whitespace.stride.md" << 'STRIDE'
## before_doing
```bash
echo "found despite trailing whitespace"
```
STRIDE

cat > "$TMPDIR_TEST/multiple-code-blocks.stride.md" << 'STRIDE'
## before_doing

Some documentation text here.

```bash
echo "first command"
echo "second command"
```

More text and another block that should be ignored:

```bash
echo "should not appear"
```
STRIDE

cat > "$TMPDIR_TEST/no-bash-block.stride.md" << 'STRIDE'
## before_doing

Just some text, no code block.

## after_doing
```bash
echo "after_doing works"
```
STRIDE

cat > "$TMPDIR_TEST/adjacent-sections.stride.md" << 'STRIDE'
## before_doing
```bash
echo "before"
```
## after_doing
```bash
echo "after"
```
STRIDE

# ============================================================
# Test Group 1: Pure bash JSON extraction (no-jq fallback)
# ============================================================
echo ""
echo "=== Test Group 1: JSON command extraction (no-jq fallback) ==="

# We test the extraction logic in isolation by inlining the same bash
# parameter expansion used in the script.

extract_command_bash() {
  local INPUT="$1"
  local _tmp COMMAND
  _tmp="${INPUT#*\"command\"}"
  if [ "$_tmp" = "$INPUT" ]; then
    COMMAND=""
  else
    _tmp="${_tmp#*:}"
    _tmp="${_tmp#*\"}"
    COMMAND="${_tmp%%\"*}"
  fi
  echo "$COMMAND"
}

# 1a: Standard claim command
INPUT='{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}'
RESULT=$(extract_command_bash "$INPUT")
assert_eq "standard claim URL" \
  "curl -X POST https://stridelikeaboss.com/api/tasks/claim" \
  "$RESULT"

# 1b: Complete command with task ID
INPUT='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/123/complete"}}'
RESULT=$(extract_command_bash "$INPUT")
assert_eq "complete URL with ID" \
  "curl -X PATCH https://stridelikeaboss.com/api/tasks/123/complete" \
  "$RESULT"

# 1c: mark_reviewed command
INPUT='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/456/mark_reviewed"}}'
RESULT=$(extract_command_bash "$INPUT")
assert_eq "mark_reviewed URL" \
  "curl -X PATCH https://stridelikeaboss.com/api/tasks/456/mark_reviewed" \
  "$RESULT"

# 1d: No command key present
INPUT='{"tool_input":{"other_key":"some value"}}'
RESULT=$(extract_command_bash "$INPUT")
assert_eq "no command key returns empty" "" "$RESULT"

# 1e: Empty command value
INPUT='{"tool_input":{"command":""}}'
RESULT=$(extract_command_bash "$INPUT")
assert_eq "empty command value" "" "$RESULT"

# 1f: Command with spaces in URL params
INPUT='{"tool_input":{"command":"curl -H Authorization: Bearer token123 https://example.com/api/tasks/claim"}}'
RESULT=$(extract_command_bash "$INPUT")
assert_eq "command with spaces" \
  "curl -H Authorization: Bearer token123 https://example.com/api/tasks/claim" \
  "$RESULT"

# 1g: JSON with whitespace around colon
INPUT='{"tool_input":{ "command" : "curl https://example.com/api/tasks/claim" }}'
RESULT=$(extract_command_bash "$INPUT")
assert_eq "whitespace around colon" \
  "curl https://example.com/api/tasks/claim" \
  "$RESULT"

# 1h: Completely unrelated JSON
INPUT='{"foo":"bar","baz":42}'
RESULT=$(extract_command_bash "$INPUT")
assert_eq "unrelated JSON returns empty" "" "$RESULT"

# ============================================================
# Test Group 2: .stride.md parser (pure bash while-read loop)
# ============================================================
echo ""
echo "=== Test Group 2: .stride.md section parser ==="

# Inline the parser logic as a function for isolated testing
parse_stride_md() {
  local STRIDE_MD="$1" HOOK_NAME="$2"
  local COMMANDS="" _found=0 _capture=0 _line _section

  while IFS= read -r _line || [ -n "$_line" ]; do
    case "$_line" in
      "## "*)
        [ "$_found" -eq 1 ] && break
        _section="${_line#\#\# }"
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

  printf '%s' "$COMMANDS"
}

# 2a: Parse before_doing from basic file
RESULT=$(parse_stride_md "$TMPDIR_TEST/basic.stride.md" "before_doing")
assert_contains "basic: before_doing line 1" 'echo "pulling latest"' "$RESULT"
assert_contains "basic: before_doing line 2" 'echo "getting deps"' "$RESULT"

# 2b: Parse after_doing from basic file
RESULT=$(parse_stride_md "$TMPDIR_TEST/basic.stride.md" "after_doing")
assert_contains "basic: after_doing line 1" 'echo "running tests"' "$RESULT"
assert_contains "basic: after_doing line 2" 'echo "running credo"' "$RESULT"

# 2c: Parse before_review
RESULT=$(parse_stride_md "$TMPDIR_TEST/basic.stride.md" "before_review")
assert_contains "basic: before_review" 'echo "creating pr"' "$RESULT"

# 2d: Parse after_review
RESULT=$(parse_stride_md "$TMPDIR_TEST/basic.stride.md" "after_review")
assert_contains "basic: after_review" 'echo "deploying"' "$RESULT"

# 2e: Doesn't bleed between sections
RESULT=$(parse_stride_md "$TMPDIR_TEST/basic.stride.md" "before_doing")
if echo "$RESULT" | grep -qF "running tests"; then
  echo -e "  ${RED}FAIL${RESET}: sections should not bleed into each other"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: sections do not bleed into each other"
  PASS=$((PASS + 1))
fi

# 2f: Hook not present in file
RESULT=$(parse_stride_md "$TMPDIR_TEST/no-hook.stride.md" "after_doing")
assert_eq "missing hook returns empty" "" "$RESULT"

# 2g: Empty code block
RESULT=$(parse_stride_md "$TMPDIR_TEST/empty-block.stride.md" "after_doing")
assert_eq "empty code block returns empty" "" "$RESULT"

# 2h: Comments and indentation are preserved (filtered later by CMD_LIST loop)
RESULT=$(parse_stride_md "$TMPDIR_TEST/with-comments.stride.md" "before_doing")
assert_contains "comments preserved in raw output" "# This is a comment" "$RESULT"
assert_contains "indented line preserved" 'echo "indented step"' "$RESULT"

# 2i: Trailing whitespace on section name
RESULT=$(parse_stride_md "$TMPDIR_TEST/trailing-whitespace.stride.md" "before_doing")
assert_contains "trailing whitespace trimmed from heading" 'echo "found despite trailing whitespace"' "$RESULT"

# 2j: Only first code block is captured
RESULT=$(parse_stride_md "$TMPDIR_TEST/multiple-code-blocks.stride.md" "before_doing")
assert_contains "first block captured" 'echo "first command"' "$RESULT"
if echo "$RESULT" | grep -qF "should not appear"; then
  echo -e "  ${RED}FAIL${RESET}: second code block should not be captured"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: second code block is ignored"
  PASS=$((PASS + 1))
fi

# 2k: Section with no bash block
RESULT=$(parse_stride_md "$TMPDIR_TEST/no-bash-block.stride.md" "before_doing")
assert_eq "no bash block returns empty" "" "$RESULT"

# 2l: Adjacent sections (no blank line between)
RESULT=$(parse_stride_md "$TMPDIR_TEST/adjacent-sections.stride.md" "before_doing")
assert_contains "adjacent: before_doing correct" 'echo "before"' "$RESULT"
if echo "$RESULT" | grep -qF 'echo "after"'; then
  echo -e "  ${RED}FAIL${RESET}: adjacent sections should not bleed"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: adjacent sections do not bleed"
  PASS=$((PASS + 1))
fi

RESULT=$(parse_stride_md "$TMPDIR_TEST/adjacent-sections.stride.md" "after_doing")
assert_contains "adjacent: after_doing correct" 'echo "after"' "$RESULT"

# ============================================================
# Test Group 3: Whitespace trimming (pure bash)
# ============================================================
echo ""
echo "=== Test Group 3: Whitespace trimming ==="

trim_leading() {
  local cmd="$1"
  local trimmed="${cmd#"${cmd%%[![:space:]]*}"}"
  echo "$trimmed"
}

# 3a: Leading spaces
RESULT=$(trim_leading "   echo hello")
assert_eq "trim leading spaces" "echo hello" "$RESULT"

# 3b: Leading tabs
RESULT=$(trim_leading "		echo hello")
assert_eq "trim leading tabs" "echo hello" "$RESULT"

# 3c: Mixed spaces and tabs
RESULT=$(trim_leading "	  	echo hello")
assert_eq "trim mixed whitespace" "echo hello" "$RESULT"

# 3d: No leading whitespace
RESULT=$(trim_leading "echo hello")
assert_eq "no trim needed" "echo hello" "$RESULT"

# 3e: All whitespace
RESULT=$(trim_leading "   ")
assert_eq "all whitespace becomes empty" "" "$RESULT"

# 3f: Empty string
RESULT=$(trim_leading "")
assert_eq "empty string stays empty" "" "$RESULT"

# ============================================================
# Test Group 4: Command list building (comments/blanks filtered)
# ============================================================
echo ""
echo "=== Test Group 4: Command list building ==="

build_cmd_list() {
  local COMMANDS="$1"
  local CMD_LIST=()
  while IFS= read -r cmd; do
    local trimmed="${cmd#"${cmd%%[![:space:]]*}"}"
    [ -z "$trimmed" ] && continue
    case "$trimmed" in \#*) continue ;; esac
    CMD_LIST+=("$trimmed")
  done <<< "$COMMANDS"
  [ ${#CMD_LIST[@]} -gt 0 ] && printf '%s\n' "${CMD_LIST[@]}" || true
}

# 4a: Filters comments and blank lines
COMMANDS='# comment
echo "step one"
   echo "indented step"

echo "step three"
# trailing comment'
RESULT=$(build_cmd_list "$COMMANDS")
LINES=$(echo "$RESULT" | wc -l | tr -d ' ')
assert_eq "filtered to 3 commands" "3" "$LINES"
assert_contains "keeps step one" 'echo "step one"' "$RESULT"
assert_contains "trims indented step" 'echo "indented step"' "$RESULT"
assert_contains "keeps step three" 'echo "step three"' "$RESULT"

# 4b: All comments/blanks
COMMANDS='# only comments

# more comments
'
RESULT=$(build_cmd_list "$COMMANDS")
# When all filtered, we get one empty line from printf of empty array
TRIMMED_RESULT="${RESULT#"${RESULT%%[![:space:]]*}"}"
assert_eq "all comments filtered to empty" "" "$TRIMMED_RESULT"

# ============================================================
# Test Group 5: Full integration (end-to-end via the script)
# ============================================================
echo ""
echo "=== Test Group 5: Full integration ==="

# Create a project directory with .stride.md
PROJ="$TMPDIR_TEST/project"
mkdir -p "$PROJ"
cat > "$PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "before_doing_executed"
```

## after_doing
```bash
echo "after_doing_executed"
```

## before_review
```bash
echo "before_review_executed"
```

## after_review
```bash
echo "after_review_executed"
```
STRIDE

# 5a: Claim triggers before_doing (post phase)
CLAIM_JSON='{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim -d {}"}}'
OUTPUT=$(echo "$CLAIM_JSON" | GEMINI_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "claim exits 0" 0 "$EXIT_CODE"
assert_contains "claim runs before_doing" "before_doing_executed" "$OUTPUT"

# 5b: Pre-complete triggers after_doing (pre phase)
COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}}'
OUTPUT=$(echo "$COMPLETE_JSON" | GEMINI_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" pre 2>&1)
EXIT_CODE=$?
assert_exit "pre-complete exits 0" 0 "$EXIT_CODE"
assert_contains "pre-complete runs after_doing" "after_doing_executed" "$OUTPUT"

# 5c: Post-complete triggers before_review (post phase)
OUTPUT=$(echo "$COMPLETE_JSON" | GEMINI_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "post-complete exits 0" 0 "$EXIT_CODE"
assert_contains "post-complete runs before_review" "before_review_executed" "$OUTPUT"

# 5d: Mark-reviewed triggers after_review (post phase)
REVIEW_JSON='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/mark_reviewed"}}'
OUTPUT=$(echo "$REVIEW_JSON" | GEMINI_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "mark-reviewed exits 0" 0 "$EXIT_CODE"
assert_contains "mark-reviewed runs after_review" "after_review_executed" "$OUTPUT"

# 5e: Non-stride command exits cleanly
OTHER_JSON='{"tool_input":{"command":"ls -la"}}'
OUTPUT=$(echo "$OTHER_JSON" | GEMINI_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "non-stride exits 0" 0 "$EXIT_CODE"
assert_eq "non-stride produces no output" "" "$OUTPUT"

# 5f: No .stride.md exits cleanly
EMPTY_PROJ="$TMPDIR_TEST/empty-project"
mkdir -p "$EMPTY_PROJ"
OUTPUT=$(echo "$CLAIM_JSON" | GEMINI_PROJECT_DIR="$EMPTY_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "no .stride.md exits 0" 0 "$EXIT_CODE"

# 5g: No phase argument exits cleanly
OUTPUT=$(echo "$CLAIM_JSON" | GEMINI_PROJECT_DIR="$PROJ" bash "$HOOK_SCRIPT" 2>&1)
EXIT_CODE=$?
assert_exit "no phase exits 0" 0 "$EXIT_CODE"

# 5h: Hook with failing command exits 2
FAIL_PROJ="$TMPDIR_TEST/fail-project"
mkdir -p "$FAIL_PROJ"
cat > "$FAIL_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "step one passes"
false
echo "step three should not run"
```
STRIDE
# Capture stderr (execution output) separately from stdout (JSON diagnostics)
FAIL_STDERR_FILE=$(mktemp)
OUTPUT=$(echo "$CLAIM_JSON" | GEMINI_PROJECT_DIR="$FAIL_PROJ" bash "$HOOK_SCRIPT" post 2>"$FAIL_STDERR_FILE")
EXIT_CODE=$?
FAIL_STDERR=$(cat "$FAIL_STDERR_FILE")
rm -f "$FAIL_STDERR_FILE"
assert_exit "failing hook exits 2" 2 "$EXIT_CODE"
assert_contains "failing hook ran step one" "step one passes" "$FAIL_STDERR"
if echo "$FAIL_STDERR" | grep -qF "step three should not run"; then
  echo -e "  ${RED}FAIL${RESET}: should not run commands after failure"
  FAIL=$((FAIL + 1))
else
  echo -e "  ${GREEN}PASS${RESET}: stops execution after failure"
  PASS=$((PASS + 1))
fi

# 5i: Hook with multiple successful commands
MULTI_PROJ="$TMPDIR_TEST/multi-project"
mkdir -p "$MULTI_PROJ"
cat > "$MULTI_PROJ/.stride.md" << 'STRIDE'
## after_doing
```bash
echo "test_one"
echo "test_two"
echo "test_three"
```
STRIDE
OUTPUT=$(echo "$COMPLETE_JSON" | GEMINI_PROJECT_DIR="$MULTI_PROJ" bash "$HOOK_SCRIPT" pre 2>&1)
EXIT_CODE=$?
assert_exit "multi-command exits 0" 0 "$EXIT_CODE"
assert_contains "multi-command: step 1" "test_one" "$OUTPUT"
assert_contains "multi-command: step 2" "test_two" "$OUTPUT"
assert_contains "multi-command: step 3" "test_three" "$OUTPUT"

# 5j: Hook section not defined for this phase
PARTIAL_PROJ="$TMPDIR_TEST/partial-project"
mkdir -p "$PARTIAL_PROJ"
cat > "$PARTIAL_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "only before_doing"
```
STRIDE
OUTPUT=$(echo "$COMPLETE_JSON" | GEMINI_PROJECT_DIR="$PARTIAL_PROJ" bash "$HOOK_SCRIPT" pre 2>&1)
EXIT_CODE=$?
assert_exit "missing section exits 0" 0 "$EXIT_CODE"
assert_eq "missing section no output" "" "$OUTPUT"

# ============================================================
# Test Group 6: Edge cases
# ============================================================
echo ""
echo "=== Test Group 6: Edge cases ==="

# 6a: .stride.md with no trailing newline
NO_NEWLINE_PROJ="$TMPDIR_TEST/no-newline-project"
mkdir -p "$NO_NEWLINE_PROJ"
printf '## before_doing\n```bash\necho "no trailing newline"\n```' > "$NO_NEWLINE_PROJ/.stride.md"
OUTPUT=$(echo "$CLAIM_JSON" | GEMINI_PROJECT_DIR="$NO_NEWLINE_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "no trailing newline exits 0" 0 "$EXIT_CODE"
assert_contains "no trailing newline runs command" "no trailing newline" "$OUTPUT"

# 6b: Command with environment variable references
ENV_PROJ="$TMPDIR_TEST/env-project"
mkdir -p "$ENV_PROJ"
cat > "$ENV_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "home=$HOME"
```
STRIDE
OUTPUT=$(echo "$CLAIM_JSON" | GEMINI_PROJECT_DIR="$ENV_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "env var expansion exits 0" 0 "$EXIT_CODE"
assert_contains "env var expanded" "home=$HOME" "$OUTPUT"

# 6c: .stride.md with CRLF line endings (Windows)
CRLF_PROJ="$TMPDIR_TEST/crlf-project"
mkdir -p "$CRLF_PROJ"
printf '## before_doing\r\n```bash\r\necho "crlf test"\r\n```\r\n' > "$CRLF_PROJ/.stride.md"
OUTPUT=$(echo "$CLAIM_JSON" | GEMINI_PROJECT_DIR="$CRLF_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
EXIT_CODE=$?
assert_exit "CRLF line endings exits 0" 0 "$EXIT_CODE"
assert_contains "CRLF runs command" "crlf test" "$OUTPUT"

# 6d: JSON with tool_response (env caching path, requires jq)
if command -v jq > /dev/null 2>&1; then
  CACHE_PROJ="$TMPDIR_TEST/cache-project"
  mkdir -p "$CACHE_PROJ"
  cat > "$CACHE_PROJ/.stride.md" << 'STRIDE'
## before_doing
```bash
echo "id=$TASK_IDENTIFIER title=$TASK_TITLE"
```
STRIDE
  CLAIM_WITH_RESPONSE='{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"},"tool_response":"{\"data\":{\"id\":42,\"identifier\":\"W99\",\"title\":\"Test Task\",\"status\":\"doing\",\"complexity\":\"small\",\"priority\":\"high\"}}"}'
  OUTPUT=$(echo "$CLAIM_WITH_RESPONSE" | GEMINI_PROJECT_DIR="$CACHE_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
  EXIT_CODE=$?
  assert_exit "env caching exits 0" 0 "$EXIT_CODE"
  assert_contains "env cache: identifier" "id=W99" "$OUTPUT"
  assert_contains "env cache: title" "title=Test Task" "$OUTPUT"
  # Clean up env cache
  rm -f "$CACHE_PROJ/.stride-env-cache"

  # 6e: host wraps API JSON inside tool_response.stdout (Bash tool wrapper shape)
  CC_CLAIM='{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"},"tool_response":{"stdout":"{\"data\":{\"id\":1526,\"identifier\":\"W217\",\"title\":\"Wrapped Task\",\"status\":\"in_progress\",\"complexity\":\"medium\",\"priority\":\"high\"}}","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false}}'
  OUTPUT=$(echo "$CC_CLAIM" | GEMINI_PROJECT_DIR="$CACHE_PROJ" bash "$HOOK_SCRIPT" post 2>&1)
  EXIT_CODE=$?
  assert_exit "env caching (stdout wrapper) exits 0" 0 "$EXIT_CODE"
  assert_contains "env cache (wrapped): identifier" "id=W217" "$OUTPUT"
  assert_contains "env cache (wrapped): title" "title=Wrapped Task" "$OUTPUT"
  rm -f "$CACHE_PROJ/.stride-env-cache"
else
  echo "  SKIP: env caching tests (jq not available)"
fi


# ============================================================
# Test Group 7: Per-file diff capture (G148/W719 contract)
# ============================================================
echo ""
echo "=== Test Group 7: Per-file diff capture ==="

# Source the capture function from the hook script. The script's main flow
# only runs when stdin is provided and a hook name is matched, so sourcing it
# without those preconditions safely defines the function without executing
# anything.
if ! command -v jq > /dev/null 2>&1; then
  echo "  SKIP: diff-capture tests (jq not available)"
elif ! command -v git > /dev/null 2>&1; then
  echo "  SKIP: diff-capture tests (git not available)"
else
  # Mirror of the inline truncation logic for isolated unit testing.
  trunc_diff_inline() {
    local diff_text="$1"
    local max_lines="$2"
    local marker="$3"

    local line_count=0
    if [ -n "$diff_text" ]; then
      local _no_nl="${diff_text//$'\n'/}"
      line_count=$(( ${#diff_text} - ${#_no_nl} + 1 ))
    fi
    if [ "$line_count" -gt "$max_lines" ]; then
      local truncated
      truncated=$(printf '%s\n' "$diff_text" | head -n $((max_lines - 1)))
      printf '%s\n%s' "$truncated" "$marker"
    else
      printf '%s' "$diff_text"
    fi
  }

  # Mirror of the inline binary-detection logic for isolated unit testing.
  is_binary_in_numstat() {
    local numstat="$1" target="$2"
    local nl added rest deleted path
    while IFS= read -r nl; do
      added="${nl%%	*}"
      rest="${nl#*	}"
      deleted="${rest%%	*}"
      path="${rest#*	}"
      if [ "$added" = "-" ] && [ "$deleted" = "-" ] && [ "$path" = "$target" ]; then
        return 0
      fi
    done <<< "$numstat"
    return 1
  }

  # 7a: Truncation — diff at exactly 500 lines is not truncated
  EXACT_500=$(for i in $(seq 1 500); do echo "line $i"; done)
  RESULT=$(trunc_diff_inline "$EXACT_500" 500 "[diff truncated at 500 lines]")
  RESULT_LINES=$(printf '%s\n' "$RESULT" | wc -l | tr -d ' ')
  assert_eq "500-line diff: line count preserved" "500" "$RESULT_LINES"
  if echo "$RESULT" | grep -qF "[diff truncated at 500 lines]"; then
    echo -e "  ${RED}FAIL${RESET}: 500-line diff should not contain truncation marker"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: 500-line diff is not truncated"
    PASS=$((PASS + 1))
  fi

  # 7b: Truncation — diff over 500 lines is truncated with the contract marker
  OVER_500=$(for i in $(seq 1 750); do echo "line $i"; done)
  RESULT=$(trunc_diff_inline "$OVER_500" 500 "[diff truncated at 500 lines]")
  RESULT_LINES=$(printf '%s\n' "$RESULT" | wc -l | tr -d ' ')
  assert_eq "750-line diff: truncated to 500 lines total" "500" "$RESULT_LINES"
  assert_contains "750-line diff: marker appended" \
    "[diff truncated at 500 lines]" \
    "$RESULT"
  # Last line should be the marker
  LAST_LINE=$(printf '%s\n' "$RESULT" | tail -n 1)
  assert_eq "750-line diff: marker is last line" \
    "[diff truncated at 500 lines]" \
    "$LAST_LINE"

  # 7c: Truncation — empty input stays empty
  RESULT=$(trunc_diff_inline "" 500 "[diff truncated at 500 lines]")
  assert_eq "empty diff stays empty" "" "$RESULT"

  # 7d: Binary detection — numstat with "- - <file>" returns true
  NUMSTAT='10	2	lib/foo.ex
-	-	assets/logo.png
3	0	test/foo_test.exs'
  if is_binary_in_numstat "$NUMSTAT" "assets/logo.png"; then
    echo -e "  ${GREEN}PASS${RESET}: binary file detected from numstat"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: binary file not detected"
    FAIL=$((FAIL + 1))
  fi

  # 7e: Binary detection — text file does not match
  if is_binary_in_numstat "$NUMSTAT" "lib/foo.ex"; then
    echo -e "  ${RED}FAIL${RESET}: text file misidentified as binary"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: text file correctly not flagged binary"
    PASS=$((PASS + 1))
  fi

  # 7f: Binary detection — file not in numstat
  if is_binary_in_numstat "$NUMSTAT" "nonexistent.txt"; then
    echo -e "  ${RED}FAIL${RESET}: missing file misidentified as binary"
    FAIL=$((FAIL + 1))
  else
    echo -e "  ${GREEN}PASS${RESET}: missing file correctly not flagged binary"
    PASS=$((PASS + 1))
  fi

  # 7g: Integration — capture_changed_files in a real temp git repo
  # Source the function from the hook script. Set arg empty to skip script main.
  CAPTURE_DIR=$(mktemp -d)
  (
    cd "$CAPTURE_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "original" > a.txt
    echo "original" > b.txt
    # Create a small binary file (PNG signature + nulls)
    printf '\x89PNG\r\n\x1a\n\x00\x00\x00\x00\x00\x00\x00\x00' > logo.png
    git add . > /dev/null
    git commit -q -m "initial"

    # Capture the base
    BASE=$(git rev-parse HEAD)

    # Modify text + binary
    echo "modified" > a.txt
    printf '\x89PNG\r\n\x1a\n\xff\xff\xff\xff\xff\xff\xff\xff' > logo.png
    rm b.txt
    git add -A > /dev/null
    git commit -q -m "changes"

    # Source the capture function from the hook script.
    # The early-exit checks (no phase, no .stride.md) keep main from running.
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true

    capture_changed_files "$BASE"
  ) > "$CAPTURE_DIR/capture.json" 2> "$CAPTURE_DIR/capture.err"

  CAPTURE_OUTPUT=$(cat "$CAPTURE_DIR/capture.json")

  # Verify the output is a JSON array of length 3
  if echo "$CAPTURE_OUTPUT" | jq -e 'type == "array" and length == 3' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: integration: emits 3-entry JSON array"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: integration: expected 3-entry array, got: $(echo "$CAPTURE_OUTPUT" | head -c 200)"
    FAIL=$((FAIL + 1))
  fi

  # Text file should have a unified-patch diff
  TEXT_DIFF=$(echo "$CAPTURE_OUTPUT" | jq -r '.[] | select(.path == "a.txt") | .diff')
  # `grep -F` still treats a leading "--" as an option; pick a needle that
  # avoids that without weakening the assertion.
  assert_contains "integration: text file has unified-patch header" \
    "diff --git a/a.txt" \
    "$TEXT_DIFF"
  assert_contains "integration: text file has +/- lines" "+modified" "$TEXT_DIFF"

  # Binary file should have the exact placeholder
  BIN_DIFF=$(echo "$CAPTURE_OUTPUT" | jq -r '.[] | select(.path == "logo.png") | .diff')
  assert_eq "integration: binary file emits exact placeholder" \
    "[binary file — no diff captured]" \
    "$BIN_DIFF"

  # Deleted file (b.txt) still appears in the changed-files list
  DELETED_PRESENT=$(echo "$CAPTURE_OUTPUT" | jq -r '.[] | select(.path == "b.txt") | .path')
  assert_eq "integration: deleted file present in array" "b.txt" "$DELETED_PRESENT"

  rm -rf "$CAPTURE_DIR"

  # 7h: Fallback — non-repo directory returns empty array
  NONREPO_DIR=$(mktemp -d)
  (
    cd "$NONREPO_DIR" || exit 1
    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files ""
  ) > "$NONREPO_DIR/out.json" 2>/dev/null
  NONREPO_OUTPUT=$(cat "$NONREPO_DIR/out.json")
  if echo "$NONREPO_OUTPUT" | jq -e 'type == "array" and length == 0' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: non-repo directory returns empty array"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: non-repo expected [], got: $NONREPO_OUTPUT"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$NONREPO_DIR"

  # 7i: Fallback — empty base ref with a valid HEAD~1 still captures
  FALLBACK_DIR=$(mktemp -d)
  FALLBACK_OUT=$(mktemp)
  (
    cd "$FALLBACK_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "first" > c.txt
    git add c.txt > /dev/null
    git commit -q -m "first"
    echo "second" > c.txt
    git add c.txt > /dev/null
    git commit -q -m "second"

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files ""
  ) > "$FALLBACK_OUT" 2>/dev/null
  FALLBACK_OUTPUT=$(cat "$FALLBACK_OUT")
  rm -f "$FALLBACK_OUT"
  if echo "$FALLBACK_OUTPUT" | jq -e 'type == "array" and length == 1 and .[0].path == "c.txt"' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: empty base falls back to HEAD~1 successfully"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: empty-base fallback expected single c.txt entry, got: $FALLBACK_OUTPUT"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$FALLBACK_DIR"

  # 7j: End-to-end — after_doing hook writes .stride-changed-files.json
  E2E_DIR=$(mktemp -d)
  (
    cd "$E2E_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    # Gitignore the hook's runtime artifacts so they don't leak into the
    # snapshot via the Option D untracked-file capture.
    cat > .gitignore << 'GITIGNORE'
.stride.md
.stride-env-cache
.stride-changed-files.json
GITIGNORE
    echo "v1" > tracked.txt
    git add .gitignore tracked.txt > /dev/null
    git commit -q -m "v1 + gitignore"
    BASE=$(git rev-parse HEAD)
    echo "v2" > tracked.txt
    git add tracked.txt > /dev/null
    git commit -q -m "v2"

    cat > .stride.md << 'STRIDE'
## after_doing
```bash
echo "ran after_doing"
```
STRIDE

    # Pre-populate the env cache with the base ref the hook would have set
    printf "TASK_BASE_REF='%s'\n" "$BASE" > .stride-env-cache

    COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/1/complete"}}'
    echo "$COMPLETE_JSON" | GEMINI_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  if [ -f "$E2E_DIR/.stride-changed-files.json" ]; then
    E2E_JSON=$(cat "$E2E_DIR/.stride-changed-files.json")
    if echo "$E2E_JSON" | jq -e 'type == "array" and length == 1 and .[0].path == "tracked.txt"' > /dev/null 2>&1; then
      echo -e "  ${GREEN}PASS${RESET}: e2e: after_doing wrote correct .stride-changed-files.json"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${RESET}: e2e: unexpected JSON contents: $E2E_JSON"
      FAIL=$((FAIL + 1))
    fi
  else
    echo -e "  ${RED}FAIL${RESET}: e2e: .stride-changed-files.json was not written"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$E2E_DIR"

  # 7k: All-commented after_doing still triggers capture
  NOCMD_DIR=$(mktemp -d)
  (
    cd "$NOCMD_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > f.txt
    git add f.txt > /dev/null
    # Gitignore stride runtime artifacts (Option D would otherwise capture
    # the test-fixture .stride.md / .stride-env-cache as untracked files).
    cat > .gitignore << 'GITIGNORE'
.stride.md
.stride-env-cache
.stride-changed-files.json
GITIGNORE
    git add .gitignore > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    echo "v2" > f.txt
    git add f.txt > /dev/null
    git commit -q -m "v2"

    cat > .stride.md << 'STRIDE'
## after_doing
```bash
# every command commented out
# echo "this never runs"
```
STRIDE

    printf "TASK_BASE_REF='%s'\n" "$BASE" > .stride-env-cache

    COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/1/complete"}}'
    echo "$COMPLETE_JSON" | GEMINI_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" pre > /dev/null 2>&1
  )
  if [ -f "$NOCMD_DIR/.stride-changed-files.json" ]; then
    NOCMD_JSON=$(cat "$NOCMD_DIR/.stride-changed-files.json")
    if echo "$NOCMD_JSON" | jq -e 'type == "array" and length == 1 and .[0].path == "f.txt"' > /dev/null 2>&1; then
      echo -e "  ${GREEN}PASS${RESET}: all-commented after_doing still triggers capture"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${RESET}: all-commented after_doing: unexpected JSON: $NOCMD_JSON"
      FAIL=$((FAIL + 1))
    fi
  else
    echo -e "  ${RED}FAIL${RESET}: all-commented after_doing did not write the JSON snapshot"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$NOCMD_DIR"

  # 7l: Legacy bypass — non-after_doing hooks must NOT touch the snapshot file
  # If a stale snapshot exists from a prior after_doing, before_review (or any
  # other phase) must leave it untouched. This preserves the backward-compat
  # guarantee: legacy code paths that don't run the capture continue to work.
  BYPASS_DIR=$(mktemp -d)
  (
    cd "$BYPASS_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > x.txt
    git add x.txt > /dev/null
    git commit -q -m "v1"

    cat > .stride.md << 'STRIDE'
## before_review
```bash
echo "ran before_review"
```
STRIDE

    # Pre-seed the snapshot file with a marker we can detect.
    echo '[{"path":"stale.txt","diff":"stale"}]' > .stride-changed-files.json

    COMPLETE_JSON='{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/1/complete"}}'
    # `post` phase + complete URL → before_review (not after_doing)
    echo "$COMPLETE_JSON" | GEMINI_PROJECT_DIR="$PWD" bash "$HOOK_SCRIPT" post > /dev/null 2>&1
  )
  if [ -f "$BYPASS_DIR/.stride-changed-files.json" ]; then
    BYPASS_JSON=$(cat "$BYPASS_DIR/.stride-changed-files.json")
    if echo "$BYPASS_JSON" | jq -e '.[0].path == "stale.txt"' > /dev/null 2>&1; then
      echo -e "  ${GREEN}PASS${RESET}: legacy bypass — before_review preserves snapshot file"
      PASS=$((PASS + 1))
    else
      echo -e "  ${RED}FAIL${RESET}: legacy bypass — before_review overwrote the snapshot: $BYPASS_JSON"
      FAIL=$((FAIL + 1))
    fi
  else
    echo -e "  ${RED}FAIL${RESET}: legacy bypass — before_review deleted the snapshot unexpectedly"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$BYPASS_DIR"

  # 7m: Empty changed-files list — base ref resolves but no files differ
  EMPTY_DIFF_DIR=$(mktemp -d)
  EMPTY_DIFF_OUT=$(mktemp)
  (
    cd "$EMPTY_DIFF_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > y.txt
    git add y.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    # Make a second commit with no real changes (use --allow-empty)
    git commit -q --allow-empty -m "empty"

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) > "$EMPTY_DIFF_OUT" 2>/dev/null
  EMPTY_DIFF_OUTPUT=$(cat "$EMPTY_DIFF_OUT")
  rm -f "$EMPTY_DIFF_OUT"
  if echo "$EMPTY_DIFF_OUTPUT" | jq -e 'type == "array" and length == 0' > /dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${RESET}: empty changed-files list returns []"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}FAIL${RESET}: empty changed-files expected [], got: $EMPTY_DIFF_OUTPUT"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$EMPTY_DIFF_DIR"

  # 7n: File with embedded null bytes — git --numstat reports as binary, so the
  # placeholder must be emitted (no patch attempt)
  NULL_DIR=$(mktemp -d)
  (
    cd "$NULL_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    printf 'plain text\n' > nullfile.dat
    git add nullfile.dat > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)
    # Replace contents with bytes that include nulls
    printf 'text\x00with\x00nulls\n' > nullfile.dat
    git add nullfile.dat > /dev/null
    git commit -q -m "v2"

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) > "$NULL_DIR/out.json" 2>/dev/null
  NULL_OUTPUT=$(cat "$NULL_DIR/out.json")
  NULL_DIFF=$(echo "$NULL_OUTPUT" | jq -r '.[0].diff // ""')
  assert_eq "null-byte file emits binary placeholder" \
    "[binary file — no diff captured]" \
    "$NULL_DIFF"
  rm -rf "$NULL_DIR"

  # ---------------------------------------------------------------------------
  # Test Group 7 (Option D semantic) — cases 7o-7s
  # The snapshot must reflect the agent's working state at completion time:
  # modified-uncommitted tracked files, staged-uncommitted changes, untracked
  # new files (synthesized new-file patches), untracked binaries (placeholder),
  # and dedupe when a path is both committed-since-base AND further modified
  # in the working tree.
  # ---------------------------------------------------------------------------

  # 7o: Modified-uncommitted tracked file appears in the snapshot
  UNCOMMITTED_DIR=$(mktemp -d)
  (
    cd "$UNCOMMITTED_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > tracked.txt
    git add tracked.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)

    # Modify the tracked file WITHOUT committing or staging
    echo "v2-uncommitted" > tracked.txt

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) > "$UNCOMMITTED_DIR/out.json" 2>/dev/null
  UNCOMMITTED_OUTPUT=$(cat "$UNCOMMITTED_DIR/out.json")
  UNCOMMITTED_DIFF=$(echo "$UNCOMMITTED_OUTPUT" | jq -r '.[] | select(.path == "tracked.txt") | .diff')
  if [ -n "$UNCOMMITTED_DIFF" ]; then
    assert_contains "Option D: modified-uncommitted tracked file has unified-patch header" \
      "diff --git a/tracked.txt" \
      "$UNCOMMITTED_DIFF"
    assert_contains "Option D: modified-uncommitted tracked file diff body present" \
      "+v2-uncommitted" \
      "$UNCOMMITTED_DIFF"
  else
    echo -e "  ${RED}FAIL${RESET}: Option D: modified-uncommitted tracked file missing from snapshot"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$UNCOMMITTED_DIR"

  # 7p: Staged-uncommitted change appears in the snapshot
  STAGED_DIR=$(mktemp -d)
  (
    cd "$STAGED_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > staged.txt
    git add staged.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)

    # Modify and stage WITHOUT committing
    echo "v2-staged" > staged.txt
    git add staged.txt > /dev/null

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) > "$STAGED_DIR/out.json" 2>/dev/null
  STAGED_OUTPUT=$(cat "$STAGED_DIR/out.json")
  STAGED_DIFF=$(echo "$STAGED_OUTPUT" | jq -r '.[] | select(.path == "staged.txt") | .diff')
  if [ -n "$STAGED_DIFF" ]; then
    assert_contains "Option D: staged-uncommitted file has unified-patch header" \
      "diff --git a/staged.txt" \
      "$STAGED_DIFF"
    assert_contains "Option D: staged-uncommitted file diff body present" \
      "+v2-staged" \
      "$STAGED_DIFF"
  else
    echo -e "  ${RED}FAIL${RESET}: Option D: staged-uncommitted file missing from snapshot"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$STAGED_DIR"

  # 7q: Untracked new file appears as synthesized new-file patch
  UNTRACKED_DIR=$(mktemp -d)
  (
    cd "$UNTRACKED_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > existing.txt
    git add existing.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)

    # Create a NEW untracked file
    cat > new_file.txt << 'NEW'
line one
line two
line three
NEW

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) > "$UNTRACKED_DIR/out.json" 2>/dev/null
  UNTRACKED_OUTPUT=$(cat "$UNTRACKED_DIR/out.json")
  UNTRACKED_DIFF=$(echo "$UNTRACKED_OUTPUT" | jq -r '.[] | select(.path == "new_file.txt") | .diff')
  if [ -n "$UNTRACKED_DIFF" ]; then
    # Synthesized new-file patch should have the +++ b/<path> header and at
    # least one `+<content>` body line.
    assert_contains "Option D: untracked new file has +++ b/<path> header" \
      "+++ b/new_file.txt" \
      "$UNTRACKED_DIFF"
    assert_contains "Option D: untracked new file has +<content> body lines" \
      "+line one" \
      "$UNTRACKED_DIFF"
  else
    echo -e "  ${RED}FAIL${RESET}: Option D: untracked new file missing from snapshot (output: $UNTRACKED_OUTPUT)"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$UNTRACKED_DIR"

  # 7r: Untracked binary uses the binary placeholder
  UNTRACKED_BIN_DIR=$(mktemp -d)
  (
    cd "$UNTRACKED_BIN_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > a.txt
    git add a.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)

    # Create an untracked file with NUL bytes (binary)
    printf 'binary\x00data\x00here\n' > new.bin

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) > "$UNTRACKED_BIN_DIR/out.json" 2>/dev/null
  UNTRACKED_BIN_OUTPUT=$(cat "$UNTRACKED_BIN_DIR/out.json")
  UNTRACKED_BIN_DIFF=$(echo "$UNTRACKED_BIN_OUTPUT" | jq -r '.[] | select(.path == "new.bin") | .diff')
  assert_eq "Option D: untracked binary file emits exact binary placeholder" \
    "[binary file — no diff captured]" \
    "$UNTRACKED_BIN_DIFF"
  rm -rf "$UNTRACKED_BIN_DIR"

  # 7s: Dedupe — committed-and-further-modified path appears exactly once
  DEDUPE_DIR=$(mktemp -d)
  (
    cd "$DEDUPE_DIR" || exit 1
    git init -q
    git config user.email "test@test.local"
    git config user.name "Test"
    echo "v1" > dual.txt
    git add dual.txt > /dev/null
    git commit -q -m "v1"
    BASE=$(git rev-parse HEAD)

    # Commit a change…
    echo "v2-committed" > dual.txt
    git add dual.txt > /dev/null
    git commit -q -m "v2"

    # …then modify the same path further WITHOUT committing
    echo "v3-uncommitted-on-top" > dual.txt

    # shellcheck disable=SC1090
    source "$HOOK_SCRIPT" 2>/dev/null || true
    capture_changed_files "$BASE"
  ) > "$DEDUPE_DIR/out.json" 2>/dev/null
  DEDUPE_OUTPUT=$(cat "$DEDUPE_DIR/out.json")
  DEDUPE_COUNT=$(echo "$DEDUPE_OUTPUT" | jq -r '[.[] | select(.path == "dual.txt")] | length')
  assert_eq "Option D: dedupe — committed + further-modified path appears exactly once" \
    "1" \
    "$DEDUPE_COUNT"
  # And the diff should reflect the FINAL working-tree state (not the
  # intermediate committed value).
  DEDUPE_DIFF=$(echo "$DEDUPE_OUTPUT" | jq -r '.[] | select(.path == "dual.txt") | .diff')
  assert_contains "Option D: dedupe — diff reflects final working-tree content" \
    "+v3-uncommitted-on-top" \
    "$DEDUPE_DIFF"
  rm -rf "$DEDUPE_DIR"
fi

# ============================================================
# Summary
# ============================================================
echo ""
echo "========================================"
TOTAL=$((PASS + FAIL))
echo "Results: $PASS passed, $FAIL failed (out of $TOTAL)"
echo "========================================"

[ "$FAIL" -eq 0 ] && exit 0 || exit 1
