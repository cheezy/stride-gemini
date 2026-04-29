#!/usr/bin/env bash
# test-stride-skill-gate.sh — tests for stride-skill-gate.sh (Gemini variant)
#
# Each test creates an isolated temp project dir, optionally writes a marker,
# pipes a Gemini BeforeTool(activate_skill) fixture into the gate, and asserts
# on exit code and stdout.
#
# Run: bash test-stride-skill-gate.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GATE="$SCRIPT_DIR/stride-skill-gate.sh"

if [ ! -x "$GATE" ]; then
  echo "FATAL: $GATE is not executable" >&2
  exit 1
fi

PASS=0
FAIL=0
RED=$(printf '\033[31m')
GREEN=$(printf '\033[32m')
RESET=$(printf '\033[0m')

assert_exit() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "${GREEN}PASS${RESET} $label (exit=$actual)"
    PASS=$((PASS+1))
  else
    echo "${RED}FAIL${RESET} $label (expected exit=$expected, got=$actual)"
    FAIL=$((FAIL+1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    echo "${GREEN}PASS${RESET} $label (stdout contains '$needle')"
    PASS=$((PASS+1))
  else
    echo "${RED}FAIL${RESET} $label (stdout missing '$needle')"
    echo "  stdout: $haystack"
    FAIL=$((FAIL+1))
  fi
}

assert_empty() {
  local label="$1" actual="$2"
  if [ -z "$actual" ]; then
    echo "${GREEN}PASS${RESET} $label (no output)"
    PASS=$((PASS+1))
  else
    echo "${RED}FAIL${RESET} $label (expected empty, got: $actual)"
    FAIL=$((FAIL+1))
  fi
}

# Portable "5 hours ago" in ISO8601-Z form
five_hours_ago_iso() {
  date -u -v-5H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d '5 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

write_marker() {
  local proj="$1" started="$2"
  mkdir -p "$proj/.stride"
  printf '{"session_id":"test","started_at":"%s","pid":12345}\n' "$started" \
    > "$proj/.stride/.orchestrator_active"
}

run_gate() {
  # Args: <project_dir> <skill_name> [allow_direct=1]
  local proj="$1" skill="$2" allow_direct="${3:-}"
  local input
  # Gemini BeforeTool fixture: tool_name=activate_skill, tool_input.name=<skill>,
  # cwd=<proj>. The gate prefers stdin cwd; CLAUDE_PROJECT_DIR is set as a
  # fallback so the gate works even if cwd extraction fails (e.g. no jq).
  input=$(printf '{"tool_name":"activate_skill","cwd":"%s","tool_input":{"name":"%s"}}' "$proj" "$skill")
  if [ "$allow_direct" = "1" ]; then
    STRIDE_ALLOW_DIRECT=1 CLAUDE_PROJECT_DIR="$proj" \
      bash "$GATE" <<<"$input" 2>/dev/null
  else
    CLAUDE_PROJECT_DIR="$proj" bash "$GATE" <<<"$input" 2>/dev/null
  fi
}

# --- Tests ---

test_marker_missing_blocks() {
  local proj
  proj=$(mktemp -d)
  local out ec
  out=$(run_gate "$proj" "stride-claiming-tasks") || ec=$?
  ec=${ec:-0}
  assert_exit "marker missing → blocks claiming" 2 "$ec"
  assert_contains "marker missing → block JSON on stdout" '"decision":"block"' "$out"
  rm -rf "$proj"
}

test_marker_fresh_allows() {
  local proj
  proj=$(mktemp -d)
  write_marker "$proj" "$(now_iso)"
  local out ec
  out=$(run_gate "$proj" "stride-claiming-tasks") || ec=$?
  ec=${ec:-0}
  assert_exit "marker fresh → allows claiming" 0 "$ec"
  assert_empty "marker fresh → silent stdout" "$out"
  rm -rf "$proj"
}

test_marker_stale_blocks() {
  local proj
  proj=$(mktemp -d)
  local stale
  stale=$(five_hours_ago_iso)
  if [ -z "$stale" ]; then
    echo "${RED}SKIP${RESET} marker stale → cannot compute 5h-ago timestamp on this platform"
    rm -rf "$proj"
    return
  fi
  write_marker "$proj" "$stale"
  local out ec
  out=$(run_gate "$proj" "stride-claiming-tasks") || ec=$?
  ec=${ec:-0}
  assert_exit "marker stale (5h) → blocks claiming" 2 "$ec"
  assert_contains "marker stale → 'stale' in reason" 'stale' "$out"
  rm -rf "$proj"
}

test_stride_workflow_always_allowed() {
  local proj
  proj=$(mktemp -d)
  # No marker — orchestrator itself must still pass.
  local out ec
  out=$(run_gate "$proj" "stride-workflow") || ec=$?
  ec=${ec:-0}
  assert_exit "stride-workflow with no marker → allowed" 0 "$ec"
  assert_empty "stride-workflow → silent stdout" "$out"

  # Plugin-namespaced form too.
  out=$(run_gate "$proj" "stride:stride-workflow") || ec=$?
  ec=${ec:-0}
  assert_exit "stride:stride-workflow with no marker → allowed" 0 "$ec"
  rm -rf "$proj"
}

test_non_stride_skill_always_allowed() {
  local proj
  proj=$(mktemp -d)
  # No marker, non-Stride skill — must pass through silently.
  local out ec
  out=$(run_gate "$proj" "superpowers:brainstorming") || ec=$?
  ec=${ec:-0}
  assert_exit "non-Stride skill (no marker) → allowed" 0 "$ec"
  assert_empty "non-Stride skill → silent stdout" "$out"

  # Plain skill name without colon prefix
  out=$(run_gate "$proj" "frontend-design") || ec=$?
  ec=${ec:-0}
  assert_exit "non-Stride bare skill → allowed" 0 "$ec"
  rm -rf "$proj"
}

test_allow_direct_env_bypasses() {
  local proj
  proj=$(mktemp -d)
  # No marker, but STRIDE_ALLOW_DIRECT=1 → must allow protected skill.
  local out ec
  out=$(run_gate "$proj" "stride-claiming-tasks" "1") || ec=$?
  ec=${ec:-0}
  assert_exit "STRIDE_ALLOW_DIRECT=1 → bypass" 0 "$ec"
  assert_empty "STRIDE_ALLOW_DIRECT=1 → silent stdout" "$out"
  rm -rf "$proj"
}

test_plugin_namespaced_name_gated() {
  local proj
  proj=$(mktemp -d)
  # No marker, plugin-namespaced protected skill → must block.
  local out ec
  out=$(run_gate "$proj" "stride:stride-claiming-tasks") || ec=$?
  ec=${ec:-0}
  assert_exit "stride:stride-claiming-tasks (no marker) → blocked" 2 "$ec"
  assert_contains "namespaced block → 'decision' in stdout" '"decision":"block"' "$out"
  rm -rf "$proj"
}

# --- Execute ---

echo "Running stride-skill-gate.sh tests (Gemini variant)..."
echo
test_marker_missing_blocks
test_marker_fresh_allows
test_marker_stale_blocks
test_stride_workflow_always_allowed
test_non_stride_skill_always_allowed
test_allow_direct_env_bypasses
test_plugin_namespaced_name_gated

echo
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
