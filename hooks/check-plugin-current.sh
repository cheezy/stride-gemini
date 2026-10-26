#!/usr/bin/env bash
# check-plugin-current.sh — stale-install check run once at Step 0 (W2465).
#
# Ports stride W2251 to the Gemini CLI. Gemini runs every custom agent and
# skill from the copy under its extensions directory, so a fix that has been
# published does nothing for a user whose installed copy is behind it — and the
# claim's skills_version is "1.0" on every release, so the server never notices.
# This script compares the two numbers and says so when the install is behind.
#
# WHAT IT READS
#   installed: the "version" string of gemini-extension.json in the directory
#              ABOVE this script's own hooks/ directory. In an installed
#              extension that is the extension root, the same directory
#              hooks.json reaches as ${extensionPath}. The script takes no
#              path argument; any argument is ignored.
#   published: the "version" of the entry named exactly "stride-gemini" in the
#              stride-gemini-marketplace catalog (a JSON array of
#              {name, version, repo, ...} objects), fetched once over HTTPS.
#
# WHAT IT PRINTS
#   One line, only when installed < published, naming both numbers and
#   `gemini extensions update stride-gemini`. In every other case — equal or
#   newer install, no manifest beside hooks/ (the README's copy-the-skills
#   install), a version that is not dotted numbers, no curl, no jq, a fetch that
#   fails or times out, a body that is not the expected array, or no
#   stride-gemini entry — it prints nothing. It never guesses a version.
#
# EXIT STATUS is always 0. This is information for the user, never a gate.
#
# SAFETY: the catalog URL is a constant here, not an input. The response is
# handed to jq as data and never evaluated or sourced, and the only text that
# can reach stdout is a string that already matched VERSION_RE. The request
# goes out without credentials of any kind; the catalog is a public file.
# The fetch is bounded (2s to connect, 3s overall), so a slow or hostile host
# cannot hold Step 0 up. -q comes first so no ~/.curlrc can add headers,
# credentials or redirects to the request.
#
# ORDERING is per dot-separated part, as integers (1.50.0 is newer than
# 1.9.0); a missing part counts as 0. A pre-release (1.51.0-rc.1) is older
# than its own release. Two pre-releases of the same release are left
# unordered, and unordered means no output.
#
# No pipes and no eval; the only external programs are curl and jq.

set -u

PIN_URL="https://raw.githubusercontent.com/cheezy/stride-gemini-marketplace/main/extensions.json"
UPDATE_CMD="gemini extensions update stride-gemini"
VERSION_RE='^[0-9]+(\.[0-9]+)*(-[0-9A-Za-z.-]+)?$'

# Echo the path of the manifest that should sit one level above this script's
# directory. Pure parameter expansion, so it needs no dirname binary.
manifest_path() {
  _src="${BASH_SOURCE[0]:-$0}"
  case "$_src" in
    */*) _dir="${_src%/*}" ;;
    *) _dir="." ;;
  esac
  printf '%s' "$_dir/../gemini-extension.json"
}

# Echo the installed version from a manifest file, or nothing.
installed_version() {
  jq -r 'if type == "object" and (.version | type) == "string" then .version else empty end' "$1" 2> /dev/null
}

# Read the catalog on stdin; echo the stride-gemini entry's version, or nothing.
published_version() {
  jq -r 'if type == "array" then (first(.[] | select(type == "object" and .name == "stride-gemini") | .version | select(type == "string")) // empty) else empty end' 2> /dev/null
}

# Succeed only if $1 sorts below $2; both arguments already match VERSION_RE.
version_older() {
  _a_core="${1%%-*}"; _b_core="${2%%-*}"
  _a_pre=""; _b_pre=""
  [ "$_a_core" != "$1" ] && _a_pre="${1#*-}"
  [ "$_b_core" != "$2" ] && _b_pre="${2#*-}"
  IFS=. read -r -a _a_parts <<< "$_a_core"
  IFS=. read -r -a _b_parts <<< "$_b_core"
  _n=${#_a_parts[@]}
  [ "${#_b_parts[@]}" -gt "$_n" ] && _n=${#_b_parts[@]}
  _i=0
  while [ "$_i" -lt "$_n" ]; do
    _x=$(( 10#${_a_parts[$_i]:-0} ))
    _y=$(( 10#${_b_parts[$_i]:-0} ))
    [ "$_x" -lt "$_y" ] && return 0
    [ "$_x" -gt "$_y" ] && return 1
    _i=$(( _i + 1 ))
  done
  # Same numbers: the only ordered case left is a pre-release against its release.
  [ -n "$_a_pre" ] && [ -z "$_b_pre" ] && return 0
  return 1
}

main() {
  command -v jq > /dev/null 2>&1 || return 0
  # A missing or unreadable manifest makes jq fail, which yields no version.
  _installed="$(installed_version "$(manifest_path)")"
  [[ "$_installed" =~ $VERSION_RE ]] || return 0
  command -v curl > /dev/null 2>&1 || return 0
  _body="$(curl -q -sS --proto '=https' --connect-timeout 2 --max-time 3 -A 'curl/stride-gemini-check' "$PIN_URL" 2> /dev/null)" || return 0
  [ -n "$_body" ] || return 0
  _published="$(published_version <<< "$_body")"
  [[ "$_published" =~ $VERSION_RE ]] || return 0
  if version_older "$_installed" "$_published"; then
    printf 'This stride-gemini extension is at %s; stride-gemini-marketplace lists %s. To catch up, run: %s\n' \
      "$_installed" "$_published" "$UPDATE_CMD"
  fi
  return 0
}

main "$@"
exit 0
