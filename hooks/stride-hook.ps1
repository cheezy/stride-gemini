# stride-hook.ps1 — Bridges Gemini CLI hooks to Stride .stride.md hook execution
#
# PowerShell companion to stride-hook.sh for Windows compatibility.
# Called by Gemini CLI's BeforeTool/AfterTool hooks (configured in hooks.json).
# Receives hook JSON on stdin, determines if the shell command is a Stride API call,
# and if so, parses and executes the corresponding .stride.md section.
#
# IMPORTANT: Gemini CLI requires JSON-only stdout. All debug/progress output
# must go to stderr via Write-Host or [Console]::Error. Only the final
# structured JSON result goes to stdout via Write-Output.
#
# Usage: echo '{"tool_input":{"command":"curl ..."}}' | pwsh stride-hook.ps1 <pre|post>
#
# Exit codes:
#   0 — Success (or not a Stride API call)
#   2 — Hook command failed (blocks the tool call in BeforeTool context)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Arguments and paths ---
$Phase = if ($args.Count -gt 0) { $args[0] } else { '' }
$ProjectDir = if ($env:GEMINI_PROJECT_DIR) { $env:GEMINI_PROJECT_DIR } elseif ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { '.' }
$StrideMd = Join-Path $ProjectDir '.stride.md'
$EnvCache = Join-Path $ProjectDir '.stride-env-cache'

# Exit early if no phase argument or no .stride.md
if (-not $Phase) { exit 0 }
if (-not (Test-Path $StrideMd)) { exit 0 }

# Read Gemini CLI hook input from stdin.
# Use $RawInput rather than $Input: $input is a PowerShell automatic variable
# and assigning to it is fragile under Set-StrictMode.
$RawInput = @($input) -join "`n"
if (-not $RawInput) { exit 0 }

# --- Extract the Bash command from hook JSON ---
$Command = ''
try {
    $json = $RawInput | ConvertFrom-Json
    $Command = $json.tool_input.command
} catch {
    # Fallback: simple string extraction for "command" : "value"
    if ($RawInput -match '"command"\s*:\s*"([^"]*)"') {
        $Command = $Matches[1]
    }
}

if (-not $Command) { exit 0 }

# --- Determine which Stride hook to run ---
# Routing:
#   post + /api/tasks/claim        → before_doing
#   pre  + /api/tasks/:id/complete → after_doing  (blocks completion if it fails)
#   post + /api/tasks/:id/complete → before_review
#   post + /api/tasks/:id/mark_reviewed → after_review

$HookName = ''

switch ($Phase) {
    'post' {
        if ($Command -match '/api/tasks/claim') {
            $HookName = 'before_doing'
        } elseif ($Command -match '/api/tasks/[^/]+/mark_reviewed') {
            $HookName = 'after_review'
        } elseif ($Command -match '/api/tasks/[^/]+/complete') {
            $HookName = 'before_review'
        }
    }
    'pre' {
        if ($Command -match '/api/tasks/[^/]+/complete') {
            $HookName = 'after_doing'
        }
    }
}

# Not a Stride API call — exit cleanly
if (-not $HookName) { exit 0 }

# --- Environment variable caching ---
# After a successful claim (before_doing), extract task metadata from the API
# response and cache it. All subsequent hooks load the cache so .stride.md
# commands can reference $TASK_IDENTIFIER, $TASK_TITLE, etc.

if ($HookName -eq 'before_doing') {
    try {
        $json = $RawInput | ConvertFrom-Json
        $response = $json.tool_response
        if ($response) {
            $taskJson = $null

            # Shape 1: host wraps API JSON inside tool_response.stdout as a string
            if ($response -is [PSCustomObject] -and $response.PSObject.Properties.Name -contains 'stdout') {
                try {
                    $innerObj = $response.stdout | ConvertFrom-Json
                    if ($innerObj.data -and $innerObj.data.id) {
                        $taskJson = $innerObj.data
                    } elseif ($innerObj.id) {
                        $taskJson = $innerObj
                    }
                } catch {
                    # stdout not parseable — fall through
                }
            }

            # Shape 2: tool_response is a JSON-encoded string
            if (-not $taskJson -and $response -is [string]) {
                try {
                    $responseObj = $response | ConvertFrom-Json
                    if ($responseObj.data -and $responseObj.data.id) {
                        $taskJson = $responseObj.data
                    } elseif ($responseObj.id) {
                        $taskJson = $responseObj
                    }
                } catch {
                    # Response not parseable JSON — skip caching
                }
            }

            # Shape 3: tool_response is raw API JSON object
            if (-not $taskJson -and $response -is [PSCustomObject]) {
                if ($response.data -and $response.data.id) {
                    $taskJson = $response.data
                } elseif ($response.PSObject.Properties.Name -contains 'id' -and $response.id) {
                    $taskJson = $response
                }
            }

            if ($taskJson) {
                $cacheLines = @(
                    "TASK_ID=$($taskJson.id)"
                    "TASK_IDENTIFIER=$($taskJson.identifier)"
                    "TASK_TITLE=$($taskJson.title)"
                    "TASK_STATUS=$($taskJson.status)"
                    "TASK_COMPLEXITY=$($taskJson.complexity)"
                    "TASK_PRIORITY=$($taskJson.priority)"
                )
                $cacheLines | Set-Content -Path $EnvCache -Encoding UTF8
            }
        }
    } catch {
        # Caching failure is non-fatal
    }
}

