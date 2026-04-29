# stride-skill-gate.ps1 — BeforeTool(activate_skill) gate for Stride sub-skills.
#
# PowerShell companion to stride-skill-gate.sh for native Windows.
# Blocks direct activations of internal Stride sub-skills unless the
# stride-workflow orchestrator wrote an activation marker at
# <project-root>/.stride/.orchestrator_active
#
# Project-root resolution: prefer the `cwd` field on the BeforeTool stdin JSON,
# then fall back to $env:GEMINI_PROJECT_DIR -> $env:CLAUDE_PROJECT_DIR -> '.'.
#
# Marker shape: {"session_id":"<id>","started_at":"<ISO8601-Z>","pid":<int>}
# Marker is "fresh" if started_at is within the last 4 hours.
#
# Usage: echo '{"tool_input":{"name":"stride-claiming-tasks"},"cwd":"."}' | pwsh stride-skill-gate.ps1
#
# Exit codes:
#   0 — allowed
#   2 — blocked

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Override: bypass entirely for plugin debugging / scripted CI ---
if ($env:STRIDE_ALLOW_DIRECT -eq '1') { exit 0 }

# --- Read stdin ---
$rawInput = @($input) -join "`n"
if (-not $rawInput) { exit 0 }

# --- Parse the BeforeTool payload ---
$skill = ''
$cwdField = ''
try {
    $obj = $rawInput | ConvertFrom-Json
    if ($obj.PSObject.Properties.Match('tool_input').Count -gt 0 -and
        $obj.tool_input.PSObject.Properties.Match('name').Count -gt 0) {
        $skill = [string]$obj.tool_input.name
    }
    if ($obj.PSObject.Properties.Match('cwd').Count -gt 0) {
        $cwdField = [string]$obj.cwd
    }
} catch {
    # Regex fallback: scope to tool_input first to avoid matching tool_name etc.
    $afterToolInput = ''
    if ($rawInput -match '"tool_input"\s*:\s*\{([^}]*)') {
        $afterToolInput = $Matches[1]
    }
    if ($afterToolInput -match '"name"\s*:\s*"([^"]*)"') {
        $skill = $Matches[1]
    }
    if ($rawInput -match '"cwd"\s*:\s*"([^"]*)"') {
        $cwdField = $Matches[1]
    }
}

if (-not $skill) { exit 0 }

# --- Normalize: strip optional plugin prefix ---
$baseName = $skill -replace '^stride:', ''

# --- Allow-list short circuit ---
if ($baseName -eq 'stride-workflow') { exit 0 }

$protected = @(
    'stride-claiming-tasks',
    'stride-completing-tasks',
    'stride-creating-tasks',
    'stride-creating-goals',
    'stride-enriching-tasks',
    'stride-subagent-workflow'
)

if ($protected -notcontains $baseName) { exit 0 }

# --- Block helper ---
function Emit-Block {
    param([string]$Reason)
    $payload = [ordered]@{ decision = 'block'; reason = $Reason }
    Write-Output ($payload | ConvertTo-Json -Compress)
    [Console]::Error.WriteLine("stride-skill-gate: $Reason")
    exit 2
}

# --- Resolve project root: stdin cwd > env-var fallback chain ---
$projectDir = $null
if ($cwdField) {
    $projectDir = $cwdField
} elseif ($env:GEMINI_PROJECT_DIR) {
    $projectDir = $env:GEMINI_PROJECT_DIR
} elseif ($env:CLAUDE_PROJECT_DIR) {
    $projectDir = $env:CLAUDE_PROJECT_DIR
} else {
    $projectDir = '.'
}

$markerPath = Join-Path $projectDir '.stride/.orchestrator_active'

if (-not (Test-Path $markerPath)) {
    Emit-Block "Stride sub-skill '$skill' can only be activated from inside stride:stride-workflow. Activate stride:stride-workflow first; the orchestrator will dispatch this skill at the appropriate phase. (Set STRIDE_ALLOW_DIRECT=1 to bypass.)"
}

# --- Read started_at ---
$started = ''
try {
    $markerContent = Get-Content -Raw -ErrorAction Stop $markerPath
    $markerObj = $markerContent | ConvertFrom-Json
    if ($markerObj.PSObject.Properties.Match('started_at').Count -gt 0) {
        $started = [string]$markerObj.started_at
    }
} catch {
    Emit-Block "Stride orchestrator marker at '$markerPath' is unparseable. Re-activate stride:stride-workflow to refresh."
}

if (-not $started) {
    Emit-Block "Stride orchestrator marker is invalid (missing or empty started_at). Re-activate stride:stride-workflow to refresh."
}

# --- Freshness check (PowerShell parses ISO8601 cleanly) ---
$startedDt = $null
try {
    $startedDt = [datetime]::Parse($started, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
} catch {
    Emit-Block "Stride orchestrator marker has unparseable started_at ('$started'). Re-activate stride:stride-workflow to refresh."
}

$age = ([datetime]::UtcNow - $startedDt).TotalSeconds
if ($age -lt 0 -or $age -gt 14400) {
    $ageInt = [int]$age
    Emit-Block "Stride orchestrator marker is stale or in the future (age ${ageInt}s; max 14400s). Re-activate stride:stride-workflow to refresh."
}

# --- Allowed ---
exit 0
