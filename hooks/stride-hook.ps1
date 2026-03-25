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

# Read Claude Code hook input from stdin
$Input = @($input) -join "`n"
if (-not $Input) { exit 0 }

# --- Extract the Bash command from hook JSON ---
$Command = ''
try {
    $json = $Input | ConvertFrom-Json
    $Command = $json.tool_input.command
} catch {
    # Fallback: simple string extraction for "command" : "value"
    if ($Input -match '"command"\s*:\s*"([^"]*)"') {
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
        $json = $Input | ConvertFrom-Json
        $response = $json.tool_response
        if ($response) {
            $taskJson = $null
            try {
                $responseObj = $response | ConvertFrom-Json
                if ($responseObj.data.id) {
                    $taskJson = $responseObj.data
                } elseif ($responseObj.id) {
                    $taskJson = $responseObj
                }
            } catch {
                # Response is not parseable JSON — skip caching
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

# --- Parse .stride.md for the hook section ---
# Extracts lines from the first ```bash code block under ## <hook_name>
$rawContent = Get-Content $StrideMd -Raw -Encoding UTF8
# Normalize line endings
$rawContent = $rawContent -replace "`r`n", "`n"
$lines = $rawContent -split "`n"

$commands = ''
$found = $false
$capture = $false

foreach ($rawLine in $lines) {
    $line = $rawLine.TrimEnd("`r")

    # Check for ## heading
    if ($line -match '^## (.+)$') {
        if ($found) { break }
        $section = $Matches[1].TrimEnd()
        if ($section -eq $HookName) { $found = $true }
        continue
    }

    if ($found) {
        if ($line -match '^```bash') {
            $capture = $true
            continue
        }
        if ($line -match '^```') {
            if ($capture) { break }
            continue
        }
        if ($capture) {
            $commands += $line + "`n"
        }
    }
}

# No commands for this hook — exit cleanly
if (-not $commands.Trim()) { exit 0 }

# --- Build command list for tracking ---
# Split commands, filter comments and blank lines
$cmdList = @()
foreach ($cmd in ($commands -split "`n")) {
    $trimmed = $cmd.TrimStart()
    if (-not $trimmed) { continue }
    if ($trimmed.StartsWith('#')) { continue }
    $cmdList += $trimmed
}

# Nothing to execute after filtering
if ($cmdList.Count -eq 0) { exit 0 }

# --- Execute commands with structured output ---
Set-Location $ProjectDir
$completedCmds = @()
$startTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$cmdIndex = 0
$cmdTotal = $cmdList.Count

foreach ($trimmed in $cmdList) {
    $cmdStdoutFile = [System.IO.Path]::GetTempFileName()
    $cmdStderrFile = [System.IO.Path]::GetTempFileName()

    try {
        # Execute command, capturing stdout and stderr to temp files
        $proc = Start-Process -FilePath 'bash' -ArgumentList '-c', $trimmed `
            -RedirectStandardOutput $cmdStdoutFile `
            -RedirectStandardError $cmdStderrFile `
            -NoNewWindow -Wait -PassThru

        if ($proc.ExitCode -eq 0) {
            $completedCmds += $trimmed
            # Print command output to stderr so Claude sees it as feedback
            if (Test-Path $cmdStdoutFile) {
                $stdout = Get-Content $cmdStdoutFile -Raw -Encoding UTF8
                if ($stdout) { [Console]::Error.Write($stdout) }
            }
            if (Test-Path $cmdStderrFile) {
                $stderr = Get-Content $cmdStderrFile -Raw -Encoding UTF8
                if ($stderr) { [Console]::Error.Write($stderr) }
            }
        } else {
            $cmdExit = $proc.ExitCode
            $cmdStdout = ''
            $cmdStderr = ''
            if (Test-Path $cmdStdoutFile) {
                $allLines = Get-Content $cmdStdoutFile -Encoding UTF8
                if ($allLines.Count -gt 50) { $allLines = $allLines[-50..-1] }
                $cmdStdout = $allLines -join "`n"
            }
            if (Test-Path $cmdStderrFile) {
                $allLines = Get-Content $cmdStderrFile -Encoding UTF8
                if ($allLines.Count -gt 50) { $allLines = $allLines[-50..-1] }
                $cmdStderr = $allLines -join "`n"
            }
            Remove-Item -Force $cmdStdoutFile, $cmdStderrFile -ErrorAction SilentlyContinue

            # Build remaining commands
            $remainingCmds = @()
            if (($cmdIndex + 1) -lt $cmdTotal) {
                $remainingCmds = $cmdList[($cmdIndex + 1)..($cmdTotal - 1)]
            }

            # Emit structured JSON on stdout for Claude to parse
            $failureResult = [ordered]@{
                hook              = $HookName
                status            = 'failed'
                failed_command    = $trimmed
                command_index     = $cmdIndex
                exit_code         = $cmdExit
                stdout            = $cmdStdout
                stderr            = $cmdStderr
                commands_completed = $completedCmds
                commands_remaining = $remainingCmds
            }
            $failureResult | ConvertTo-Json -Depth 5 -Compress

            # Human-readable error on stderr for Claude's feedback
            [Console]::Error.WriteLine("Stride $HookName hook failed on command $($cmdIndex + 1)/$($cmdTotal): $trimmed")
            if ($cmdStderr) { [Console]::Error.WriteLine($cmdStderr) }

            exit 2
        }
    } finally {
        Remove-Item -Force $cmdStdoutFile, $cmdStderrFile -ErrorAction SilentlyContinue
    }

    $cmdIndex++
}

# --- Success output ---
$endTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$duration = $endTime - $startTime

$successResult = [ordered]@{
    hook               = $HookName
    status             = 'success'
    commands_completed = $completedCmds
    duration_seconds   = $duration
}
$successResult | ConvertTo-Json -Depth 5 -Compress

# Clean up env cache after the final hook in the lifecycle
if ($HookName -eq 'after_review' -and (Test-Path $EnvCache)) {
    Remove-Item -Force $EnvCache -ErrorAction SilentlyContinue
}

exit 0
