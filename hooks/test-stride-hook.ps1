# test-stride-hook.ps1 — Tests for stride-hook.ps1 PowerShell hook script
#
# Mirrors all 6 test groups from test-stride-hook.sh.
# Self-contained — no Pester or external dependencies.
#
# Usage: pwsh test-stride-hook.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PASS = 0
$script:FAIL = 0
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HookScript = Join-Path $ScriptDir 'stride-hook.ps1'

# --- Assertion helpers ---

function Assert-Eq {
    param([string]$Label, [string]$Expected, [string]$Actual)
    if ($Expected -eq $Actual) {
        Write-Host "  PASS: $Label" -ForegroundColor Green
        $script:PASS++
    } else {
        Write-Host "  FAIL: $Label" -ForegroundColor Red
        Write-Host "    expected: $($Expected.Substring(0, [Math]::Min(200, $Expected.Length)))"
        Write-Host "    actual:   $($Actual.Substring(0, [Math]::Min(200, $Actual.Length)))"
        $script:FAIL++
    }
}

function Assert-Contains {
    param([string]$Label, [string]$Needle, [string]$Haystack)
    if ($Haystack.Contains($Needle)) {
        Write-Host "  PASS: $Label" -ForegroundColor Green
        $script:PASS++
    } else {
        Write-Host "  FAIL: $Label" -ForegroundColor Red
        Write-Host "    expected to contain: $Needle"
        Write-Host "    actual: $($Haystack.Substring(0, [Math]::Min(200, $Haystack.Length)))"
        $script:FAIL++
    }
}

function Assert-NotContains {
    param([string]$Label, [string]$Needle, [string]$Haystack)
    if (-not $Haystack.Contains($Needle)) {
        Write-Host "  PASS: $Label" -ForegroundColor Green
        $script:PASS++
    } else {
        Write-Host "  FAIL: $Label" -ForegroundColor Red
        Write-Host "    expected NOT to contain: $Needle"
        $script:FAIL++
    }
}

function Assert-Exit {
    param([string]$Label, [int]$Expected, [int]$Actual)
    if ($Expected -eq $Actual) {
        Write-Host "  PASS: $Label (exit $Actual)" -ForegroundColor Green
        $script:PASS++
    } else {
        Write-Host "  FAIL: $Label" -ForegroundColor Red
        Write-Host "    expected exit: $Expected"
        Write-Host "    actual exit:   $Actual"
        $script:FAIL++
    }
}

# --- Helper: run stride-hook.ps1 with input and capture output ---
function Invoke-HookScript {
    param(
        [string]$InputJson,
        [string]$Phase,
        [string]$ProjectDir
    )
    $tempInput = [System.IO.Path]::GetTempFileName()
    $tempOutput = [System.IO.Path]::GetTempFileName()
    $tempError = [System.IO.Path]::GetTempFileName()
    try {
        Set-Content -Path $tempInput -Value $InputJson -Encoding UTF8 -NoNewline
        $envArgs = @{}
        if ($ProjectDir) {
            $envArgs['GEMINI_PROJECT_DIR'] = $ProjectDir
        }
        # Build environment block
        $envBlock = [System.Collections.Generic.Dictionary[string,string]]::new()
        foreach ($key in [System.Environment]::GetEnvironmentVariables('Process').Keys) {
            $envBlock[$key] = [System.Environment]::GetEnvironmentVariable($key, 'Process')
        }
        if ($ProjectDir) {
            $envBlock['GEMINI_PROJECT_DIR'] = $ProjectDir
        }

        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = 'pwsh'
        $psi.Arguments = "-NoProfile -File `"$HookScript`" $Phase"
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        foreach ($kv in $envBlock.GetEnumerator()) {
            $psi.Environment[$kv.Key] = $kv.Value
        }
        if ($ProjectDir) {
            $psi.Environment['GEMINI_PROJECT_DIR'] = $ProjectDir
        }

        $proc = [System.Diagnostics.Process]::Start($psi)
        $proc.StandardInput.Write($InputJson)
        $proc.StandardInput.Close()
        # Read stdout fully, then stderr, then WaitForExit (the canonical
        # harness order). A sync-over-async drain (ReadToEndAsync + .Result)
        # can deadlock under PowerShell's synchronization context as the suite
        # grows; the hooks never emit more than the ~64KB pipe buffer of stderr,
        # so the simple sequential ReadToEnd is both correct and reliable.
        $stdout = $proc.StandardOutput.ReadToEnd()
        $stderr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()

        return @{
            ExitCode = $proc.ExitCode
            Stdout   = $stdout
            Stderr   = $stderr
        }
    } finally {
        Remove-Item -Force $tempInput, $tempOutput, $tempError -ErrorAction SilentlyContinue
    }
}

# --- Helper: wait for a listener job to accept connections ---
# Start-Job spawns a whole pwsh process, so the HttpListener inside it can
# take longer to come up than the hook subprocess takes to fire its PUT.
# Poll the port until it accepts a TCP connection (or the timeout elapses)
# before invoking the hook, otherwise the PUT races the listener startup.
function Wait-ForListener {
    param([int]$Port, [int]$TimeoutSeconds = 10)
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            $client.Connect('localhost', $Port)
            if ($client.Connected) { return $true }
        } catch {
            Start-Sleep -Milliseconds 100
        } finally {
            $client.Dispose()
        }
    }
    return $false
}

# ============================================================
# Setup: create temp directory with test fixtures
# ============================================================
$TmpDir = Join-Path ([System.IO.Path]::GetTempPath()) "stride-ps-test-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null

try {

# --- Test .stride.md files ---

Set-Content -Path (Join-Path $TmpDir 'basic.stride.md') -Value @'
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
'@ -Encoding UTF8

Set-Content -Path (Join-Path $TmpDir 'with-comments.stride.md') -Value @'
## before_doing
```bash
# This is a comment
echo "step one"
   echo "indented step"
echo "step three"
# Another comment
```
'@ -Encoding UTF8

Set-Content -Path (Join-Path $TmpDir 'no-hook.stride.md') -Value @'
## before_doing
```bash
echo "only before_doing here"
```
'@ -Encoding UTF8

Set-Content -Path (Join-Path $TmpDir 'empty-block.stride.md') -Value @'
## after_doing
```bash
```
'@ -Encoding UTF8

Set-Content -Path (Join-Path $TmpDir 'multiple-code-blocks.stride.md') -Value @'
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
'@ -Encoding UTF8

Set-Content -Path (Join-Path $TmpDir 'no-bash-block.stride.md') -Value @'
## before_doing

Just some text, no code block.

## after_doing
```bash
echo "after_doing works"
```
'@ -Encoding UTF8

Set-Content -Path (Join-Path $TmpDir 'adjacent-sections.stride.md') -Value @'
## before_doing
```bash
echo "before"
```
## after_doing
```bash
echo "after"
```
'@ -Encoding UTF8

# ============================================================
# Test Group 1: JSON command extraction
# ============================================================
Write-Host ""
Write-Host "=== Test Group 1: JSON command extraction ==="

# We test extraction by providing JSON and checking if the script
# routes correctly (which proves the command was extracted).
# For isolated extraction tests, we check that non-Stride commands
# produce no output and exit 0.

$proj = Join-Path $TmpDir 'g1-project'
New-Item -ItemType Directory -Path $proj -Force | Out-Null
Copy-Item (Join-Path $TmpDir 'basic.stride.md') (Join-Path $proj '.stride.md')

# 1a: Standard claim command extracts correctly
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}' -Phase 'post' -ProjectDir $proj
Assert-Exit "standard claim URL exits 0" 0 $r.ExitCode
Assert-Contains "claim runs before_doing" "pulling latest" $r.Stdout

# 1b: Complete command extracts correctly
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/123/complete"}}' -Phase 'pre' -ProjectDir $proj
Assert-Exit "complete URL exits 0" 0 $r.ExitCode
Assert-Contains "pre-complete runs after_doing" "running tests" $r.Stdout

# 1c: No command key present
$r = Invoke-HookScript -InputJson '{"tool_input":{"other_key":"some value"}}' -Phase 'post' -ProjectDir $proj
Assert-Exit "no command key exits 0" 0 $r.ExitCode

# 1d: Empty command value
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":""}}' -Phase 'post' -ProjectDir $proj
Assert-Exit "empty command exits 0" 0 $r.ExitCode

# 1e: Completely unrelated JSON
$r = Invoke-HookScript -InputJson '{"foo":"bar","baz":42}' -Phase 'post' -ProjectDir $proj
Assert-Exit "unrelated JSON exits 0" 0 $r.ExitCode

# ============================================================
# Test Group 2: .stride.md section parser
# ============================================================
Write-Host ""
Write-Host "=== Test Group 2: .stride.md section parser ==="

$proj2 = Join-Path $TmpDir 'g2-project'
New-Item -ItemType Directory -Path $proj2 -Force | Out-Null

$ClaimJson = '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}'
$CompleteJson = '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}}'
$ReviewJson = '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/mark_reviewed"}}'

# 2a-d: Parse all 4 sections from basic file
Copy-Item (Join-Path $TmpDir 'basic.stride.md') (Join-Path $proj2 '.stride.md') -Force
$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $proj2
Assert-Contains "basic: before_doing line 1" 'pulling latest' $r.Stdout
Assert-Contains "basic: before_doing line 2" 'getting deps' $r.Stdout

$r = Invoke-HookScript -InputJson $CompleteJson -Phase 'pre' -ProjectDir $proj2
Assert-Contains "basic: after_doing line 1" 'running tests' $r.Stdout
Assert-Contains "basic: after_doing line 2" 'running credo' $r.Stdout

$r = Invoke-HookScript -InputJson $CompleteJson -Phase 'post' -ProjectDir $proj2
Assert-Contains "basic: before_review" 'creating pr' $r.Stdout

$r = Invoke-HookScript -InputJson $ReviewJson -Phase 'post' -ProjectDir $proj2
Assert-Contains "basic: after_review" 'deploying' $r.Stdout

# 2e: Sections don't bleed
$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $proj2
Assert-NotContains "sections do not bleed" 'running tests' $r.Stdout

# 2f: Hook not present in file
Copy-Item (Join-Path $TmpDir 'no-hook.stride.md') (Join-Path $proj2 '.stride.md') -Force
$r = Invoke-HookScript -InputJson $CompleteJson -Phase 'pre' -ProjectDir $proj2
Assert-Exit "missing hook exits 0" 0 $r.ExitCode

# 2g: Empty code block
Copy-Item (Join-Path $TmpDir 'empty-block.stride.md') (Join-Path $proj2 '.stride.md') -Force
$r = Invoke-HookScript -InputJson $CompleteJson -Phase 'pre' -ProjectDir $proj2
Assert-Exit "empty code block exits 0" 0 $r.ExitCode

# 2h: Only first code block captured
Copy-Item (Join-Path $TmpDir 'multiple-code-blocks.stride.md') (Join-Path $proj2 '.stride.md') -Force
$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $proj2
Assert-Contains "first block captured" 'first command' $r.Stdout
Assert-NotContains "second block ignored" 'should not appear' $r.Stdout

# 2i: Section with no bash block
Copy-Item (Join-Path $TmpDir 'no-bash-block.stride.md') (Join-Path $proj2 '.stride.md') -Force
$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $proj2
Assert-Exit "no bash block exits 0" 0 $r.ExitCode

# 2j: Adjacent sections
Copy-Item (Join-Path $TmpDir 'adjacent-sections.stride.md') (Join-Path $proj2 '.stride.md') -Force
# Command output (not the command text) is the observable here. Post-D65 the
# executed-command stdout is folded into the structured success JSON on stdout
# (the literal `echo "before"` with quotes never appears because the output of
# the echo — `before` — is what is captured, not the command text).
$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $proj2
Assert-Contains "adjacent: before_doing correct" 'before' $r.Stdout
Assert-NotContains "adjacent sections do not bleed" 'after' $r.Stdout

$r = Invoke-HookScript -InputJson $CompleteJson -Phase 'pre' -ProjectDir $proj2
Assert-Contains "adjacent: after_doing correct" 'after' $r.Stdout

# ============================================================
# Test Group 3: Whitespace trimming
# ============================================================
Write-Host ""
Write-Host "=== Test Group 3: Whitespace trimming ==="

# Test the TrimStart behavior used in command list building.
# NOTE: the parameter must not be named $Input — that is a reserved
# PowerShell automatic variable (the pipeline enumerator) and binding a
# param to it silently yields an empty value.
function Test-TrimStart {
    param([string]$Value)
    return $Value.TrimStart()
}

Assert-Eq "trim leading spaces" "echo hello" (Test-TrimStart "   echo hello")
Assert-Eq "trim leading tabs" "echo hello" (Test-TrimStart "`t`techo hello")
Assert-Eq "trim mixed whitespace" "echo hello" (Test-TrimStart "`t  `techo hello")
Assert-Eq "no trim needed" "echo hello" (Test-TrimStart "echo hello")
Assert-Eq "all whitespace becomes empty" "" (Test-TrimStart "   ")
Assert-Eq "empty string stays empty" "" (Test-TrimStart "")

# ============================================================
# Test Group 4: Command list building
# ============================================================
Write-Host ""
Write-Host "=== Test Group 4: Command list building ==="

# Test the filtering logic: skip comments and blank lines
function Build-CmdList {
    param([string]$Commands)
    $result = @()
    foreach ($cmd in ($Commands -split "`n")) {
        $trimmed = $cmd.TrimStart()
        if (-not $trimmed) { continue }
        if ($trimmed.StartsWith('#')) { continue }
        $result += $trimmed
    }
    return $result
}