# Load cached env vars if available (all hooks benefit from this)
if (Test-Path $EnvCache) {
    Get-Content $EnvCache -Encoding UTF8 | ForEach-Object {
        $line = $_.Trim()
        if ($line -and $line -match '^([^=]+)=(.*)$') {
            [System.Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
        }
    }
}

# Helper: resolve the Stride API base URL for the changed_files upload.
# Primary source is $ProjectDir/.stride_auth.md (the same file the agent reads)
# — its `**API URL:**` line. Falls back to a literal URL in the intercepted
# $Command for back-compat when the auth file is absent. Mirror of
# stride-hook.sh:resolve_stride_api_url.
function Resolve-StrideApiUrl {
    $url = ''
    $authPath = Join-Path $ProjectDir '.stride_auth.md'
    if (Test-Path $authPath) {
        foreach ($line in (Get-Content -Path $authPath)) {
            if ($line -match '\*\*API URL:\*\*' -and $line -match '(https?://[A-Za-z0-9._:/-]+)') {
                $url = $Matches[1]; break
            }
        }
    }
    if (-not $url -and $Command -match '(https?://[A-Za-z0-9._-]+(:[0-9]+)?)') { $url = $Matches[1] }
    return $url
}

# Helper: resolve the Stride API bearer token for the changed_files upload.
# Primary source is the production `**API Token:**` line in
# $ProjectDir/.stride_auth.md — deliberately NOT the `**Local API Token:**`
# line (the `**API Token:**` pattern does not match `**Local API Token:**`).
# Falls back to a literal `Bearer <token>` in the intercepted $Command. Never
# logs the token. Mirror of stride-hook.sh:resolve_stride_api_token.
function Resolve-StrideApiToken {
    $token = ''
    $authPath = Join-Path $ProjectDir '.stride_auth.md'
    if (Test-Path $authPath) {
        foreach ($line in (Get-Content -Path $authPath)) {
            if ($line -match '\*\*API Token:\*\*' -and $line -match '`([^`]+)`') {
                $token = $Matches[1]; break
            }
        }
    }
    if (-not $token -and $Command -match 'Bearer\s+([A-Za-z0-9._+/=-]+)') { $token = $Matches[1] }
    return $token
}

# Fire-and-forget upload of the per-file diff snapshot to the Stride server.
# Mirror of stride-hook.sh's finalize_after_doing PUT path. URL and token are
# resolved by Resolve-StrideApiUrl / Resolve-StrideApiToken — preferring
# $ProjectDir/.stride_auth.md so the upload works whether the agent's completion
# curl used literal values or shell variables, with the $Command literal
# extraction kept as a back-compat fallback. Silently no-ops if any prerequisite
# is missing (snapshot file, URL, token, TASK_ID) so behavior degrades to the
# legacy on-disk-only snapshot.
function Invoke-FinalizeAfterDoing {
    if ($HookName -ne 'after_doing') { return }
    $snapshotPath = Join-Path $ProjectDir '.stride-changed-files.json'
    if (-not (Test-Path $snapshotPath)) { return }

    $apiBase = Resolve-StrideApiUrl
    $token = Resolve-StrideApiToken

    $taskId = [System.Environment]::GetEnvironmentVariable('TASK_ID', 'Process')
    if (-not $apiBase -or -not $token -or -not $taskId) { return }

    try {
        # Wrap the bare snapshot array as {"changed_files": [...]} so the
        # server's params['changed_files'] receives the list. A bare top-level
        # array would land at params['_json'] under Plug.Parsers and persist
        # as NULL. Construct via hashtable + ConvertTo-Json so PowerShell
        # handles JSON escaping itself rather than relying on string concat.
        $snapshotData = Get-Content -Raw -Path $snapshotPath | ConvertFrom-Json
        if ($null -eq $snapshotData) { $snapshotData = @() }
        $body = @{ changed_files = @($snapshotData) } | ConvertTo-Json -Depth 100 -Compress
        Invoke-WebRequest `
            -Uri "$apiBase/api/tasks/$taskId/changed_files" `
            -Method Put `
            -Body $body `
            -ContentType 'application/json' `
            -Headers @{ Authorization = "Bearer $token" } `
            -UseBasicParsing -TimeoutSec 10 -ErrorAction SilentlyContinue | Out-Null
    } catch {
        # Fire-and-forget — swallow all errors.
    }
}

# --- Parse and execute one .stride.md hook section ---
# Mirror of stride-hook.sh:run_stride_section. Takes a section name and
# returns 0 on no-op / all-success, 2 on first failure. Emits structured
# success/failed JSON via [Console]::Out.WriteLine so the function's
# return value stays a clean int (PowerShell function output otherwise
# collects pipeline writes into the caller's variable, which would
# pollute `$rc = Invoke-StrideSection ...` and break the -ne 0 gate).
# Get-Content reads wrapped in @() so .Count is safe under
# Set-StrictMode -Version Latest when commands produce no output.
function Invoke-StrideSection {
    param([string]$Section)

    $rawContent = Get-Content $StrideMd -Raw -Encoding UTF8
    $rawContent = $rawContent -replace "`r`n", "`n"
    $sectionLines = $rawContent -split "`n"

    $secCommands = ''
    $secFound = $false
    $secCapture = $false

    foreach ($rawLine in $sectionLines) {
        $line = $rawLine.TrimEnd("`r")

        if ($line -match '^## (.+)$') {
            if ($secFound) { break }
            $heading = $Matches[1].TrimEnd()
            if ($heading -eq $Section) { $secFound = $true }
            continue
        }

        if ($secFound) {
            if ($line -match '^```bash') {
                $secCapture = $true
                continue
            }
            if ($line -match '^```') {
                if ($secCapture) { break }
                continue
            }
            if ($secCapture) {
                $secCommands += $line + "`n"
            }
        }
    }

    if (-not $secCommands.Trim()) {
        Invoke-FinalizeAfterDoing
        return 0
    }

    $secCmdList = @()
    foreach ($cmd in ($secCommands -split "`n")) {
        $trimmedCmd = $cmd.TrimStart()
        if (-not $trimmedCmd) { continue }
        if ($trimmedCmd.StartsWith('#')) { continue }
        $secCmdList += $trimmedCmd
    }

    if ($secCmdList.Count -eq 0) {
        Invoke-FinalizeAfterDoing
        return 0
    }

    Set-Location $ProjectDir
    $secCompletedCmds = @()
    $secStartTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $secCmdIndex = 0
    $secCmdTotal = $secCmdList.Count

    foreach ($execTrimmed in $secCmdList) {
        $secStdoutFile = [System.IO.Path]::GetTempFileName()
        $secStderrFile = [System.IO.Path]::GetTempFileName()

        try {
            $proc = Start-Process -FilePath 'bash' -ArgumentList '-c', $execTrimmed `
                -RedirectStandardOutput $secStdoutFile `
                -RedirectStandardError $secStderrFile `
                -NoNewWindow -Wait -PassThru

            if ($proc.ExitCode -eq 0) {
                $secCompletedCmds += $execTrimmed
                if (Test-Path $secStdoutFile) {
                    $secStdout = Get-Content $secStdoutFile -Raw -Encoding UTF8
                    if ($secStdout) { [Console]::Error.Write($secStdout) }
                }
                if (Test-Path $secStderrFile) {
                    $secStderr = Get-Content $secStderrFile -Raw -Encoding UTF8
                    if ($secStderr) { [Console]::Error.Write($secStderr) }
                }
            } else {
                $secCmdExit = $proc.ExitCode
                $secCmdStdout = ''
                $secCmdStderr = ''
                if (Test-Path $secStdoutFile) {
                    $allLines = @(Get-Content $secStdoutFile -Encoding UTF8)
                    if ($allLines.Count -gt 50) { $allLines = $allLines[-50..-1] }
                    $secCmdStdout = $allLines -join "`n"
                }
                if (Test-Path $secStderrFile) {
                    $allLines = @(Get-Content $secStderrFile -Encoding UTF8)
                    if ($allLines.Count -gt 50) { $allLines = $allLines[-50..-1] }
                    $secCmdStderr = $allLines -join "`n"
                }
                Remove-Item -Force $secStdoutFile, $secStderrFile -ErrorAction SilentlyContinue

                $secRemainingCmds = @()
                if (($secCmdIndex + 1) -lt $secCmdTotal) {
                    $secRemainingCmds = $secCmdList[($secCmdIndex + 1)..($secCmdTotal - 1)]
                }

                $failureResult = [ordered]@{
                    hook              = $Section
                    status            = 'failed'
                    failed_command    = $execTrimmed
                    command_index     = $secCmdIndex
                    exit_code         = $secCmdExit
                    stdout            = $secCmdStdout
                    stderr            = $secCmdStderr
                    commands_completed = $secCompletedCmds
                    commands_remaining = $secRemainingCmds
                }
                [Console]::Out.WriteLine(($failureResult | ConvertTo-Json -Depth 5 -Compress))

                [Console]::Error.WriteLine("Stride $Section hook failed on command $($secCmdIndex + 1)/$($secCmdTotal): $execTrimmed")
                if ($secCmdStderr) { [Console]::Error.WriteLine($secCmdStderr) }

                return 2
            }
        } finally {
            Remove-Item -Force $secStdoutFile, $secStderrFile -ErrorAction SilentlyContinue
        }

        $secCmdIndex++
    }

    # Per-file diff snapshot PUT — no-op outside after_doing (gates on the
    # GLOBAL $HookName, so calling this for "after_goal" does not retrigger).
    Invoke-FinalizeAfterDoing

    $secEndTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $secDuration = $secEndTime - $secStartTime

    $successResult = [ordered]@{
        hook               = $Section
        status             = 'success'
        commands_completed = $secCompletedCmds
        duration_seconds   = $secDuration
    }
    [Console]::Out.WriteLine(($successResult | ConvertTo-Json -Depth 5 -Compress))

    return 0
}