$commands = "# comment`necho `"step one`"`n   echo `"indented step`"`n`necho `"step three`"`n# trailing comment"
$result = Build-CmdList $commands
Assert-Eq "filtered to 3 commands" "3" "$($result.Count)"
Assert-Eq "keeps step one" 'echo "step one"' $result[0]
Assert-Eq "trims indented step" 'echo "indented step"' $result[1]
Assert-Eq "keeps step three" 'echo "step three"' $result[2]

$commands = "# only comments`n`n# more comments`n"
# @() re-wraps the result: a function returning an empty array unrolls to
# $null on the pipeline, and $null.Count is a hard error under
# Set-StrictMode -Version Latest on pwsh 7.6+.
$result = @(Build-CmdList $commands)
Assert-Eq "all comments filtered to empty" "0" "$($result.Count)"

# ============================================================
# Test Group 5: Full integration
# ============================================================
Write-Host ""
Write-Host "=== Test Group 5: Full integration ==="

$proj5 = Join-Path $TmpDir 'g5-project'
New-Item -ItemType Directory -Path $proj5 -Force | Out-Null
Set-Content -Path (Join-Path $proj5 '.stride.md') -Value @'
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
'@ -Encoding UTF8

# 5a: Claim triggers before_doing
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim -d {}"}}' -Phase 'post' -ProjectDir $proj5
Assert-Exit "claim exits 0" 0 $r.ExitCode
Assert-Contains "claim runs before_doing" "before_doing_executed" $r.Stdout
# D65: a fully passing section writes nothing to stderr.
Assert-Eq "claim writes nothing to stderr" "" $r.Stderr.Trim()

# 5b: Pre-complete triggers after_doing
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}}' -Phase 'pre' -ProjectDir $proj5
Assert-Exit "pre-complete exits 0" 0 $r.ExitCode
Assert-Contains "pre-complete runs after_doing" "after_doing_executed" $r.Stdout

# 5c: Post-complete triggers before_review
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}}' -Phase 'post' -ProjectDir $proj5
Assert-Exit "post-complete exits 0" 0 $r.ExitCode
Assert-Contains "post-complete runs before_review" "before_review_executed" $r.Stdout

# 5d: Mark-reviewed triggers after_review
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/mark_reviewed"}}' -Phase 'post' -ProjectDir $proj5
Assert-Exit "mark-reviewed exits 0" 0 $r.ExitCode
Assert-Contains "mark-reviewed runs after_review" "after_review_executed" $r.Stdout

# 5e: Non-stride command exits cleanly
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"ls -la"}}' -Phase 'post' -ProjectDir $proj5
Assert-Exit "non-stride exits 0" 0 $r.ExitCode
Assert-Eq "non-stride no stderr" "" $r.Stderr.Trim()

# 5f: No .stride.md exits cleanly
$emptyProj = Join-Path $TmpDir 'empty-project'
New-Item -ItemType Directory -Path $emptyProj -Force | Out-Null
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}' -Phase 'post' -ProjectDir $emptyProj
Assert-Exit "no .stride.md exits 0" 0 $r.ExitCode

# 5g: No phase argument exits cleanly
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}' -Phase '' -ProjectDir $proj5
Assert-Exit "no phase exits 0" 0 $r.ExitCode

# 5h: Hook with failing command exits 2
$failProj = Join-Path $TmpDir 'fail-project'
New-Item -ItemType Directory -Path $failProj -Force | Out-Null
Set-Content -Path (Join-Path $failProj '.stride.md') -Value @'
## before_doing
```bash
echo "step one passes"
false
echo "step three should not run"
```
'@ -Encoding UTF8

$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}' -Phase 'post' -ProjectDir $failProj
Assert-Exit "failing hook exits 2" 2 $r.ExitCode
# The failure message stays on stderr — load-bearing for the BeforeTool
# blocking semantic (exit 2 + stderr message).
Assert-Contains "failing hook reports failure on stderr" "hook failed on command 2/3" $r.Stderr
# D65: the earlier PASSING command's output must NOT leak to stderr.
Assert-NotContains "passing command output kept off stderr" "step one passes" $r.Stderr
Assert-NotContains "stops execution after failure" "step three should not run" $r.Stderr

# 5i: Hook with multiple successful commands
$multiProj = Join-Path $TmpDir 'multi-project'
New-Item -ItemType Directory -Path $multiProj -Force | Out-Null
Set-Content -Path (Join-Path $multiProj '.stride.md') -Value @'
## after_doing
```bash
echo "test_one"
echo "test_two"
echo "test_three"
```
'@ -Encoding UTF8

$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}}' -Phase 'pre' -ProjectDir $multiProj
Assert-Exit "multi-command exits 0" 0 $r.ExitCode
# D65: each passing command's output is folded into commands_output on stdout.
Assert-Contains "multi-command: emits commands_output" '"commands_output"' $r.Stdout
Assert-Contains "multi-command: step 1" "test_one" $r.Stdout
Assert-Contains "multi-command: step 2" "test_two" $r.Stdout
Assert-Contains "multi-command: step 3" "test_three" $r.Stdout

# 5j: Missing section exits 0
$partialProj = Join-Path $TmpDir 'partial-project'
New-Item -ItemType Directory -Path $partialProj -Force | Out-Null
Set-Content -Path (Join-Path $partialProj '.stride.md') -Value @'
## before_doing
```bash
echo "only before_doing"
```
'@ -Encoding UTF8

$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}}' -Phase 'pre' -ProjectDir $partialProj
Assert-Exit "missing section exits 0" 0 $r.ExitCode

# ============================================================
# Test Group 6: Edge cases
# ============================================================
Write-Host ""
Write-Host "=== Test Group 6: Edge cases ==="

# 6a: .stride.md with no trailing newline
$noNewlineProj = Join-Path $TmpDir 'no-newline-project'
New-Item -ItemType Directory -Path $noNewlineProj -Force | Out-Null
[System.IO.File]::WriteAllText(
    (Join-Path $noNewlineProj '.stride.md'),
    "## before_doing`n``````bash`necho `"no trailing newline`"`n``````",
    [System.Text.Encoding]::UTF8
)

$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $noNewlineProj
Assert-Exit "no trailing newline exits 0" 0 $r.ExitCode
Assert-Contains "no trailing newline runs command" "no trailing newline" $r.Stdout

# 6b: Command with environment variable references
$envProj = Join-Path $TmpDir 'env-project'
New-Item -ItemType Directory -Path $envProj -Force | Out-Null
Set-Content -Path (Join-Path $envProj '.stride.md') -Value @'
## before_doing
```bash
echo "home=$HOME"
```
'@ -Encoding UTF8

$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $envProj
Assert-Exit "env var expansion exits 0" 0 $r.ExitCode
Assert-Contains "env var expanded" "home=" $r.Stdout

# 6c: .stride.md with CRLF line endings
$crlfProj = Join-Path $TmpDir 'crlf-project'
New-Item -ItemType Directory -Path $crlfProj -Force | Out-Null
[System.IO.File]::WriteAllText(
    (Join-Path $crlfProj '.stride.md'),
    "## before_doing`r`n``````bash`r`necho `"crlf test`"`r`n```````r`n",
    [System.Text.Encoding]::UTF8
)

$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $crlfProj
Assert-Exit "CRLF line endings exits 0" 0 $r.ExitCode
Assert-Contains "CRLF runs command" "crlf test" $r.Stdout

# 6d: JSON with tool_response (env caching path)
$cacheProj = Join-Path $TmpDir 'cache-project'
New-Item -ItemType Directory -Path $cacheProj -Force | Out-Null
Set-Content -Path (Join-Path $cacheProj '.stride.md') -Value @'
## before_doing
```bash
echo "id=$TASK_IDENTIFIER title=$TASK_TITLE"
```
'@ -Encoding UTF8

$claimWithResponse = '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"},"tool_response":"{\"data\":{\"id\":42,\"identifier\":\"W99\",\"title\":\"Test Task\",\"status\":\"doing\",\"complexity\":\"small\",\"priority\":\"high\"}}"}'
$r = Invoke-HookScript -InputJson $claimWithResponse -Phase 'post' -ProjectDir $cacheProj
Assert-Exit "env caching exits 0" 0 $r.ExitCode
Assert-Contains "env cache: identifier" "id=W99" $r.Stdout
Assert-Contains "env cache: title" "title=Test Task" $r.Stdout
# Clean up cache
$cacheFile = Join-Path $cacheProj '.stride-env-cache'
if (Test-Path $cacheFile) { Remove-Item -Force $cacheFile }

# 6e: Structured JSON output on success
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}' -Phase 'post' -ProjectDir $proj5
Assert-Contains "success JSON has hook field" '"hook"' $r.Stdout
Assert-Contains "success JSON has status" '"success"' $r.Stdout
# D65: success JSON carries the per-command output array and writes no stderr.
Assert-Contains "success JSON has commands_output field" '"commands_output"' $r.Stdout
Assert-Eq "success path writes nothing to stderr" "" $r.Stderr.Trim()
# stdout must be a single parseable JSON object with status success.
$successObj = $r.Stdout | ConvertFrom-Json
Assert-Eq "success stdout parses to status success" "success" $successObj.status

# 6e2: D65 — a PASSING command that writes to STDERR (exit 0) is the exact
# production trigger. Its stderr must NOT reach fd 2 (where the host mislabels
# it); it must land in the success JSON's commands_output[].stderr.
$stderrOkProj = Join-Path $TmpDir 'stderr-ok-project'
New-Item -ItemType Directory -Path $stderrOkProj -Force | Out-Null
Set-Content -Path (Join-Path $stderrOkProj '.stride.md') -Value @'
## before_doing
```bash
echo "compiling to stderr" 1>&2
```
'@ -Encoding UTF8
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}' -Phase 'post' -ProjectDir $stderrOkProj
Assert-Exit "stderr-writing passing gate exits 0" 0 $r.ExitCode
Assert-Eq "stderr-writing passing gate writes nothing to fd 2" "" $r.Stderr.Trim()
$soObj = $r.Stdout | ConvertFrom-Json
Assert-Contains "passing command's stderr folded into commands_output" "compiling to stderr" $soObj.commands_output[0].stderr

# 6f: Structured JSON output on failure
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}' -Phase 'post' -ProjectDir $failProj
Assert-Contains "failure JSON has hook field" '"hook"' $r.Stdout
Assert-Contains "failure JSON has failed status" '"failed"' $r.Stdout

# ============================================================
# Test Group 7: after_goal end-to-end routing (W785)
# ============================================================
# Mirrors test-stride-hook.sh Test Group 8 — exercises the W784
# routing changes in stride-hook.ps1. Fixtures use generic URLs and
# synthetic task IDs per the W785 pitfall.
Write-Host ""
Write-Host "=== Test Group 7: after_goal end-to-end routing (W785) ==="

function Build-AfterGoalInput {
    param(
        [string]$PrimaryCommand,
        [string[]]$HookNames
    )
    $hooksArr = @($HookNames | ForEach-Object { @{ name = $_ } })
    $inner = (@{ data = @{ id = 99 }; hooks = $hooksArr } | ConvertTo-Json -Depth 5 -Compress)
    return (@{
        tool_input    = @{ command = $PrimaryCommand }
        tool_response = @{ stdout = $inner }
    } | ConvertTo-Json -Depth 5 -Compress)
}

$agProj = Join-Path $TmpDir 'after-goal-e2e'
New-Item -ItemType Directory -Path $agProj -Force | Out-Null
Set-Content -Path (Join-Path $agProj '.stride.md') -Value @'
## before_doing
```bash
echo "before_doing_ran"
```

## after_doing
```bash
echo "after_doing_ran"
```

## before_review
```bash
echo "before_review_ran"
```

## after_review
```bash
echo "after_review_ran"
```

## after_goal
```bash
echo "after_goal_ran for $GOAL_IDENTIFIER"
```
'@ -Encoding UTF8

# 7a: after_goal in response + ## after_goal present -> section runs.
$agInputPresent = Build-AfterGoalInput `
    -PrimaryCommand 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete' `
    -HookNames @('after_doing', 'before_review', 'after_review', 'after_goal')
$r = Invoke-HookScript -InputJson $agInputPresent -Phase 'post' -ProjectDir $agProj
Assert-Exit "7a: end-to-end after_goal present exits 0" 0 $r.ExitCode
Assert-Contains "7a: primary before_review ran" "before_review_ran" $r.Stdout
Assert-Contains "7a: after_goal section ran" "after_goal_ran" $r.Stdout
Assert-Contains "7a: structured success JSON for after_goal on stdout" '"hook":"after_goal"' $r.Stdout

# 7b: after_goal in response + ## after_goal section ABSENT (back-compat).
$agProjMissing = Join-Path $TmpDir 'after-goal-e2e-missing'
New-Item -ItemType Directory -Path $agProjMissing -Force | Out-Null
Set-Content -Path (Join-Path $agProjMissing '.stride.md') -Value @'
## before_doing
```bash
echo "before_doing_ran"
```

## after_doing
```bash
echo "after_doing_ran"
```

## before_review
```bash
echo "before_review_ran"
```

## after_review
```bash
echo "after_review_ran"
```
'@ -Encoding UTF8
$r = Invoke-HookScript -InputJson $agInputPresent -Phase 'post' -ProjectDir $agProjMissing
Assert-Exit "7b: end-to-end after_goal-missing-section exits 0 (back-compat)" 0 $r.ExitCode
Assert-Contains "7b: primary before_review still ran" "before_review_ran" $r.Stdout
Assert-NotContains "7b: missing ## after_goal emits no after_goal JSON" '"hook":"after_goal"' $r.Stdout

# 7c: after_goal NOT in response -> behavior unchanged.
$agInputAbsent = Build-AfterGoalInput `
    -PrimaryCommand 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete' `
    -HookNames @('after_doing', 'before_review', 'after_review')
$r = Invoke-HookScript -InputJson $agInputAbsent -Phase 'post' -ProjectDir $agProj
Assert-Exit "7c: end-to-end after_goal-absent exits 0" 0 $r.ExitCode
Assert-Contains "7c: primary before_review ran" "before_review_ran" $r.Stdout
Assert-NotContains "7c: after_goal absent does not execute the section" "after_goal_ran" $r.Stdout

# 7d: after_goal section command exits non-zero -> structured failure JSON
# surfaces on stdout; script exit code stays 0.
$agProjFail = Join-Path $TmpDir 'after-goal-e2e-fail'
New-Item -ItemType Directory -Path $agProjFail -Force | Out-Null
Set-Content -Path (Join-Path $agProjFail '.stride.md') -Value @'
## before_review
```bash
echo "before_review_ran"
```

## after_review
```bash
echo "after_review_ran"
```

## after_goal
```bash
bash -c 'exit 11'
```
'@ -Encoding UTF8
$r = Invoke-HookScript -InputJson $agInputPresent -Phase 'post' -ProjectDir $agProjFail
Assert-Exit "7d: end-to-end after_goal-failure does not propagate as script exit" 0 $r.ExitCode
Assert-Contains "7d: structured failed JSON references after_goal on stdout" '"hook":"after_goal"' $r.Stdout
Assert-Contains "7d: structured failed JSON has status:failed" '"status":"failed"' $r.Stdout
Assert-Contains "7d: structured failed JSON carries non-zero exit_code" '"exit_code":11' $r.Stdout

# 7e: mark_reviewed URL also routes after_goal.
$agInputMr = Build-AfterGoalInput `
    -PrimaryCommand 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/mark_reviewed' `
    -HookNames @('after_review', 'after_goal')
$r = Invoke-HookScript -InputJson $agInputMr -Phase 'post' -ProjectDir $agProj
Assert-Exit "7e: end-to-end after_goal on mark_reviewed exits 0" 0 $r.ExitCode
Assert-Contains "7e: mark_reviewed runs after_review" "after_review_ran" $r.Stdout
Assert-Contains "7e: mark_reviewed runs after_goal" "after_goal_ran" $r.Stdout

# ============================================================
# Test Group 8: PUT snapshot upload (W844 — G162 port)
# ============================================================
# Mirror of stride/hooks/test-stride-hook.ps1 Test Group 7. Verifies
# Invoke-FinalizeAfterDoing PUTs the on-disk snapshot to
# {URL}/api/tasks/{TASK_ID}/changed_files when all prerequisites are
# present, and silently no-ops otherwise.
Write-Host ""
Write-Host "=== Test Group 8: PUT snapshot upload (W844) ==="

# 8a: PUT-success — snapshot uploaded to a local HttpListener
$putSuccessProj = Join-Path $TmpDir 'put-success-project'
New-Item -ItemType Directory -Path $putSuccessProj -Force | Out-Null
Set-Content -Path (Join-Path $putSuccessProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $putSuccessProj '.stride-changed-files.json') `
    -Value '[{"path":"foo.txt","diff":"unified patch body"}]' -Encoding UTF8
Set-Content -Path (Join-Path $putSuccessProj '.stride-env-cache') `
    -Value "TASK_ID=99`nTASK_BASE_REF=abc" -Encoding UTF8

$putPort = 18881
$putFixture = Join-Path $TmpDir 'put-fixture.json'
if (Test-Path $putFixture) { Remove-Item -Force $putFixture }

$putListenerJob = Start-Job -ArgumentList $putPort, $putFixture -ScriptBlock {
    param($Port, $Fixture)
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add("http://localhost:$Port/")
    try {
        $l.Start()
        $ctx = $l.GetContext()
        $req = $ctx.Request
        $reader = [System.IO.StreamReader]::new($req.InputStream)
        $body = $reader.ReadToEnd()
        @{
            Method = $req.HttpMethod
            Path   = $req.Url.AbsolutePath
            Auth   = $req.Headers['Authorization']
            Body   = $body
        } | ConvertTo-Json -Compress | Set-Content -Path $Fixture -Encoding UTF8
        $resp = $ctx.Response
        $resp.StatusCode = 200
        $resp.OutputStream.Close()
    } catch {
        # Listener tear-down errors are ignored.
    } finally {
        if ($l.IsListening) { $l.Stop() }
    }
}

try {
    $null = Wait-ForListener -Port $putPort
    $putCompleteCmd = "curl -X PATCH http://localhost:$putPort/api/tasks/99/complete -H `"Authorization: Bearer test_token_xyz`""
    # ConvertTo-Json escapes the command's embedded quotes — hand-rolling the
    # JSON here produces an invalid document whose fallback-regex extraction
    # truncates the command at the first inner quote, dropping the token.
    $putJson = @{ tool_input = @{ command = $putCompleteCmd } } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $putJson -Phase 'pre' -ProjectDir $putSuccessProj
    Assert-Exit "8a: hook exits 0 after PUT" 0 $r.ExitCode

    Wait-Job $putListenerJob -Timeout 8 | Out-Null
    Remove-Job $putListenerJob -Force -ErrorAction SilentlyContinue

    if (Test-Path $putFixture) {
        $record = Get-Content -Raw -Path $putFixture | ConvertFrom-Json
        Assert-Eq "8a: PUT method" "PUT" $record.Method
        Assert-Contains "8a: PUT path targets /changed_files" "/api/tasks/99/changed_files" $record.Path
        Assert-Eq "8a: Bearer token from `$Command" "Bearer test_token_xyz" $record.Auth
        # D61: body's changed_files value is the transport-encoded envelope
        # {encoding: "base64", data: <string>}, NOT a bare array and NOT raw
        # diff text (an edge filter could misread the raw text as an attack).
        try {
            $parsedBody = $record.Body | ConvertFrom-Json
            if ($parsedBody.changed_files.encoding -eq 'base64' -and
                $parsedBody.changed_files.data -is [string] -and
                $parsedBody.changed_files.data.Length -gt 0) {
                Write-Host "  PASS: 8a: PUT body is the base64-encoded changed_files envelope" -ForegroundColor Green
                $script:PASS++
            } else {
                Write-Host "  FAIL: 8a: PUT body is not the encoded envelope: $($record.Body)" -ForegroundColor Red
                $script:FAIL++
            }

            # D61: the raw diff/path text MUST NOT appear in the wire body.
            if ($record.Body -like '*foo.txt*') {
                Write-Host "  FAIL: 8a: raw path leaked into the wire body (should be base64-encoded)" -ForegroundColor Red
                $script:FAIL++
            } else {
                Write-Host "  PASS: 8a: raw diff text is absent from the wire body (encoded)" -ForegroundColor Green
                $script:PASS++
            }

            # D61: round-trip — encoding the snapshot bytes the same way the hook
            # does reproduces the envelope's data field.
            $expectedData = [System.Convert]::ToBase64String(
                [System.IO.File]::ReadAllBytes((Join-Path $putSuccessProj '.stride-changed-files.json')))
            if ($parsedBody.changed_files.data -eq $expectedData) {
                Write-Host "  PASS: 8a: encoded data round-trips to the snapshot file content" -ForegroundColor Green
                $script:PASS++
            } else {
                Write-Host "  FAIL: 8a: round-trip mismatch — data: $($parsedBody.changed_files.data) vs expected: $expectedData" -ForegroundColor Red
                $script:FAIL++
            }
        } catch {
            Write-Host "  FAIL: 8a: PUT body did not parse as JSON: $($_.Exception.Message)" -ForegroundColor Red
            $script:FAIL++
        }
    } else {
        Write-Host "  FAIL: 8a: PUT did not arrive at listener" -ForegroundColor Red
        $script:FAIL++
    }
} finally {
    if ($putListenerJob -and $putListenerJob.State -eq 'Running') {
        Stop-Job $putListenerJob -ErrorAction SilentlyContinue
        Remove-Job $putListenerJob -Force -ErrorAction SilentlyContinue
    }
}

# 8a2 (D67): Invoke-ChangedFilesUpload strips the hook's own root artifacts from
# the snapshot before PUT. The ps1 has no capture step, so this upload-side
# filter is the equivalent enforcement point. A same-named file in a
# subdirectory is kept; the legitimate change is kept.
$exclProj = Join-Path $TmpDir 'put-exclude-project'
New-Item -ItemType Directory -Path $exclProj -Force | Out-Null
Set-Content -Path (Join-Path $exclProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $exclProj '.stride-changed-files.json') `
    -Value '[{"path":".stride-diff-upload-state","diff":"state body"},{"path":"lib/foo.ex","diff":"real patch"},{"path":"sub/.stride-changed-files.json","diff":"user file"},{"path":".stride-changed-files.json","diff":"snapshot body"}]' -Encoding UTF8
Set-Content -Path (Join-Path $exclProj '.stride-env-cache') `
    -Value "TASK_ID=99`nTASK_BASE_REF=abc" -Encoding UTF8

$exclPort = 18879
$exclFixture = Join-Path $TmpDir 'put-exclude-fixture.json'
if (Test-Path $exclFixture) { Remove-Item -Force $exclFixture }

$exclListenerJob = Start-Job -ArgumentList $exclPort, $exclFixture -ScriptBlock {
    param($Port, $Fixture)
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add("http://localhost:$Port/")
    try {
        $l.Start()
        $ctx = $l.GetContext()
        $req = $ctx.Request
        $reader = [System.IO.StreamReader]::new($req.InputStream)
        $body = $reader.ReadToEnd()
        @{ Body = $body } | ConvertTo-Json -Compress | Set-Content -Path $Fixture -Encoding UTF8
        $resp = $ctx.Response
        $resp.StatusCode = 200
        $resp.OutputStream.Close()
    } catch {
        # Listener tear-down errors are ignored.
    } finally {
        if ($l.IsListening) { $l.Stop() }
    }
}