# Detect an `after_goal` entry in the response's `hooks` array. Handles
# Gemini's wrapped form (`tool_response.stdout` is a JSON string),
# the raw-API-JSON form, and the JSON-encoded-string form. Returns
# $true when an entry with name == "after_goal" is found, $false otherwise.
function Test-AfterGoalInResponse {
    param([string]$InputJson)

    if (-not $InputJson) { return $false }

    try {
        $parsed = $InputJson | ConvertFrom-Json
    } catch {
        return $false
    }

    if ($parsed.PSObject.Properties.Name -notcontains 'tool_response') {
        return $false
    }

    $resp = $parsed.tool_response
    if (-not $resp) { return $false }

    $payload = $null

    if ($resp -is [PSCustomObject] -and $resp.PSObject.Properties.Name -contains 'stdout') {
        try { $payload = $resp.stdout | ConvertFrom-Json } catch { $payload = $null }
    }

    if ($null -eq $payload -and $resp -is [string]) {
        try { $payload = $resp | ConvertFrom-Json } catch { $payload = $null }
    }

    if ($null -eq $payload -and $resp -is [PSCustomObject]) {
        $payload = $resp
    }

    if ($null -eq $payload) { return $false }
    if (-not ($payload.PSObject.Properties.Name -contains 'hooks')) { return $false }
    if ($null -eq $payload.hooks) { return $false }

    foreach ($entry in @($payload.hooks)) {
        if ($entry -and ($entry.PSObject.Properties.Name -contains 'name') -and $entry.name -eq 'after_goal') {
            return $true
        }
    }

    return $false
}