try {
    $null = Wait-ForListener -Port $exclPort
    $exclCmd = "curl -X PATCH http://localhost:$exclPort/api/tasks/99/complete -H `"Authorization: Bearer test_token_xyz`""
    $exclJson = @{ tool_input = @{ command = $exclCmd } } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $exclJson -Phase 'pre' -ProjectDir $exclProj
    Assert-Exit "8a2: hook exits 0 after filtered PUT" 0 $r.ExitCode

    Wait-Job $exclListenerJob -Timeout 8 | Out-Null
    Remove-Job $exclListenerJob -Force -ErrorAction SilentlyContinue

    if (Test-Path $exclFixture) {
        $record = Get-Content -Raw -Path $exclFixture | ConvertFrom-Json
        $parsedBody = $record.Body | ConvertFrom-Json
        $decoded = [System.Convert]::FromBase64String($parsedBody.changed_files.data)
        $decodedText = [System.Text.Encoding]::UTF8.GetString($decoded)
        $entries = @($decodedText | ConvertFrom-Json)
        $paths = @($entries | ForEach-Object { $_.path })
        Assert-Eq "8a2: filtered snapshot keeps only the non-artifact entries" "2" "$($entries.Count)"
        if ($paths -contains 'lib/foo.ex' -and $paths -contains 'sub/.stride-changed-files.json') {
            Write-Host "  PASS: 8a2: real file and subdir same-named file survive the filter" -ForegroundColor Green
            $script:PASS++
        } else {
            Write-Host "  FAIL: 8a2: expected lib/foo.ex + sub/.stride-changed-files.json, got: $($paths -join ', ')" -ForegroundColor Red
            $script:FAIL++
        }
        if ($paths -notcontains '.stride-diff-upload-state' -and $paths -notcontains '.stride-changed-files.json') {
            Write-Host "  PASS: 8a2: root upload-state and snapshot artifacts stripped from PUT body" -ForegroundColor Green
            $script:PASS++
        } else {
            Write-Host "  FAIL: 8a2: root artifacts leaked into PUT body: $($paths -join ', ')" -ForegroundColor Red
            $script:FAIL++
        }
    } else {
        Write-Host "  FAIL: 8a2: filtered PUT did not arrive at listener" -ForegroundColor Red
        $script:FAIL++
    }
} finally {
    if ($exclListenerJob -and $exclListenerJob.State -eq 'Running') {
        Stop-Job $exclListenerJob -ErrorAction SilentlyContinue
        Remove-Job $exclListenerJob -Force -ErrorAction SilentlyContinue
    }
}

# 8b: PUT failure (unreachable URL) does not propagate
$putFailProj = Join-Path $TmpDir 'put-fail-project'
New-Item -ItemType Directory -Path $putFailProj -Force | Out-Null
Set-Content -Path (Join-Path $putFailProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $putFailProj '.stride-changed-files.json') `
    -Value '[{"path":"foo.txt","diff":"body"}]' -Encoding UTF8
Set-Content -Path (Join-Path $putFailProj '.stride-env-cache') `
    -Value "TASK_ID=99`nTASK_BASE_REF=abc" -Encoding UTF8
$failCmd = 'curl -X PATCH http://127.0.0.1:1/api/tasks/99/complete -H "Authorization: Bearer tok"'
# ConvertTo-Json escapes the embedded quotes so the token survives extraction
# and the PUT is actually attempted (and fails on the unreachable port).
$failJson = @{ tool_input = @{ command = $failCmd } } | ConvertTo-Json -Compress
$r = Invoke-HookScript -InputJson $failJson -Phase 'pre' -ProjectDir $putFailProj
Assert-Exit "8b: hook exits 0 even when PUT fails" 0 $r.ExitCode
# D61: a failed upload is surfaced to stderr (non-fatal), never silently dropped.
# (W1095) the shared helper warns with the HTTP code, e.g. "(HTTP 000)".
Assert-Contains "8b: failed PUT warns to stderr" "stride-hook: changed_files upload failed (HTTP" $r.Stderr
$snapshotPath8b = Join-Path $putFailProj '.stride-changed-files.json'
if (Test-Path $snapshotPath8b) {
    Write-Host "  PASS: 8b: snapshot file persists across failed PUT" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 8b: snapshot file missing after failed PUT" -ForegroundColor Red
    $script:FAIL++
}

# 8c: No snapshot file on disk → Invoke-FinalizeAfterDoing no-ops cleanly
$noSnapProj = Join-Path $TmpDir 'no-snap-project'
New-Item -ItemType Directory -Path $noSnapProj -Force | Out-Null
Set-Content -Path (Join-Path $noSnapProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $noSnapProj '.stride-env-cache') `
    -Value "TASK_ID=99" -Encoding UTF8
$noSnapCmd = 'curl -X PATCH http://127.0.0.1:1/api/tasks/99/complete -H "Authorization: Bearer tok"'
$noSnapJson = "{`"tool_input`":{`"command`":`"$noSnapCmd`"}}"
$r = Invoke-HookScript -InputJson $noSnapJson -Phase 'pre' -ProjectDir $noSnapProj
Assert-Exit "8c: hook exits 0 with no snapshot file" 0 $r.ExitCode

# 8d: No Bearer token in `$Command → finalize no-ops
$noTokProj = Join-Path $TmpDir 'no-tok-project'
New-Item -ItemType Directory -Path $noTokProj -Force | Out-Null
Set-Content -Path (Join-Path $noTokProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $noTokProj '.stride-changed-files.json') `
    -Value '[{"path":"foo.txt","diff":"body"}]' -Encoding UTF8
Set-Content -Path (Join-Path $noTokProj '.stride-env-cache') `
    -Value "TASK_ID=99" -Encoding UTF8
$noTokCmd = 'curl -X PATCH http://stride.example.com/api/tasks/99/complete'
$noTokJson = "{`"tool_input`":{`"command`":`"$noTokCmd`"}}"
$r = Invoke-HookScript -InputJson $noTokJson -Phase 'pre' -ProjectDir $noTokProj
Assert-Exit "8d: hook exits 0 with no Bearer token" 0 $r.ExitCode

# 8e (D127): No TASK_ID in env cache → finalize STILL PUTs, targeting the id
# parsed from the /complete URL (99). Before D127 the missing cache id suppressed
# the upload; now the URL is the authoritative source of the task id, so the PUT
# must fire and land on /api/tasks/99/changed_files.
$noIdProj = Join-Path $TmpDir 'no-id-project'
New-Item -ItemType Directory -Path $noIdProj -Force | Out-Null
Set-Content -Path (Join-Path $noIdProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $noIdProj '.stride-changed-files.json') `
    -Value '[{"path":"foo.txt","diff":"body"}]' -Encoding UTF8
Set-Content -Path (Join-Path $noIdProj '.stride-env-cache') `
    -Value "TASK_BASE_REF=abc" -Encoding UTF8

$noIdPort = 18883
$noIdFixture = Join-Path $TmpDir 'no-id-fixture.json'
if (Test-Path $noIdFixture) { Remove-Item -Force $noIdFixture }

$noIdListenerJob = Start-Job -ArgumentList $noIdPort, $noIdFixture -ScriptBlock {
    param($Port, $Fixture)
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add("http://localhost:$Port/")
    try {
        $l.Start()
        $ctx = $l.GetContext()
        $req = $ctx.Request
        @{ Method = $req.HttpMethod; Path = $req.Url.AbsolutePath } |
            ConvertTo-Json -Compress | Set-Content -Path $Fixture -Encoding UTF8
        $resp = $ctx.Response
        $resp.StatusCode = 200
        $resp.OutputStream.Close()
    } catch {
        # Listener tear-down errors are ignored.
    } finally {
        if ($l.IsListening) { $l.Stop() }
    }
}

try {
    $null = Wait-ForListener -Port $noIdPort
    $noIdCmd = "curl -X PATCH http://localhost:$noIdPort/api/tasks/99/complete -H `"Authorization: Bearer tok`""
    $noIdJson = @{ tool_input = @{ command = $noIdCmd } } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $noIdJson -Phase 'pre' -ProjectDir $noIdProj
    Assert-Exit "8e: hook exits 0 with no env TASK_ID" 0 $r.ExitCode

    Wait-Job $noIdListenerJob -Timeout 8 | Out-Null
    Remove-Job $noIdListenerJob -Force -ErrorAction SilentlyContinue

    if (Test-Path $noIdFixture) {
        $record = Get-Content -Raw -Path $noIdFixture | ConvertFrom-Json
        Assert-Contains "8e (D127): missing env TASK_ID → PUT still made, targeting the URL id (99)" `
            "/api/tasks/99/changed_files" $record.Path
    } else {
        Write-Host "  FAIL: 8e (D127): PUT did not arrive despite the URL carrying id 99" -ForegroundColor Red
        $script:FAIL++
    }
} finally {
    if ($noIdListenerJob -and $noIdListenerJob.State -eq 'Running') {
        Stop-Job $noIdListenerJob -ErrorAction SilentlyContinue
        Remove-Job $noIdListenerJob -Force -ErrorAction SilentlyContinue
    }
}

# 8f (D127): stale env TASK_ID + differing /complete URL id → the PUT targets the
# URL id, NOT the stale cache id. TASK_ID=111 (stale, a prior task) is seeded in
# the env cache while the command completes /api/tasks/99/complete; the diff must
# land on 99 — the fix for the empty-changed_files root cause (G321/D126).
$staleProj = Join-Path $TmpDir 'stale-id-project'
New-Item -ItemType Directory -Path $staleProj -Force | Out-Null
Set-Content -Path (Join-Path $staleProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $staleProj '.stride-changed-files.json') `
    -Value '[{"path":"foo.txt","diff":"body"}]' -Encoding UTF8
Set-Content -Path (Join-Path $staleProj '.stride-env-cache') `
    -Value "TASK_ID=111`nTASK_BASE_REF=abc" -Encoding UTF8

$stalePort = 18885
$staleFixture = Join-Path $TmpDir 'stale-id-fixture.json'
if (Test-Path $staleFixture) { Remove-Item -Force $staleFixture }

$staleListenerJob = Start-Job -ArgumentList $stalePort, $staleFixture -ScriptBlock {
    param($Port, $Fixture)
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add("http://localhost:$Port/")
    try {
        $l.Start()
        $ctx = $l.GetContext()
        $req = $ctx.Request
        @{ Method = $req.HttpMethod; Path = $req.Url.AbsolutePath } |
            ConvertTo-Json -Compress | Set-Content -Path $Fixture -Encoding UTF8
        $resp = $ctx.Response
        $resp.StatusCode = 200
        $resp.OutputStream.Close()
    } catch {
        # Listener tear-down errors are ignored.
    } finally {
        if ($l.IsListening) { $l.Stop() }
    }
}

try {
    $null = Wait-ForListener -Port $stalePort
    $staleCmd = "curl -X PATCH http://localhost:$stalePort/api/tasks/99/complete -H `"Authorization: Bearer tok`""
    $staleJson = @{ tool_input = @{ command = $staleCmd } } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $staleJson -Phase 'pre' -ProjectDir $staleProj
    Assert-Exit "8f: hook exits 0 with a stale env TASK_ID" 0 $r.ExitCode

    Wait-Job $staleListenerJob -Timeout 8 | Out-Null
    Remove-Job $staleListenerJob -Force -ErrorAction SilentlyContinue

    if (Test-Path $staleFixture) {
        $record = Get-Content -Raw -Path $staleFixture | ConvertFrom-Json
        Assert-Contains "8f (D127): PUT targets the /complete URL id (99), not the stale env TASK_ID (111)" `
            "/api/tasks/99/changed_files" $record.Path
        Assert-NotContains "8f (D127): PUT does NOT target the stale env TASK_ID (111)" `
            "/api/tasks/111/changed_files" $record.Path
    } else {
        Write-Host "  FAIL: 8f (D127): PUT did not arrive at listener" -ForegroundColor Red
        $script:FAIL++
    }
} finally {
    if ($staleListenerJob -and $staleListenerJob.State -eq 'Running') {
        Stop-Job $staleListenerJob -ErrorAction SilentlyContinue
        Remove-Job $staleListenerJob -Force -ErrorAction SilentlyContinue
    }
}

# 8g (D127): Get-TaskIdFromCommand unit test — parity with bash 9g. The helper is
# defined after stride-hook.ps1's early-exit guards, so the whole script cannot be
# dot-sourced to reach it (it would exit at the no-Phase/no-input guard first).
# Extract the actual function block from the source and invoke it directly so this
# tests the shipped definition, not a copy — covering the /complete and
# /mark_reviewed id extraction and the empty-return branches (claim, next, and a
# non-numeric segment) that the integration tests (8e/8f) do not reach.
$hookSource = Get-Content -Raw -Path $HookScript
if ($hookSource -match '(?ms)^function Get-TaskIdFromCommand \{.*?^\}') {
    Invoke-Expression $Matches[0]
    $u1 = Get-TaskIdFromCommand -CommandText 'curl -X PATCH https://x/api/tasks/7777/complete -H h'
    $u2 = Get-TaskIdFromCommand -CommandText 'curl -X PATCH https://x/api/tasks/42/mark_reviewed'
    $u3 = Get-TaskIdFromCommand -CommandText 'curl -X POST https://x/api/tasks/claim'
    $u4 = Get-TaskIdFromCommand -CommandText 'curl -s https://x/api/tasks/next'
    $u5 = Get-TaskIdFromCommand -CommandText 'curl https://x/api/tasks/abc/complete'
    Assert-Eq "8g (D127): Get-TaskIdFromCommand reads /complete + /mark_reviewed ids, empty for claim/next/non-numeric" `
        "7777|42|||" "$u1|$u2|$u3|$u4|$u5"
} else {
    Write-Host "  FAIL: 8g (D127): could not extract Get-TaskIdFromCommand from stride-hook.ps1" -ForegroundColor Red
    $script:FAIL++
}

# ============================================================
# Test Group 9: W1093 early capture + W1094 before_review self-heal
# ============================================================
Write-Host ""
Write-Host "=== Test Group 9: early upload-state + before_review self-heal (W1093/W1094) ==="

# Build a project with a seeded snapshot. $State (optional) seeds the upload
# state file. Returns the project path. URL is unreachable so a PUT attempt
# fails fast with HTTP 000 and warns to stderr — the observable retry signal.
function New-SelfHealProject {
    param([string]$Name, [string]$State)
    $proj = Join-Path $TmpDir $Name
    New-Item -ItemType Directory -Path $proj -Force | Out-Null
    Set-Content -Path (Join-Path $proj '.stride.md') -Value @'
## before_review
```bash
```
'@ -Encoding UTF8
    Set-Content -Path (Join-Path $proj '.stride-changed-files.json') `
        -Value '[{"path":"foo.txt","diff":"body"}]' -Encoding UTF8
    Set-Content -Path (Join-Path $proj '.stride-env-cache') -Value "TASK_ID=99" -Encoding UTF8
    if ($State) {
        Set-Content -Path (Join-Path $proj '.stride-diff-upload-state') -Value $State -Encoding UTF8
    }
    return $proj
}

$selfHealCmd = 'curl -X PATCH http://127.0.0.1:1/api/tasks/99/complete -H "Authorization: Bearer tok"'
$selfHealJson = @{ tool_input = @{ command = $selfHealCmd } } | ConvertTo-Json -Compress

# 9a: an after_doing run records the upload state with task id + HTTP code
# ONLY — never the bearer token or the API URL.
$stProj = Join-Path $TmpDir 'self-heal-state'
New-Item -ItemType Directory -Path $stProj -Force | Out-Null
Set-Content -Path (Join-Path $stProj '.stride.md') -Value @'
## after_doing
```bash
echo ran
```
'@ -Encoding UTF8
Set-Content -Path (Join-Path $stProj '.stride-changed-files.json') `
    -Value '[{"path":"foo.txt","diff":"body"}]' -Encoding UTF8
Set-Content -Path (Join-Path $stProj '.stride-env-cache') -Value "TASK_ID=99" -Encoding UTF8
$null = Invoke-HookScript -InputJson $selfHealJson -Phase 'pre' -ProjectDir $stProj
$stContent = ''
$stPath = Join-Path $stProj '.stride-diff-upload-state'
if (Test-Path $stPath) { $stContent = Get-Content -Raw -Path $stPath }
Assert-Contains "9a: upload-state records task_id" "task_id=99" $stContent
Assert-Contains "9a: upload-state records http_code" "http_code=" $stContent
if ($stContent -match 'Bearer|127\.0\.0\.1|tok') {
    Write-Host "  FAIL: 9a: upload-state leaked token or URL" -ForegroundColor Red; $script:FAIL++
} else {
    Write-Host "  PASS: 9a: upload-state contains no token or URL" -ForegroundColor Green; $script:PASS++
}

# 9b: missing state → before_review re-uploads (PUT attempted → HTTP 000 warn)
$p = New-SelfHealProject -Name 'self-heal-missing' -State ''
$r = Invoke-HookScript -InputJson $selfHealJson -Phase 'post' -ProjectDir $p
Assert-Exit "9b: self-heal does not fail the hook" 0 $r.ExitCode
Assert-Contains "9b: missing state → re-uploads" "changed_files upload failed (HTTP" $r.Stderr

# 9c: different task id recorded → re-uploads
$p = New-SelfHealProject -Name 'self-heal-stale' -State "task_id=88`nhttp_code=200"
$r = Invoke-HookScript -InputJson $selfHealJson -Phase 'post' -ProjectDir $p
Assert-Contains "9c: stale task id → re-uploads" "changed_files upload failed (HTTP" $r.Stderr

# 9d: recorded non-2xx for this task → re-uploads
$p = New-SelfHealProject -Name 'self-heal-non2xx' -State "task_id=99`nhttp_code=500"
$r = Invoke-HookScript -InputJson $selfHealJson -Phase 'post' -ProjectDir $p
Assert-Contains "9d: recorded non-2xx → re-uploads" "changed_files upload failed (HTTP" $r.Stderr

# 9e: healthy 2xx recorded for this task → no re-upload (no PUT, no warning)
$p = New-SelfHealProject -Name 'self-heal-healthy' -State "task_id=99`nhttp_code=200"
$r = Invoke-HookScript -InputJson $selfHealJson -Phase 'post' -ProjectDir $p
Assert-NotContains "9e: healthy 2xx → no re-upload" "changed_files upload failed (HTTP" $r.Stderr

# 9f (W1658): terminal self-heal failure fails LOUD. With no state file the
# self-heal retries, the PUT to the unreachable endpoint (127.0.0.1:1) returns a
# non-2xx (HTTP 000), and the hook prints a distinct UNRESOLVED warning on stderr
# AND appends unresolved=yes to the state file — without changing the exit code.
$p = New-SelfHealProject -Name 'self-heal-terminal' -State ''
$r = Invoke-HookScript -InputJson $selfHealJson -Phase 'post' -ProjectDir $p
Assert-Exit "9f (W1658): terminal failure does not change the hook exit code" 0 $r.ExitCode
Assert-Contains "9f (W1658): terminal self-heal failure prints a loud UNRESOLVED warning" "CHANGED_FILES UPLOAD UNRESOLVED" $r.Stderr
$w1658StateFile = Join-Path $p '.stride-diff-upload-state'
$w1658State = if (Test-Path $w1658StateFile) { Get-Content -Raw -Path $w1658StateFile } else { '' }
Assert-Contains "9f (W1658): state file marked unresolved on terminal failure" "unresolved=yes" $w1658State

# 9g (W1658): a later 2xx PUT overwrites the state file and self-clears the mark.
# Seed the project with a terminal-failure state (unresolved=yes) and point the
# self-heal at a 200 listener; the successful re-PUT must overwrite the state to
# a healthy code with no unresolved marker.
$clearProj = New-SelfHealProject -Name 'self-heal-clear' -State "task_id=99`nhttp_code=500`nunresolved=yes"
$clearPort = 18887
$clearJob = Start-Job -ArgumentList $clearPort -ScriptBlock {
    param($Port)
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add("http://localhost:$Port/")
    try {
        $l.Start(); $ctx = $l.GetContext()
        $resp = $ctx.Response; $resp.StatusCode = 200; $resp.OutputStream.Close()
    } catch { } finally { if ($l.IsListening) { $l.Stop() } }
}
try {
    $null = Wait-ForListener -Port $clearPort
    $clearCmd = "curl -X PATCH http://localhost:$clearPort/api/tasks/99/complete -H `"Authorization: Bearer tok`""
    $clearJson = @{ tool_input = @{ command = $clearCmd } } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $clearJson -Phase 'post' -ProjectDir $clearProj
    Wait-Job $clearJob -Timeout 8 | Out-Null
    Remove-Job $clearJob -Force -ErrorAction SilentlyContinue
    $clearStateFile = Join-Path $clearProj '.stride-diff-upload-state'
    $clearState = if (Test-Path $clearStateFile) { Get-Content -Raw -Path $clearStateFile } else { '' }
    Assert-Contains "9g (W1658): later 2xx PUT records a healthy code" "http_code=200" $clearState
    Assert-NotContains "9g (W1658): later 2xx PUT self-clears the unresolved mark" "unresolved=yes" $clearState
} finally {
    Remove-Job $clearJob -Force -ErrorAction SilentlyContinue
}

# ============================================================
# Test Group 10: claim-time TASK_BASE_REF refresh + persisted-output
# fallback (W1087, mirrors test-stride-hook.sh Test Group 14 test-for-test)
# ============================================================
# A claim always opens a new task window. The hook must refresh TASK_BASE_REF
# to current HEAD on every claim: from parseable stdout, from a persisted output
# file when stdout only carries a "saved to" notice, and — when no JSON is
# obtainable at all — by rewriting only the TASK_BASE_REF line while preserving
# existing TASK_ identity lines. Non-claim hooks never touch it.
Write-Host ""
Write-Host "=== Test Group 10: claim TASK_BASE_REF refresh (W1087) ==="

# Mirror of the bash setup_put_repo: a real two-commit git repo with the stride
# state files gitignored, a pre-seeded cache carrying a STALE base ref (the v1
# commit) and a TASK_ID line to prove preservation.
function New-GitRepo {
    param([string]$Name)
    $dir = Join-Path $TmpDir $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    & git -C $dir init -q 2>$null | Out-Null
    & git -C $dir config user.email 'test@test.local' 2>$null | Out-Null
    & git -C $dir config user.name 'Test' 2>$null | Out-Null
    & git -C $dir config commit.gpgsign false 2>$null | Out-Null
    Set-Content -Path (Join-Path $dir '.gitignore') `
        -Value ".stride.md`n.stride-env-cache`n.stride-changed-files.json`n.stride-diff-upload-state" -Encoding UTF8
    Set-Content -Path (Join-Path $dir 'tracked.txt') -Value 'v1' -Encoding UTF8
    & git -C $dir add .gitignore tracked.txt 2>$null | Out-Null
    & git -C $dir commit -q -m 'v1' 2>$null | Out-Null
    Set-Content -Path (Join-Path $dir 'tracked.txt') -Value 'v2' -Encoding UTF8
    & git -C $dir add tracked.txt 2>$null | Out-Null
    & git -C $dir commit -q -m 'v2' 2>$null | Out-Null
    $putBase = (& git -C $dir rev-parse 'HEAD~1' | Out-String).Trim()
    Set-Content -Path (Join-Path $dir '.stride-env-cache') -Value "TASK_ID=42`nTASK_BASE_REF=$putBase" -Encoding UTF8
    Set-Content -Path (Join-Path $dir '.stride.md') -Value @'
## before_doing
```bash
echo "claimed"
```
'@ -Encoding UTF8
    return $dir
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "  SKIP: git not available — Group 10 requires it" -ForegroundColor Yellow
} else {
    # 10a: inline stdout JSON writes the full cache with TASK_BASE_REF = HEAD.
    $brA = New-GitRepo -Name 'g10-inline'
    $headA = (& git -C $brA rev-parse HEAD | Out-String).Trim()
    $claimA = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = '{"data":{"id":42,"identifier":"W42","title":"Inline Task","status":"in_progress","complexity":"medium","priority":"high"}}'; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimA -Phase 'post' -ProjectDir $brA
    Assert-Exit "10a: inline JSON claim exits 0" 0 $r.ExitCode
    $cacheA = Get-Content -Raw -Path (Join-Path $brA '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10a: inline JSON writes the identifier" "TASK_IDENTIFIER=W42" $cacheA
    Assert-Contains "10a: inline JSON sets TASK_BASE_REF to current HEAD" "TASK_BASE_REF=$headA" $cacheA

    # 10b: a persisted-output notice pointing at a readable JSON file.
    $brB = New-GitRepo -Name 'g10-persisted'
    $headB = (& git -C $brB rev-parse HEAD | Out-String).Trim()
    $persistDirB = Join-Path $TmpDir 'g10-persist-b'
    New-Item -ItemType Directory -Path $persistDirB -Force | Out-Null
    $persistFileB = Join-Path $persistDirB 'persisted.json'
    Set-Content -Path $persistFileB -Value '{"data":{"id":77,"identifier":"W77","title":"Persisted Task","status":"in_progress","complexity":"medium","priority":"high"}}' -Encoding UTF8 -NoNewline
    $claimB = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = "Full output saved to: $persistFileB"; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimB -Phase 'post' -ProjectDir $brB
    Assert-Exit "10b: persisted-file claim exits 0" 0 $r.ExitCode
    $cacheB = Get-Content -Raw -Path (Join-Path $brB '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10b: persisted file supplies the identifier" "TASK_IDENTIFIER=W77" $cacheB
    Assert-Contains "10b: persisted file path sets TASK_BASE_REF to HEAD" "TASK_BASE_REF=$headB" $cacheB

    # 10c: garbage stdout refreshes only TASK_BASE_REF, preserves prior TASK_ID,
    # removes the stale snapshot.
    $brC = New-GitRepo -Name 'g10-garbage'
    $headC = (& git -C $brC rev-parse HEAD | Out-String).Trim()
    Set-Content -Path (Join-Path $brC '.stride-changed-files.json') -Value '[{"path":"stale.txt","diff":"x"}]' -Encoding UTF8
    $claimC = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = 'this is not json at all'; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimC -Phase 'post' -ProjectDir $brC
    Assert-Exit "10c: garbage-stdout claim exits 0" 0 $r.ExitCode
    $cacheC = Get-Content -Raw -Path (Join-Path $brC '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10c: garbage stdout preserves the prior TASK_ID" "TASK_ID=42" $cacheC
    Assert-Contains "10c: garbage stdout still refreshes TASK_BASE_REF to HEAD" "TASK_BASE_REF=$headC" $cacheC
    if (-not (Test-Path (Join-Path $brC '.stride-changed-files.json'))) {
        Write-Host "  PASS: 10c: base-ref-only refresh removes the stale snapshot" -ForegroundColor Green
        $script:PASS++
    } else {
        Write-Host "  FAIL: 10c: stale snapshot survived the base-ref-only refresh" -ForegroundColor Red
        $script:FAIL++
    }

    # 10d: a persisted-output notice pointing at a MISSING file falls through.
    $brD = New-GitRepo -Name 'g10-missing-file'
    $headD = (& git -C $brD rev-parse HEAD | Out-String).Trim()
    $claimD = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = "Full output saved to: $TmpDir/g10-does-not-exist.json"; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimD -Phase 'post' -ProjectDir $brD
    Assert-Exit "10d: missing-persisted-file claim exits 0" 0 $r.ExitCode
    $cacheD = Get-Content -Raw -Path (Join-Path $brD '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10d: missing persisted file preserves the prior TASK_ID" "TASK_ID=42" $cacheD
    Assert-Contains "10d: missing persisted file refreshes TASK_BASE_REF to HEAD" "TASK_BASE_REF=$headD" $cacheD

    # 10e: a non-claim post invocation leaves TASK_BASE_REF untouched.
    $brE = New-GitRepo -Name 'g10-noclaim'
    $putBaseE = (& git -C $brE rev-parse 'HEAD~1' | Out-String).Trim()
    $claimE = @{ tool_input = @{ command = 'curl -X PATCH http://127.0.0.1:1/api/tasks/42/complete' } } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimE -Phase 'post' -ProjectDir $brE
    Assert-Exit "10e: complete URL exits 0" 0 $r.ExitCode
    $cacheE = Get-Content -Raw -Path (Join-Path $brE '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10e: complete URL leaves TASK_BASE_REF at the prior base ref" "TASK_BASE_REF=$putBaseE" $cacheE

    # 10f: garbage stdout in a NON-git directory writes no cache.
    $brF = Join-Path $TmpDir 'g10-nongit'
    New-Item -ItemType Directory -Path $brF -Force | Out-Null
    Set-Content -Path (Join-Path $brF '.stride.md') -Value @'
## before_doing
```bash
echo "claimed"
```
'@ -Encoding UTF8
    $claimF = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = 'not json'; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimF -Phase 'post' -ProjectDir $brF
    Assert-Exit "10f: garbage stdout in a non-git dir exits 0" 0 $r.ExitCode
    if (-not (Test-Path (Join-Path $brF '.stride-env-cache'))) {
        Write-Host "  PASS: 10f: no cache written when HEAD is unresolvable" -ForegroundColor Green
        $script:PASS++
    } else {
        Write-Host "  FAIL: 10f: cache written despite unresolvable HEAD" -ForegroundColor Red
        $script:FAIL++
    }

    # 10g: a persisted file whose content is harness preview text (not JSON).
    $brG = New-GitRepo -Name 'g10-nonjson-file'
    $headG = (& git -C $brG rev-parse HEAD | Out-String).Trim()
    $persistDirG = Join-Path $TmpDir 'g10-persist-g'
    New-Item -ItemType Directory -Path $persistDirG -Force | Out-Null
    $persistFileG = Join-Path $persistDirG 'preview.txt'
    Set-Content -Path $persistFileG -Value "... (output truncated for preview) ...`nnot valid json" -Encoding UTF8
    $claimG = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = "Full output saved to: $persistFileG"; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimG -Phase 'post' -ProjectDir $brG
    Assert-Exit "10g: non-JSON-persisted-file claim exits 0" 0 $r.ExitCode
    $cacheG = Get-Content -Raw -Path (Join-Path $brG '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10g: non-JSON persisted file preserves the prior TASK_ID" "TASK_ID=42" $cacheG
    Assert-Contains "10g: non-JSON persisted file refreshes TASK_BASE_REF to HEAD" "TASK_BASE_REF=$headG" $cacheG

    # 10h: garbage stdout with NO pre-existing cache creates one with only
    # TASK_BASE_REF (no TASK_ identity lines to preserve).
    $brH = New-GitRepo -Name 'g10-absent-cache'
    Remove-Item -Force (Join-Path $brH '.stride-env-cache') -ErrorAction SilentlyContinue
    $headH = (& git -C $brH rev-parse HEAD | Out-String).Trim()
    $claimH = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = 'garbage'; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimH -Phase 'post' -ProjectDir $brH
    Assert-Exit "10h: absent-cache claim exits 0" 0 $r.ExitCode
    $cacheH = Get-Content -Raw -Path (Join-Path $brH '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10h: absent cache is created with TASK_BASE_REF at HEAD" "TASK_BASE_REF=$headH" $cacheH
    Assert-NotContains "10h: no spurious TASK_ID line created" "TASK_ID=" $cacheH

    # 10i: a persisted-output path containing spaces is recovered intact.
    $brI = New-GitRepo -Name 'g10-spaced-path'
    $persistDirI = Join-Path $TmpDir 'g10 persist with space'
    New-Item -ItemType Directory -Path $persistDirI -Force | Out-Null
    $persistFileI = Join-Path $persistDirI 'persisted.json'
    Set-Content -Path $persistFileI -Value '{"data":{"id":88,"identifier":"W88","title":"Spaced Task","status":"in_progress","complexity":"small","priority":"low"}}' -Encoding UTF8 -NoNewline
    $claimI = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = "Full output saved to: $persistFileI"; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimI -Phase 'post' -ProjectDir $brI
    Assert-Exit "10i: spaced-path claim exits 0" 0 $r.ExitCode
    $cacheI = Get-Content -Raw -Path (Join-Path $brI '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10i: persisted path with spaces is recovered" "TASK_IDENTIFIER=W88" $cacheI

    # 10j: an id-only persisted payload (no {"data":...} envelope) caches its
    # identity lines instead of throwing under StrictMode and falling through.
    $brJ = New-GitRepo -Name 'g10-id-only'
    $headJ = (& git -C $brJ rev-parse HEAD | Out-String).Trim()
    $persistDirJ = Join-Path $TmpDir 'g10-persist-j'
    New-Item -ItemType Directory -Path $persistDirJ -Force | Out-Null
    $persistFileJ = Join-Path $persistDirJ 'persisted.json'
    Set-Content -Path $persistFileJ -Value '{"id":99,"identifier":"W99","title":"Id Only","status":"in_progress","complexity":"small","priority":"low"}' -Encoding UTF8 -NoNewline
    $claimJ = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = "Full output saved to: $persistFileJ"; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $claimJ -Phase 'post' -ProjectDir $brJ
    Assert-Exit "10j: id-only persisted payload claim exits 0" 0 $r.ExitCode
    $cacheJ = Get-Content -Raw -Path (Join-Path $brJ '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "10j: id-only persisted payload caches the identifier" "TASK_IDENTIFIER=W99" $cacheJ
    Assert-Contains "10j: id-only persisted payload sets TASK_BASE_REF to HEAD" "TASK_BASE_REF=$headJ" $cacheJ
}

# ============================================================
# Test Group 11: server hook.env forwarding (W1519)
# ============================================================
# Mirrors test-stride-hook.sh Test Group 15. The claim response's singular
# `.hook.env` and the /complete|/mark_reviewed `.hooks[].env` (for after_goal)
# are the single source of truth for the exported variables. Assert the full
# env matrix reaches the running section (not just the six-field TASK_*
# subset), that HOOK_NAME/TASK_BASE_REF stay script-owned, that GOAL_* export
# for after_goal (with the parent_id fallback), and that server-omitted keys
# become empty strings rather than errors.
Write-Host ""
Write-Host "=== Test Group 11: server hook.env forwarding (W1519) ==="

$efProj = Join-Path $TmpDir 'env-forward'
New-Item -ItemType Directory -Path $efProj -Force | Out-Null
Set-Content -Path (Join-Path $efProj '.stride.md') -Value @'
## before_doing
```bash
echo "desc=$TASK_DESCRIPTION needs=$TASK_NEEDS_REVIEW board=$BOARD_NAME agent=$AGENT_NAME"
```

## after_review
```bash
echo "after_review_ran"
```

## after_goal
```bash
echo "after_goal_ran id=$GOAL_ID ident=$GOAL_IDENTIFIER title=$GOAL_TITLE desc=[$GOAL_DESCRIPTION]"
```
'@ -Encoding UTF8

# 11a: a before_doing claim response carrying a singular `.hook.env` forwards
# TASK_DESCRIPTION/TASK_NEEDS_REVIEW/BOARD_NAME/AGENT_NAME into the section AND
# persists them to the env cache — while HOOK_NAME and TASK_BASE_REF from the
# server env are NOT applied (script-owned).
$efInnerA = @{
    data = @{ id = 42; identifier = 'W99'; title = 'Env Task'; status = 'in_progress'; complexity = 'small'; priority = 'high' }
    hook = @{ name = 'before_doing'; env = @{
        TASK_DESCRIPTION  = 'A detailed task description'
        TASK_NEEDS_REVIEW = 'false'
        BOARD_NAME        = 'Stride Development'
        COLUMN_NAME       = 'Doing'
        AGENT_NAME        = 'Claude Opus'
        HOOK_NAME         = 'before_doing'
        TASK_BASE_REF     = 'SHOULD_NOT_APPEAR'
    } }
} | ConvertTo-Json -Depth 6 -Compress
$efInputA = @{
    tool_input    = @{ command = 'curl -X POST https://stridelikeaboss.com/api/tasks/claim' }
    tool_response = @{ stdout = $efInnerA }
} | ConvertTo-Json -Depth 6 -Compress
$r = Invoke-HookScript -InputJson $efInputA -Phase 'post' -ProjectDir $efProj
Assert-Exit "11a: claim env forwarding exits 0" 0 $r.ExitCode
Assert-Contains "11a: TASK_DESCRIPTION reaches the section" "desc=A detailed task description" $r.Stdout
Assert-Contains "11a: TASK_NEEDS_REVIEW reaches the section" "needs=false" $r.Stdout
Assert-Contains "11a: BOARD_NAME reaches the section" "board=Stride Development" $r.Stdout
Assert-Contains "11a: AGENT_NAME reaches the section" "agent=Claude Opus" $r.Stdout
$efCacheA = Get-Content -Raw -Path (Join-Path $efProj '.stride-env-cache') -ErrorAction SilentlyContinue
Assert-Contains "11a: TASK_DESCRIPTION persisted to the env cache" "TASK_DESCRIPTION=" $efCacheA
Assert-Contains "11a: TASK_NEEDS_REVIEW persisted to the env cache" "TASK_NEEDS_REVIEW=" $efCacheA
Assert-Contains "11a: BOARD_NAME persisted to the env cache" "BOARD_NAME=" $efCacheA
Assert-NotContains "11a: server TASK_BASE_REF excluded from forwarding" "SHOULD_NOT_APPEAR" $efCacheA
Remove-Item -Force (Join-Path $efProj '.stride-env-cache') -ErrorAction SilentlyContinue

# 11b: after_goal routing exports the server-supplied GOAL_* into the
# after_goal section (non-empty $GOAL_IDENTIFIER / $GOAL_TITLE / $GOAL_DESCRIPTION).
$efInnerB = @{
    data  = @{ id = 99 }
    hooks = @(
        @{ name = 'after_review' },
        @{ name = 'after_goal'; env = @{ GOAL_ID = '7'; GOAL_IDENTIFIER = 'G7'; GOAL_TITLE = 'Goal Seven'; GOAL_DESCRIPTION = 'The seventh goal' } }
    )
} | ConvertTo-Json -Depth 6 -Compress
$efInputB = @{
    tool_input    = @{ command = 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/mark_reviewed' }
    tool_response = @{ stdout = $efInnerB }
} | ConvertTo-Json -Depth 6 -Compress
$r = Invoke-HookScript -InputJson $efInputB -Phase 'post' -ProjectDir $efProj
Assert-Exit "11b: after_goal env forwarding exits 0" 0 $r.ExitCode
Assert-Contains "11b: GOAL_IDENTIFIER reaches the after_goal section" "ident=G7" $r.Stdout
Assert-Contains "11b: GOAL_TITLE reaches the after_goal section" "title=Goal Seven" $r.Stdout
Assert-Contains "11b: GOAL_DESCRIPTION reaches the after_goal section" "desc=[The seventh goal]" $r.Stdout
Remove-Item -Force (Join-Path $efProj '.stride-env-cache') -ErrorAction SilentlyContinue

# 11c: after_goal entry omits GOAL_ID but the response data carries parent_id —
# GOAL_ID falls back to that parent id (response-local).
$efInnerC = @{
    data  = @{ id = 99; parent_id = 4695 }
    hooks = @(
        @{ name = 'after_review' },
        @{ name = 'after_goal'; env = @{ GOAL_IDENTIFIER = 'G7'; GOAL_TITLE = 'Goal Seven' } }
    )
} | ConvertTo-Json -Depth 6 -Compress
$efInputC = @{
    tool_input    = @{ command = 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/mark_reviewed' }
    tool_response = @{ stdout = $efInnerC }
} | ConvertTo-Json -Depth 6 -Compress
$r = Invoke-HookScript -InputJson $efInputC -Phase 'post' -ProjectDir $efProj
Assert-Exit "11c: parent_id fallback exits 0" 0 $r.ExitCode
Assert-Contains "11c: GOAL_ID falls back to data.parent_id" "id=4695" $r.Stdout
Remove-Item -Force (Join-Path $efProj '.stride-env-cache') -ErrorAction SilentlyContinue

# 11d: a server-omitted GOAL_* key exports as an empty string, never an error —
# the after_goal section runs and sees an empty $GOAL_DESCRIPTION.
$efInnerD = @{
    data  = @{ id = 99 }
    hooks = @(
        @{ name = 'after_review' },
        @{ name = 'after_goal'; env = @{ GOAL_ID = '7'; GOAL_IDENTIFIER = 'G7'; GOAL_TITLE = 'Goal Seven' } }
    )
} | ConvertTo-Json -Depth 6 -Compress
$efInputD = @{
    tool_input    = @{ command = 'curl -X PATCH https://stridelikeaboss.com/api/tasks/99/mark_reviewed' }
    tool_response = @{ stdout = $efInnerD }
} | ConvertTo-Json -Depth 6 -Compress
$r = Invoke-HookScript -InputJson $efInputD -Phase 'post' -ProjectDir $efProj
Assert-Exit "11d: omitted GOAL_DESCRIPTION does not error" 0 $r.ExitCode
Assert-Contains "11d: omitted GOAL_DESCRIPTION exports as empty string" "desc=[]" $r.Stdout
Assert-Contains "11d: supplied GOAL_IDENTIFIER still present alongside the empty key" "ident=G7" $r.Stdout
Remove-Item -Force (Join-Path $efProj '.stride-env-cache') -ErrorAction SilentlyContinue

# ============================================================
# Test Group 12: hook-executor fixes — ms durations, backslash
# line-continuation, and pre-existing-edit snapshot guard (W1520)
# ============================================================
# Mirrors test-stride-hook.sh Test Group 16.
Write-Host ""
Write-Host "=== Test Group 12: hook-executor fixes (W1520) ==="

$execProj = Join-Path $TmpDir 'exec-fixes'
New-Item -ItemType Directory -Path $execProj -Force | Out-Null
Set-Content -Path (Join-Path $execProj '.stride.md') -Value @'
## before_doing
```bash
echo "ran"
```
'@ -Encoding UTF8

# 12a: the success JSON reports duration_ms as a number (sub-second
# resolution), replacing the whole-second-only duration_seconds.
$claim12 = '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}'
$r = Invoke-HookScript -InputJson $claim12 -Phase 'post' -ProjectDir $execProj
Assert-Exit "12a: before_doing with duration_ms exits 0" 0 $r.ExitCode
$durOk = $false
try {
    $parsed12 = $r.Stdout | ConvertFrom-Json
    if ($parsed12.PSObject.Properties.Name -contains 'duration_ms' -and
        $parsed12.duration_ms -is [int64] -or $parsed12.duration_ms -is [int]) {
        if ([int64]$parsed12.duration_ms -ge 0 -and [int64]$parsed12.duration_ms -lt 60000) { $durOk = $true }
    }
} catch { $durOk = $false }
if ($durOk) {
    Write-Host "  PASS: 12a: success JSON reports a numeric duration_ms" -ForegroundColor Green
    $script:PASS++
} else {
    Write-Host "  FAIL: 12a: duration_ms missing or non-numeric: $($r.Stdout)" -ForegroundColor Red
    $script:FAIL++
}
Remove-Item -Force (Join-Path $execProj '.stride-env-cache') -ErrorAction SilentlyContinue

# 12b: a .stride.md command split across lines with a trailing backslash
# executes as ONE command. Without the join, `two` runs on its own (not found)
# and the section fails with exit 2.
$bslashProj = Join-Path $TmpDir 'backslash-cont'
New-Item -ItemType Directory -Path $bslashProj -Force | Out-Null
Set-Content -Path (Join-Path $bslashProj '.stride.md') -Value @'
## before_doing
```bash
echo one \
two
```
'@ -Encoding UTF8
$r = Invoke-HookScript -InputJson $claim12 -Phase 'post' -ProjectDir $bslashProj
Assert-Exit "12b: backslash-continued command exits 0 (joined, not split)" 0 $r.ExitCode
Assert-Contains "12b: continuation joined into one echo" "one two" $r.Stdout
Remove-Item -Force (Join-Path $bslashProj '.stride-env-cache') -ErrorAction SilentlyContinue

# 12c: a standalone comment line ending in a backslash is inert — it must NOT
# swallow the following command.
$cmtProj = Join-Path $TmpDir 'backslash-comment'
New-Item -ItemType Directory -Path $cmtProj -Force | Out-Null
Set-Content -Path (Join-Path $cmtProj '.stride.md') -Value @'
## before_doing
```bash
# a trailing-backslash comment \
echo after_comment
```
'@ -Encoding UTF8
$r = Invoke-HookScript -InputJson $claim12 -Phase 'post' -ProjectDir $cmtProj
Assert-Exit "12c: comment-with-backslash exits 0" 0 $r.ExitCode
Assert-Contains "12c: comment did not swallow the next command" "after_comment" $r.Stdout
Remove-Item -Force (Join-Path $cmtProj '.stride-env-cache') -ErrorAction SilentlyContinue

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "  SKIP: 12d/12e dirty-baseline tests (git not available)" -ForegroundColor Yellow
} else {
    # 12d: pre-existing-edit snapshot guard at upload time — a file whose path
    # was dirty at claim AND is hash-identical now is filtered out of the PUT
    # body; a task-introduced file is kept.
    $dbProj = Join-Path $TmpDir 'dirty-baseline-filter'
    New-Item -ItemType Directory -Path $dbProj -Force | Out-Null
    & git -C $dbProj init -q 2>$null | Out-Null
    & git -C $dbProj config user.email 'test@test.local' 2>$null | Out-Null
    & git -C $dbProj config user.name 'Test' 2>$null | Out-Null
    Set-Content -Path (Join-Path $dbProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8
    Set-Content -Path (Join-Path $dbProj 'pre_existing.txt') -Value 'dirty-at-claim' -Encoding UTF8 -NoNewline
    Set-Content -Path (Join-Path $dbProj 'task_file.txt') -Value 'task-content' -Encoding UTF8 -NoNewline
    $preHash = (& git -C $dbProj hash-object 'pre_existing.txt' | Out-String).Trim()
    # Baseline lists pre_existing.txt at its CURRENT hash (matches -> excluded);
    # task_file.txt is absent from the baseline (kept).
    Set-Content -Path (Join-Path $dbProj '.stride-dirty-baseline') -Value "$preHash pre_existing.txt" -Encoding UTF8
    Set-Content -Path (Join-Path $dbProj '.stride-changed-files.json') `
        -Value '[{"path":"pre_existing.txt","diff":"pre body"},{"path":"task_file.txt","diff":"task body"}]' -Encoding UTF8
    Set-Content -Path (Join-Path $dbProj '.stride-env-cache') -Value "TASK_ID=99`nTASK_BASE_REF=abc" -Encoding UTF8

    $dbPort = 18893
    $dbFixture = Join-Path $TmpDir 'dirty-baseline-fixture.json'
    if (Test-Path $dbFixture) { Remove-Item -Force $dbFixture }
    $dbListenerJob = Start-Job -ArgumentList $dbPort, $dbFixture -ScriptBlock {
        param($Port, $Fixture)
        $l = [System.Net.HttpListener]::new()
        $l.Prefixes.Add("http://localhost:$Port/")
        try {
            $l.Start()
            $ctx = $l.GetContext()
            $reader = [System.IO.StreamReader]::new($ctx.Request.InputStream)
            $body = $reader.ReadToEnd()
            @{ Body = $body } | ConvertTo-Json -Compress | Set-Content -Path $Fixture -Encoding UTF8
            $ctx.Response.StatusCode = 200
            $ctx.Response.OutputStream.Close()
        } catch {
        } finally {
            if ($l.IsListening) { $l.Stop() }
        }
    }
    try {
        $null = Wait-ForListener -Port $dbPort
        $dbCmd = "curl -X PATCH http://localhost:$dbPort/api/tasks/99/complete -H `"Authorization: Bearer test_token_xyz`""
        $dbJson = @{ tool_input = @{ command = $dbCmd } } | ConvertTo-Json -Compress
        $r = Invoke-HookScript -InputJson $dbJson -Phase 'pre' -ProjectDir $dbProj
        Assert-Exit "12d: hook exits 0 after filtered PUT" 0 $r.ExitCode
        Wait-Job $dbListenerJob -Timeout 8 | Out-Null
        Remove-Job $dbListenerJob -Force -ErrorAction SilentlyContinue
        if (Test-Path $dbFixture) {
            $record = Get-Content -Raw -Path $dbFixture | ConvertFrom-Json
            $parsedBody = $record.Body | ConvertFrom-Json
            $decoded = [System.Convert]::FromBase64String($parsedBody.changed_files.data)
            $entries = @(([System.Text.Encoding]::UTF8.GetString($decoded)) | ConvertFrom-Json)
            $paths = @($entries | ForEach-Object { $_.path })
            if ($paths -contains 'task_file.txt') {
                Write-Host "  PASS: 12d: task-introduced file survives the baseline filter" -ForegroundColor Green
                $script:PASS++
            } else {
                Write-Host "  FAIL: 12d: task_file.txt was dropped: $($paths -join ', ')" -ForegroundColor Red
                $script:FAIL++
            }
            if ($paths -notcontains 'pre_existing.txt') {
                Write-Host "  PASS: 12d: pre-existing dirty file excluded from PUT body" -ForegroundColor Green
                $script:PASS++
            } else {
                Write-Host "  FAIL: 12d: pre-existing dirty file leaked into PUT body: $($paths -join ', ')" -ForegroundColor Red
                $script:FAIL++
            }
        } else {
            Write-Host "  FAIL: 12d: filtered PUT did not arrive at listener" -ForegroundColor Red
            $script:FAIL++
        }
    } finally {
        if ($dbListenerJob -and $dbListenerJob.State -eq 'Running') {
            Stop-Job $dbListenerJob -ErrorAction SilentlyContinue
            Remove-Job $dbListenerJob -Force -ErrorAction SilentlyContinue
        }
    }

    # 12e: Write-DirtyBaseline fires end-to-end at claim time — a claim in a
    # repo with a pre-existing dirty file writes the .stride-dirty-baseline.
    $blRepo = New-GitRepo -Name 'g12-baseline'
    Set-Content -Path (Join-Path $blRepo 'preexisting_dirty.txt') -Value 'dirty' -Encoding UTF8 -NoNewline
    $blClaim = '{"tool_input":{"command":"curl -X POST https://stride.example.com/api/tasks/claim"},"tool_response":{"stdout":"{\"data\":{\"id\":42,\"identifier\":\"W42\",\"title\":\"T\",\"status\":\"in_progress\",\"complexity\":\"small\",\"priority\":\"low\"}}","stderr":"","interrupted":false}}'
    $null = Invoke-HookScript -InputJson $blClaim -Phase 'post' -ProjectDir $blRepo
    $blFile = Join-Path $blRepo '.stride-dirty-baseline'
    if ((Test-Path $blFile) -and ((Get-Content -Raw $blFile) -match 'preexisting_dirty\.txt')) {
        Write-Host "  PASS: 12e: claim records the dirty baseline end-to-end" -ForegroundColor Green
        $script:PASS++
    } else {
        Write-Host "  FAIL: 12e: claim did not record .stride-dirty-baseline" -ForegroundColor Red
        $script:FAIL++
    }
}

# ============================================================
# Test Group 13: D142 — post-pull TASK_BASE_REF + committed-range override
# (mirrors test-stride-hook.sh Test Group 17)
# ============================================================
Write-Host ""
Write-Host "=== Test Group 13: D142 post-pull TASK_BASE_REF + committed-range override ==="

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "  SKIP: git not available — Group 13 requires it" -ForegroundColor Yellow
} else {
    # 13a: the claim-time refresh records the POST-pull branch point. A bare
    # origin and a second clone simulate another computer whose completed task
    # arrives via the ## before_doing pull (the D132/W1678 incident).
    $d142Root = Join-Path $TmpDir 'g13-d142'
    New-Item -ItemType Directory -Path $d142Root -Force | Out-Null
    & git init -q --bare (Join-Path $d142Root 'origin.git') 2>$null | Out-Null
    & git -C (Join-Path $d142Root 'origin.git') symbolic-ref HEAD refs/heads/main 2>$null | Out-Null
    $cloneA = Join-Path $d142Root 'cloneA'
    & git clone -q (Join-Path $d142Root 'origin.git') $cloneA 2>$null | Out-Null
    & git -C $cloneA config user.email 'test@test.local' 2>$null | Out-Null
    & git -C $cloneA config user.name 'Test' 2>$null | Out-Null
    & git -C $cloneA config commit.gpgsign false 2>$null | Out-Null
    & git -C $cloneA checkout -q -b main 2>$null | Out-Null
    Set-Content -Path (Join-Path $cloneA '.gitignore') `
        -Value ".stride.md`n.stride-env-cache`n.stride-changed-files.json`n.stride-diff-upload-state`n.stride-dirty-baseline" -Encoding UTF8
    Set-Content -Path (Join-Path $cloneA 'base.txt') -Value 'base' -Encoding UTF8
    & git -C $cloneA add .gitignore base.txt 2>$null | Out-Null
    & git -C $cloneA commit -q -m 'base' 2>$null | Out-Null
    & git -C $cloneA push -q origin main 2>$null | Out-Null
    $cloneB = Join-Path $d142Root 'cloneB'
    & git clone -q (Join-Path $d142Root 'origin.git') $cloneB 2>$null | Out-Null
    & git -C $cloneB config user.email 'test@test.local' 2>$null | Out-Null
    & git -C $cloneB config user.name 'Test' 2>$null | Out-Null
    & git -C $cloneB config commit.gpgsign false 2>$null | Out-Null
    Set-Content -Path (Join-Path $cloneB 'w1678.txt') -Value 'other' -Encoding UTF8
    & git -C $cloneB add w1678.txt 2>$null | Out-Null
    & git -C $cloneB commit -q -m 'other clone task' 2>$null | Out-Null
    & git -C $cloneB push -q origin main 2>$null | Out-Null

    $prePull = (& git -C $cloneA rev-parse HEAD | Out-String).Trim()
    Set-Content -Path (Join-Path $cloneA '.stride.md') -Value @'
## before_doing
```bash
git pull -q origin main
```
'@ -Encoding UTF8
    Set-Content -Path (Join-Path $cloneA '.stride-env-cache') `
        -Value "TASK_ID=OLD1`nTASK_BASE_REF=1111111111111111111111111111111111111111" -Encoding UTF8
    $d142Claim = @{
        tool_input = @{ command = 'curl -X POST https://stride.example.com/api/tasks/claim' }
        tool_response = @{ stdout = '{"data":{"id":142,"identifier":"D142","title":"Cross clone","status":"in_progress","complexity":"medium","priority":"high"}}'; stderr = ''; interrupted = $false }
    } | ConvertTo-Json -Compress
    $r = Invoke-HookScript -InputJson $d142Claim -Phase 'post' -ProjectDir $cloneA
    Assert-Exit "13a: cross-clone claim exits 0" 0 $r.ExitCode
    $postPull = (& git -C $cloneA rev-parse HEAD | Out-String).Trim()
    if ($prePull -eq $postPull) {
        Write-Host "  FAIL: 13a fixture vacuous — the before_doing pull did not move HEAD" -ForegroundColor Red
        $script:FAIL++
    } else {
        Write-Host "  PASS: 13a fixture: the before_doing pull moved HEAD (discriminating power)" -ForegroundColor Green
        $script:PASS++
    }
    $d142Cache = Get-Content -Raw -Path (Join-Path $cloneA '.stride-env-cache') -ErrorAction SilentlyContinue
    Assert-Contains "13a: claim records the POST-pull branch point as TASK_BASE_REF" "TASK_BASE_REF=$postPull" $d142Cache
    Assert-NotContains "13a: the stale prior-session TASK_BASE_REF was replaced" "1111111111111111111111111111111111111111" $d142Cache

    # 13b: committed-range override — a baseline entry whose path the task's
    # commits contain is task work and must survive the upload filter (D137).
    $crProj = Join-Path $TmpDir 'g13-committed'
    New-Item -ItemType Directory -Path $crProj -Force | Out-Null
    & git -C $crProj init -q 2>$null | Out-Null
    & git -C $crProj config user.email 'test@test.local' 2>$null | Out-Null
    & git -C $crProj config user.name 'Test' 2>$null | Out-Null
    & git -C $crProj config commit.gpgsign false 2>$null | Out-Null
    Set-Content -Path (Join-Path $crProj 'tracked.txt') -Value 'v1' -Encoding UTF8
    & git -C $crProj add tracked.txt 2>$null | Out-Null
    & git -C $crProj commit -q -m 'v1' 2>$null | Out-Null
    $crBase = (& git -C $crProj rev-parse HEAD | Out-String).Trim()
    # Pre-claim dirt, then the auto-commit commits it as the task's work.
    Add-Content -Path (Join-Path $crProj 'tracked.txt') -Value 'task edit present at claim' -Encoding UTF8
    $crHash = (& git -C $crProj hash-object -- 'tracked.txt' | Out-String).Trim()
    Set-Content -Path (Join-Path $crProj '.stride-dirty-baseline') -Value "$crHash tracked.txt" -Encoding UTF8
    & git -C $crProj add tracked.txt 2>$null | Out-Null
    & git -C $crProj commit -q -m 'task auto-commit' 2>$null | Out-Null
    Set-Content -Path (Join-Path $crProj '.stride-changed-files.json') `
        -Value '[{"path":"tracked.txt","diff":"task work"}]' -Encoding UTF8
    Set-Content -Path (Join-Path $crProj '.stride-env-cache') `
        -Value "TASK_ID=99`nTASK_BASE_REF=$crBase" -Encoding UTF8
    Set-Content -Path (Join-Path $crProj '.stride.md') -Value @'
## after_doing
```bash
echo "ran"
```
'@ -Encoding UTF8

    $crPort = 18893
    $crFixture = Join-Path $TmpDir 'd142-put-fixture.json'
    if (Test-Path $crFixture) { Remove-Item -Force $crFixture }
    $crListenerJob = Start-Job -ArgumentList $crPort, $crFixture -ScriptBlock {
        param($Port, $Fixture)
        $l = [System.Net.HttpListener]::new()
        $l.Prefixes.Add("http://localhost:$Port/")
        try {
            $l.Start()
            $ctx = $l.GetContext()
            $req = $ctx.Request
            $reader = [System.IO.StreamReader]::new($req.InputStream)
            $body = $reader.ReadToEnd()
            @{ Body = $body } | ConvertTo-Json -Compress | Set-Content -Path $Fixture -Encoding UTF8
            $resp = $ctx.Response
            $resp.StatusCode = 200
            $resp.OutputStream.Close()
        } catch {
            # Listener tear-down errors are ignored.
        } finally {
            if ($l.IsListening) { $l.Stop() }
        }
    }
    try {
        $null = Wait-ForListener -Port $crPort
        $crCmd = "curl -X PATCH http://localhost:$crPort/api/tasks/99/complete -H `"Authorization: Bearer test_token_cr`""
        $crJson = @{ tool_input = @{ command = $crCmd } } | ConvertTo-Json -Compress
        $r = Invoke-HookScript -InputJson $crJson -Phase 'pre' -ProjectDir $crProj
        Assert-Exit "13b: hook exits 0 after the committed-range PUT" 0 $r.ExitCode

        Wait-Job $crListenerJob -Timeout 8 | Out-Null
        Remove-Job $crListenerJob -Force -ErrorAction SilentlyContinue

        if (Test-Path $crFixture) {
            $record = Get-Content -Raw -Path $crFixture | ConvertFrom-Json
            $parsedBody = $record.Body | ConvertFrom-Json
            $decoded = [System.Convert]::FromBase64String($parsedBody.changed_files.data)
            $decodedText = [System.Text.Encoding]::UTF8.GetString($decoded)
            $entries = @($decodedText | ConvertFrom-Json)
            $paths = @($entries | ForEach-Object { $_.path })
            if ($paths -contains 'tracked.txt') {
                Write-Host "  PASS: 13b: committed task work survives the baseline filter" -ForegroundColor Green
                $script:PASS++
            } else {
                Write-Host "  FAIL: 13b: committed task work was dropped, got: $($paths -join ', ')" -ForegroundColor Red
                $script:FAIL++
            }
        } else {
            Write-Host "  FAIL: 13b: no PUT recorded by the listener" -ForegroundColor Red
            $script:FAIL++
        }
    } finally {
        Remove-Job $crListenerJob -Force -ErrorAction SilentlyContinue
    }
}

# ============================================================
# Summary
# ============================================================
Write-Host ""
Write-Host "========================================"
$Total = $script:PASS + $script:FAIL
Write-Host "Results: $($script:PASS) passed, $($script:FAIL) failed (out of $Total)"
Write-Host "========================================"

} finally {
    # Cleanup
    Remove-Item -Recurse -Force $TmpDir -ErrorAction SilentlyContinue
}

if ($script:FAIL -gt 0) { exit 1 } else { exit 0 }