# --- Execute the primary hook ---
$primaryRc = Invoke-StrideSection -Section $HookName

if ($primaryRc -ne 0) {
    exit $primaryRc
}

# --- After-goal routing (W784 / mirrors stride v1.17.1 W505) ---
# When the server bundles an `after_goal` entry in the response of /complete
# or /mark_reviewed, run the local `## after_goal` section as a blocking
# hook. Missing `## after_goal` is a clean no-op (back-compat). $null =
# swallows the int return; the JSON the function emits via
# [Console]::Out.WriteLine still reaches the script's stdout for the agent
# to forward via PATCH /api/tasks/:goal_id/after_goal.
if ($Phase -eq 'post' -and ($Command -match '/api/tasks/[^/]+/(complete|mark_reviewed)')) {
    if (Test-AfterGoalInResponse -InputJson $RawInput) {
        $null = Invoke-StrideSection -Section 'after_goal'
    }
}

# Clean up per-lifecycle state after the final hook. after_goal piggy-backs
# on after_review when present, so this gate stays on $HookName ==
# 'after_review'. Mirrors stride-hook.sh, which removes both the env cache and
# the changed-files snapshot here.
if ($HookName -eq 'after_review') {
    Remove-Item -Force $EnvCache -ErrorAction SilentlyContinue
    Remove-Item -Force (Join-Path $ProjectDir '.stride-changed-files.json') -ErrorAction SilentlyContinue
}

exit 0
