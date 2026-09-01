# test-stride-hook.ps1 — Tests for stride-hook.ps1 PowerShell hook script
#
# Mirrors the test groups in test-stride-hook.sh; Test Group 14 here is the
# case-for-case mirror of that suite's Test Group 18 (W2144 loop state).
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
# Test Group 14: loop state on completion (W2144)
# ============================================================
# Case-for-case mirror of test-stride-hook.sh Test Group 18. The three cases
# that suite documents as deliberately NOT ported from the Claude Code original
# (33g/33h/33i, all Tier-2 snapshot-recovery guards for machinery this port
# does not have) are absent here for the same reason — see the comment block at
# the head of that group.
Write-Host ""
Write-Host "=== Test Group 14: loop state on completion (W2144) ==="

$g14IsWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows)

# curl is stubbed so the changed_files self-heal makes no network call: these
# cases are about the loop-state record, and a real curl would make them slow
# and non-deterministic. Windows keeps the real curl — the stub is a shell
# script — which costs only a little time on that platform.
$g14OldPath = $env:PATH
$g14Stub = Join-Path $TmpDir 'g14stub'
New-Item -ItemType Directory -Path $g14Stub -Force | Out-Null
if (-not $g14IsWindows) {
    [System.IO.File]::WriteAllText((Join-Path $g14Stub 'curl'), "#!/usr/bin/env bash`nexit 0`n")
    & chmod '+x' (Join-Path $g14Stub 'curl')
    $env:PATH = $g14Stub + [System.IO.Path]::PathSeparator + $env:PATH
}

function New-G14Proj {
    $d = Join-Path $TmpDir ("g14-" + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $d '.stride.md'),
        "## before_doing`n``````bash`n``````n`n## before_review`n``````bash`n``````n")
    return $d
}
function New-G14Input {
    param([string]$SessionId, [string]$Command, [string]$Payload,
          [switch]$NoSessionId, [switch]$NoResponse)
    $o = [ordered]@{}
    if (-not $NoSessionId) { $o['session_id'] = $SessionId }
    $o['tool_input'] = [ordered]@{ command = $Command }
    if (-not $NoResponse) { $o['tool_response'] = [ordered]@{ stdout = $Payload } }
    return ($o | ConvertTo-Json -Compress -Depth 6)
}
function Get-G14StatePath { param([string]$Dir) return (Join-Path (Join-Path $Dir '.stride') '.loop-state.json') }
function Get-G14Presence  { param([string]$Dir) if (Test-Path -LiteralPath (Get-G14StatePath $Dir)) { return 'present' } else { return 'absent' } }
function Read-G14State    { param([string]$Dir) return (Get-Content -Raw -LiteralPath (Get-G14StatePath $Dir) | ConvertFrom-Json) }

$g14Cmd    = 'curl -X PATCH https://stride.invalid/api/tasks/99/complete -H "Authorization: Bearer SECRETVALUE"'
$g14Claim  = 'curl -X POST https://stride.invalid/api/tasks/claim'
$g14Ok     = '{"data":{"id":99,"identifier":"W2144","needs_review":false},"hooks":[{"name":"before_review"}]}'
$g14OkTrue = '{"data":{"id":99,"identifier":"W2144","needs_review":true},"hooks":[{"name":"before_review"}]}'
$g14_422   = '{"errors":{"base":["completion is invalid"]}}'

try {
    # Session-id env vars must not leak in from the ambient environment.
    Remove-Item Env:\GEMINI_SESSION_ID -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_SESSION_ID -ErrorAction SilentlyContinue

    # 14a: a successful completion records all four fields
    $d = New-G14Proj
    $null = Invoke-HookScript -InputJson (New-G14Input -SessionId 'sess-abc' -Command $g14Cmd -Payload $g14Ok) -Phase 'post' -ProjectDir $d
    $j = Read-G14State $d
    Assert-Eq "14a: records the identifier" "W2144" $j.identifier
    Assert-Eq "14a: records needs_review false" "False" ([string]$j.needs_review)
    Assert-Eq "14a: records the session id" "sess-abc" $j.session_id
    # Asserted against the RAW file text, never the parsed object: PowerShell's
    # ConvertFrom-Json silently converts an ISO-8601 string into a [DateTime],
    # so $j.completed_at would be matched in the host's local format and the
    # on-disk shape - the thing the other half has to agree with - would go
    # untested.
    Assert-Eq "14a: completed_at is ISO8601 Z" $true `
        ((Get-Content -Raw -LiteralPath (Get-G14StatePath $d)) -cmatch '"completed_at":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z"')

    # 14b: needs_review=true is recorded verbatim AND as a real boolean. The
    # type assert is the point: a quoted "true" would stringify identically.
    $d = New-G14Proj
    $null = Invoke-HookScript -InputJson (New-G14Input -SessionId 'sess-b' -Command $g14Cmd -Payload $g14OkTrue) -Phase 'post' -ProjectDir $d
    $j = Read-G14State $d
    Assert-Eq "14b: needs_review true recorded" "True" ([string]$j.needs_review)
    Assert-Eq "14b: needs_review is a boolean, not a string" "Boolean" $j.needs_review.GetType().Name

    # 14b2: a STRING "true" in the response is refused outright
    $d = New-G14Proj
    $null = Invoke-HookScript -InputJson (New-G14Input -SessionId 'sess-b2' -Command $g14Cmd -Payload '{"data":{"id":9,"identifier":"W9","needs_review":"true"}}') -Phase 'post' -ProjectDir $d
    Assert-Eq "14b2: a quoted needs_review is refused, nothing recorded" "absent" (Get-G14Presence $d)

    # 14c: the session id falls back to the environment when the input omits it
    $noSid = New-G14Input -NoSessionId -Command $g14Cmd -Payload $g14Ok
    $d = New-G14Proj
    $env:CLAUDE_SESSION_ID = 'env-sess'
    $null = Invoke-HookScript -InputJson $noSid -Phase 'post' -ProjectDir $d
    Assert-Eq "14c: falls back to CLAUDE_SESSION_ID" "env-sess" (Read-G14State $d).session_id
    $d = New-G14Proj
    $env:GEMINI_SESSION_ID = 'gem-sess'
    $null = Invoke-HookScript -InputJson $noSid -Phase 'post' -ProjectDir $d
    Assert-Eq "14c: GEMINI_SESSION_ID wins over CLAUDE_SESSION_ID" "gem-sess" (Read-G14State $d).session_id
    Remove-Item Env:\GEMINI_SESSION_ID -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_SESSION_ID -ErrorAction SilentlyContinue

    # 14d: an absent session id degrades to "unknown" rather than dropping the record
    $d = New-G14Proj
    $null = Invoke-HookScript -InputJson $noSid -Phase 'post' -ProjectDir $d
    $j = Read-G14State $d
    Assert-Eq "14d: absent session id degrades to unknown" "unknown" $j.session_id
    Assert-Eq "14d: the record is still written" "W2144" $j.identifier

    # 14e: a non-identifier-shaped session id degrades to "unknown", never recorded raw
    $d = New-G14Proj
    $null = Invoke-HookScript -InputJson (New-G14Input -SessionId 'not a/session id' -Command $g14Cmd -Payload $g14Ok) -Phase 'post' -ProjectDir $d
    Assert-Eq "14e: unsafe session id degrades to unknown" "unknown" (Read-G14State $d).session_id

    # 14f: a 422 completion does NOT write the record, and is not announced
    $d = New-G14Proj
    $r = Invoke-HookScript -InputJson (New-G14Input -SessionId 'sess-f' -Command $g14Cmd -Payload $g14_422) -Phase 'post' -ProjectDir $d
    Assert-Eq "14f: a 422 completion writes nothing" "absent" (Get-G14Presence $d)
    Assert-NotContains "14f: a well-formed 422 is not announced as unparsable" "unparsable" $r.Stderr

    # 14g: a successful claim clears a previous completion's record
    $d = New-G14Proj
    New-Item -ItemType Directory -Path (Join-Path $d '.stride') -Force | Out-Null
    [System.IO.File]::WriteAllText((Get-G14StatePath $d), '{"identifier":"W_OLD","needs_review":false,"completed_at":"2026-01-01T00:00:00Z","session_id":"old"}' + "`n")
    $null = Invoke-HookScript -InputJson (New-G14Input -SessionId 'sess-g' -Command $g14Claim -Payload '{"data":{"id":1,"identifier":"W1"}}') -Phase 'post' -ProjectDir $d
    Assert-Eq "14g: a claim clears the record" "absent" (Get-G14Presence $d)

    # 14h: the writer's mechanics, asserted structurally on the source. The
    # forbidden writers are the ones that would silently break byte-identity:
    # Set-Content and Out-File append [Environment]::NewLine (CRLF on Windows)
    # and, under Windows PowerShell 5.1, -Encoding UTF8 emits a BOM.
    $g14Src = Get-Content -Raw -LiteralPath $HookScript
    $g14Fn = [regex]::Match($g14Src, '(?ms)^function Write-LoopState \{.*?^\}').Value
    # Comments are stripped before the NotContains checks below: the writer's
    # own commentary NAMES the forbidden writers in order to explain why they
    # are forbidden, and an unstripped body would match on that prose rather
    # than on a real call.
    $g14FnCode = (($g14Fn -split "`n") | Where-Object { $_.TrimStart() -notlike '#*' }) -join "`n"
    Assert-Eq "14h: the writer produced a body to inspect" $true ($g14Fn.Length -gt 0)
    Assert-Contains "14h: writes via WriteAllText (no BOM, explicit LF)" "System.IO.File]::WriteAllText" $g14FnCode
    Assert-NotContains "14h: never uses Set-Content" "Set-Content" $g14FnCode
    Assert-NotContains "14h: never uses Out-File" "Out-File" $g14FnCode
    Assert-NotContains "14h: never writes to stdout" "Write-Output" $g14FnCode
    $d = New-G14Proj
    $null = Invoke-HookScript -InputJson (New-G14Input -SessionId 'sess-h' -Command $g14Cmd -Payload $g14Ok) -Phase 'post' -ProjectDir $d
    Assert-Eq "14h: a successful write leaves no temp behind" 0 `
        (@(Get-ChildItem -LiteralPath (Join-Path $d '.stride') -Filter 'loop-state.*' -ErrorAction SilentlyContinue)).Count

    # 14i: exactly the four documented keys, and never the Bearer token
    $d = New-G14Proj
    $null = Invoke-HookScript -InputJson (New-G14Input -SessionId 'sess-i' -Command $g14Cmd -Payload $g14Ok) -Phase 'post' -ProjectDir $d
    $j = Read-G14State $d
    Assert-Eq "14i: exactly the four documented keys" "completed_at identifier needs_review session_id" `
        (($j.PSObject.Properties.Name | Sort-Object) -join ' ')
    $g14Raw = Get-Content -Raw -LiteralPath (Get-G14StatePath $d)
    Assert-NotContains "14i: the token never reaches the record (value)" "SECRETVALUE" $g14Raw
    Assert-NotContains "14i: the token never reaches the record (scheme)" "Bearer" $g14Raw

    # 14j: an unwritable .stride/ is announced and never fails the completion
    if ($g14IsWindows) {
        Write-Host "  SKIP: 14j (POSIX mode bits unavailable on Windows)"
    } else {
        $d = New-G14Proj
        New-Item -ItemType Directory -Path (Join-Path $d '.stride') -Force | Out-Null
        & chmod '500' (Join-Path $d '.stride')
        $r = Invoke-HookScript -InputJson (New-G14Input -SessionId 'sess-j' -Command $g14Cmd -Payload $g14Ok) -Phase 'post' -ProjectDir $d
        Assert-Exit "14j: an unwritable .stride/ still exits 0" 0 $r.ExitCode
        Assert-Contains "14j: the failure is announced on stderr" "loop state" $r.Stderr
        Assert-Eq "14j: nothing was recorded" "absent" (Get-G14Presence $d)
        & chmod '700' (Join-Path $d '.stride')
    }

    # 14k: the claim -> complete -> claim cycle leaves absent, present, absent
    $d = New-G14Proj
    $null = Invoke-HookScript -InputJson (New-G14Input -SessionId 'sess-k' -Command $g14Claim -Payload '{"data":{"id":1,"identifier":"W1"}}') -Phase 'post' -ProjectDir $d
    $k1 = Get-G14Presence $d
    $null = Invoke-HookScript -InputJson (New-G14Input -SessionId 'sess-k' -Command $g14Cmd -Payload $g14Ok) -Phase 'post' -ProjectDir $d
    $k2 = Get-G14Presence $d
    $null = Invoke-HookScript -InputJson (New-G14Input -SessionId 'sess-k' -Command $g14Claim -Payload '{"data":{"id":2,"identifier":"W2"}}') -Phase 'post' -ProjectDir $d
    $k3 = Get-G14Presence $d
    Assert-Eq "14k: claim/complete/claim cycles absent-present-absent" "absent present absent" "$k1 $k2 $k3"

    # 14l: a failed or unparsable claim STILL clears — the safe direction
    foreach ($g14Body in @('{"errors":{"base":["no task available"]}}', '{"data":{"identi')) {
        $d = New-G14Proj
        New-Item -ItemType Directory -Path (Join-Path $d '.stride') -Force | Out-Null
        [System.IO.File]::WriteAllText((Get-G14StatePath $d), '{"identifier":"W_OLD","needs_review":false,"completed_at":"2026-01-01T00:00:00Z","session_id":"old"}' + "`n")
        $null = Invoke-HookScript -InputJson (New-G14Input -SessionId 'sess-l' -Command $g14Claim -Payload $g14Body) -Phase 'post' -ProjectDir $d
        Assert-Eq "14l: a failed/unparsable claim still clears the record" "absent" (Get-G14Presence $d)
    }

    # 14m: an absent tool_response records nothing and is NOT announced as
    # unparsable — "no body at all" must stay out of a channel claiming a body
    # failed to parse. This is exactly why Get-CompletionRawBody exists.
    $d = New-G14Proj
    $r = Invoke-HookScript -InputJson (New-G14Input -SessionId 'sess-m' -Command $g14Cmd -NoResponse) -Phase 'post' -ProjectDir $d
    Assert-Exit "14m: an absent tool_response exits 0" 0 $r.ExitCode
    Assert-Eq "14m: nothing recorded" "absent" (Get-G14Presence $d)
    Assert-NotContains "14m: not announced as unparsable" "unparsable" $r.Stderr

    # 14n: a truncated completion body records nothing and IS announced
    $d = New-G14Proj
    $r = Invoke-HookScript -InputJson (New-G14Input -SessionId 'sess-n' -Command $g14Cmd -Payload '{"data":{"identifier":"W2 TRUNCA') -Phase 'post' -ProjectDir $d
    Assert-Eq "14n: a truncated body records nothing" "absent" (Get-G14Presence $d)
    Assert-Contains "14n: a truncated body is announced as unparsable" "unparsable" $r.Stderr

    # 14o: the exact input class where the two shells can silently disagree.
    # bash reads values through $( ), which strips every trailing newline;
    # ConvertTo-LoopStateValue strips trailing LFs so both agree. An INTERIOR
    # newline is refused by both.
    $d = New-G14Proj
    $null = Invoke-HookScript -InputJson (New-G14Input -SessionId "trail-nl`n" -Command $g14Cmd -Payload $g14Ok) -Phase 'post' -ProjectDir $d
    Assert-Eq "14o: a trailing newline in the session id is stripped, not refused" "trail-nl" (Read-G14State $d).session_id
    $d = New-G14Proj
    $null = Invoke-HookScript -InputJson (New-G14Input -SessionId "a`nb" -Command $g14Cmd -Payload $g14Ok) -Phase 'post' -ProjectDir $d
    Assert-Eq "14o: an interior newline is refused" "unknown" (Read-G14State $d).session_id

    # 14p: AC5 — both halves produce a byte-identical record for the same input.
    # The mirror image of test-stride-hook.sh 18p, driven from this side.
    $g14Bash = Get-Command bash -ErrorAction SilentlyContinue
    $g14ShHook = Join-Path $ScriptDir 'stride-hook.sh'
    if (-not $g14Bash -or -not (Test-Path -LiteralPath $g14ShHook)) {
        Write-Host "  SKIP: 14p cross-half byte-identity (bash not available — AC5 is still covered on this host by 14u, which pins the same on-disk shape without the other half)"
    } else {
        $dA = New-G14Proj
        $dB = New-G14Proj
        $g14In = New-G14Input -SessionId 'sess-p' -Command $g14Cmd -Payload $g14OkTrue
        $null = Invoke-HookScript -InputJson $g14In -Phase 'post' -ProjectDir $dB
        $env:GEMINI_PROJECT_DIR = $dA
        $null = ($g14In | & bash $g14ShHook post 2>&1)
        Remove-Item Env:\GEMINI_PROJECT_DIR -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath (Get-G14StatePath $dA))) {
            Assert-Eq "14p: the bash half wrote a record" "present" "absent"
        } else {
            $bytesA = [System.IO.File]::ReadAllBytes((Get-G14StatePath $dA))
            $bytesB = [System.IO.File]::ReadAllBytes((Get-G14StatePath $dB))
            $textA = [System.Text.Encoding]::UTF8.GetString($bytesA)
            $textB = [System.Text.Encoding]::UTF8.GetString($bytesB)
            # A fixed-length timestamp plus an identical remainder means an
            # identical byte layout, so substituting a constant is sound.
            $normA = [regex]::Replace($textA, '"completed_at":"[^"]*"', '"completed_at":"TS"')
            $normB = [regex]::Replace($textB, '"completed_at":"[^"]*"', '"completed_at":"TS"')
            Assert-Eq "14p: both halves produce a byte-identical record" $normA $normB
            Assert-Eq "14p: both records are the same size" $bytesA.Length $bytesB.Length
            Assert-Eq "14p: the PowerShell record has no BOM" $false `
                ($bytesB.Length -ge 3 -and $bytesB[0] -eq 0xEF -and $bytesB[1] -eq 0xBB -and $bytesB[2] -eq 0xBF)
            Assert-Eq "14p: the PowerShell record has no CR" 0 (@($bytesB | Where-Object { $_ -eq 13 })).Count
            Assert-Eq "14p: the PowerShell record ends in exactly one LF" 10 $bytesB[$bytesB.Length - 1]
        }
    }
    # 14q: the OVERWRITE path — a completion over an EXISTING record. Without
    # this the File::Replace branch (added to avoid .NET Framework's
    # delete-then-move window) never executes, and AC2's atomicity is asserted
    # only structurally. This is the case atomicity is actually about.
    $d = New-G14Proj
    New-Item -ItemType Directory -Path (Join-Path $d '.stride') -Force | Out-Null
    [System.IO.File]::WriteAllText((Get-G14StatePath $d), '{"identifier":"W_OLD","needs_review":true,"completed_at":"2026-01-01T00:00:00Z","session_id":"old"}' + "`n")
    $null = Invoke-HookScript -InputJson (New-G14Input -SessionId 'sess-q' -Command $g14Cmd -Payload $g14Ok) -Phase 'post' -ProjectDir $d
    $j = Read-G14State $d
    Assert-Eq "14q: a completion overwrites an existing record" "W2144" $j.identifier
    Assert-Eq "14q: the overwritten record carries the new needs_review" "False" ([string]$j.needs_review)
    Assert-Eq "14q: the overwritten record carries the new session id" "sess-q" $j.session_id
    Assert-Eq "14q: the overwrite leaves no temp behind" 0 `
        (@(Get-ChildItem -LiteralPath (Join-Path $d '.stride') -Filter 'loop-state.*' -ErrorAction SilentlyContinue)).Count

    # 14r: an accented identifier is refused. The twin's gate was locale-
    # dependent (a collation-ordered glob range accepted these on bash 3.2
    # under UTF-8) while this side's -cmatch is codepoint-based; both now
    # refuse, and this case pins the agreeing half.
    $d = New-G14Proj
    $null = Invoke-HookScript -InputJson (New-G14Input -SessionId 'sess-r' -Command $g14Cmd -Payload '{"data":{"id":9,"identifier":"Wé144","needs_review":true}}') -Phase 'post' -ProjectDir $d
    Assert-Eq "14r: an accented identifier is refused" "absent" (Get-G14Presence $d)

    # 14s: session-id TYPE parity with jq — the ladder in
    # Write-LoopStateForCompletion. A bare [string] cast fails all three.
    $d = New-G14Proj
    $env:CLAUDE_SESSION_ID = 'env-sess'
    $null = Invoke-HookScript -InputJson '{"session_id":["abc"],"tool_input":{"command":"c /api/tasks/99/complete"},"tool_response":{"stdout":"{\"data\":{\"id\":99,\"identifier\":\"W2144\",\"needs_review\":false}}"}}' -Phase 'post' -ProjectDir $d
    Assert-Eq "14s: an array session id degrades to unknown, never the env value" "unknown" (Read-G14State $d).session_id
    $d = New-G14Proj
    $null = Invoke-HookScript -InputJson '{"session_id":12345,"tool_input":{"command":"c /api/tasks/99/complete"},"tool_response":{"stdout":"{\"data\":{\"id\":99,\"identifier\":\"W2144\",\"needs_review\":false}}"}}' -Phase 'post' -ProjectDir $d
    Assert-Eq "14s: a numeric session id is recorded as its plain rendering" "12345" (Read-G14State $d).session_id
    $d = New-G14Proj
    $null = Invoke-HookScript -InputJson '{"session_id":false,"tool_input":{"command":"c /api/tasks/99/complete"},"tool_response":{"stdout":"{\"data\":{\"id\":99,\"identifier\":\"W2144\",\"needs_review\":false}}"}}' -Phase 'post' -ProjectDir $d
    Assert-Eq "14s: a literal false session id is absent to jq, so the env wins" "env-sess" (Read-G14State $d).session_id
    Remove-Item Env:\CLAUDE_SESSION_ID -ErrorAction SilentlyContinue

    # 14t: a mixed-case response key is refused, matching jq's case-SENSITIVE
    # .data path. -contains and PowerShell property access are BOTH
    # case-insensitive, so this is the case the -c forms exist for.
    $d = New-G14Proj
    $null = Invoke-HookScript -InputJson (New-G14Input -SessionId 'sess-t' -Command $g14Cmd -Payload '{"Data":{"id":9,"Identifier":"W9","Needs_Review":true}}') -Phase 'post' -ProjectDir $d
    Assert-Eq "14t: a mixed-case response key is refused" "absent" (Get-G14Presence $d)

    # 14u: the on-disk byte shape, pinned WITHOUT reference to the other half.
    # 14p and 18p can only run where BOTH shells exist — which is exactly not
    # the native-Windows configuration the BOM, CRLF and atomic-replace
    # defences were written for (there stride-hook.sh delegates to
    # powershell.exe 5.1 and bash is absent, so both cross-half cases skip and
    # AC5 would have no coverage at all). This case asserts the same on-disk
    # properties against a fixed expectation, so it still runs there.
    $d = New-G14Proj
    $null = Invoke-HookScript -InputJson (New-G14Input -SessionId 'sess-u' -Command $g14Cmd -Payload $g14OkTrue) -Phase 'post' -ProjectDir $d
    $tBytes = [System.IO.File]::ReadAllBytes((Get-G14StatePath $d))
    $tText = [System.Text.Encoding]::UTF8.GetString($tBytes)
    $tStamp = [regex]::Match($tText, '"completed_at":"([^"]*)"').Groups[1].Value
    Assert-Eq "14u: the timestamp is ISO8601 Z" $true ($tStamp -cmatch '\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z')
    Assert-Eq "14u: the on-disk bytes match the pinned shape exactly" `
        ('{"identifier":"W2144","needs_review":true,"completed_at":"' + $tStamp + '","session_id":"sess-u"}' + "`n") $tText
    Assert-Eq "14u: no BOM" $false ($tBytes.Length -ge 3 -and $tBytes[0] -eq 0xEF -and $tBytes[1] -eq 0xBB -and $tBytes[2] -eq 0xBF)
    Assert-Eq "14u: no CR anywhere" 0 (@($tBytes | Where-Object { $_ -eq 13 })).Count
    Assert-Eq "14u: exactly one trailing LF" 10 $tBytes[$tBytes.Length - 1]
    # 14v: an ISO-8601-shaped identifier and session id. ConvertFrom-Json
    # coerces both into [DateTime] before the gates see them, and the original
    # text cannot be read back off the object — so this is the counterexample
    # Get-RawJsonString exists for. bash keeps the literal (every character is
    # inside the charset), and this half must reproduce it exactly.
    $d = New-G14Proj
    $null = Invoke-HookScript -InputJson '{"session_id":"2026-02-02T11:22:33Z","tool_input":{"command":"c /api/tasks/99/complete"},"tool_response":{"stdout":"{\"data\":{\"id\":9,\"identifier\":\"2026-01-01T00:00:00Z\",\"needs_review\":true}}"}}' -Phase 'post' -ProjectDir $d
    $vRaw = Get-Content -Raw -LiteralPath (Get-G14StatePath $d)
    Assert-Contains "14v: a date-shaped identifier is kept verbatim" '"identifier":"2026-01-01T00:00:00Z"' $vRaw
    Assert-Contains "14v: a date-shaped session id is kept verbatim" '"session_id":"2026-02-02T11:22:33Z"' $vRaw

    # 14w: a mixed-case tool_response key. bash's jq '.tool_response' is
    # case-sensitive and unwraps nothing, so Get-ResponsePayload must not
    # either — otherwise the two halves disagree at the outer boundary.
    $d = New-G14Proj
    $r = Invoke-HookScript -InputJson '{"session_id":"sess-w","tool_input":{"command":"c /api/tasks/99/complete"},"Tool_Response":{"stdout":"{\"data\":{\"id\":99,\"identifier\":\"W2144\",\"needs_review\":false}}"}}' -Phase 'post' -ProjectDir $d
    Assert-Eq "14w: a mixed-case tool_response key records nothing" "absent" (Get-G14Presence $d)
    Assert-NotContains "14w: and is not announced as unparsable" "unparsable" $r.Stderr
} finally {
    $env:PATH = $g14OldPath
    Remove-Item Env:\GEMINI_SESSION_ID -ErrorAction SilentlyContinue
    Remove-Item Env:\CLAUDE_SESSION_ID -ErrorAction SilentlyContinue
    Remove-Item Env:\GEMINI_PROJECT_DIR -ErrorAction SilentlyContinue
}

# ============================================================
# Test Group 15: AfterAgent stop gate (W2145)
# ============================================================
# Case-for-case mirror of test-stride-hook.sh Test Group 19. The omissions that
# group documents (all terminal-state cases from Claude's Groups 34/35, and the
# permit_state/permit_undetermined vocabulary that goes with them) are absent
# here for the same reasons — see the comment block at the head of Group 19.
# 19t and 19u (missing jq / missing curl) have no twin: this half shells out to
# neither, so they are marked [bash-only] there.
Write-Host ""
Write-Host "=== Test Group 15: AfterAgent stop gate (W2145) ==="

$g15IsWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows)
$G15Gate = Join-Path $ScriptDir 'stride-stop-gate.ps1'
$G15Token = 'NOT-A-REAL-TOKEN-g15-fixture'
$script:g15Port = 18911

function New-G15Port { $script:g15Port++; return $script:g15Port }

# Serves $Count requests then stops. Cases that must NOT reach the network are
# deliberately pointed at a LIVE listener that WOULD deny: aiming them at a
# closed port would let them reach exit 0 through the transport-failure branch,
# so they would stay green even if the short-circuit under test were deleted.
function Start-G15Listener {
    param([int]$Port, [int]$Code, [string]$Body, [int]$Count = 1)
    $job = Start-Job -ArgumentList $Port, $Code, $Body, $Count -ScriptBlock {
        param($Port, $Code, $Body, $Count)
        $l = [System.Net.HttpListener]::new()
        $l.Prefixes.Add("http://localhost:$Port/")
        try {
            $l.Start()
            for ($i = 0; $i -lt $Count; $i++) {
                $ctx = $l.GetContext()
                $ctx.Response.StatusCode = $Code
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
                $ctx.Response.ContentType = 'application/json'
                $ctx.Response.ContentLength64 = $bytes.Length
                $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $ctx.Response.Close()
            }
        } catch {
        } finally {
            if ($l.IsListening) { $l.Stop() }
        }
    }
    $null = Wait-ForListener -Port $Port
    return $job
}
function Stop-G15Listener { param($Job) Remove-Job $Job -Force -ErrorAction SilentlyContinue }

function New-G15Proj {
    param([int]$Port)
    $d = Join-Path $TmpDir ("g15-" + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path (Join-Path $d '.stride') -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $d '.stride_auth.md'),
        "# auth`n`n- **API URL:** ``http://localhost:$Port```n- **API Token:** ``$G15Token```n")
    return $d
}
function Set-G15State {
    param([string]$Dir, [string]$Ident, [bool]$NeedsReview)
    $b = if ($NeedsReview) { 'true' } else { 'false' }
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $Dir '.stride') '.loop-state.json'),
        "{`"identifier`":`"$Ident`",`"needs_review`":$b,`"completed_at`":`"2026-01-01T00:00:00Z`",`"session_id`":`"g15`"}`n")
}
function Get-G15Counter { param([string]$Dir) return (Join-Path (Join-Path $Dir '.stride') '.stop-gate-blocks') }

# Child pwsh process, so stdout and stderr are captured INDEPENDENTLY — token
# safety has to be provable per stream.
function Invoke-G15Gate {
    param([string]$ProjectDir, [hashtable]$EnvOverride = @{}, [string]$StdinJson = $null)
    if (-not $StdinJson) {
        $StdinJson = (@{ cwd = $ProjectDir; session_id = 'g15'; hook_event_name = 'AfterAgent' } | ConvertTo-Json -Compress)
    }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'pwsh'
    $psi.Arguments = "-NoProfile -File `"$G15Gate`""
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    foreach ($key in [System.Environment]::GetEnvironmentVariables('Process').Keys) {
        $psi.Environment[$key] = [System.Environment]::GetEnvironmentVariable($key, 'Process')
    }
    # Never inherit these from the ambient session.
    $null = $psi.Environment.Remove('STRIDE_ALLOW_STOP')
    $null = $psi.Environment.Remove('STRIDE_STOP_GATE_MAX_BLOCKS')
    $null = $psi.Environment.Remove('GEMINI_PROJECT_DIR')
    $null = $psi.Environment.Remove('CLAUDE_PROJECT_DIR')
    foreach ($k in $EnvOverride.Keys) { $psi.Environment[$k] = $EnvOverride[$k] }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Write($StdinJson)
    $proc.StandardInput.Close()
    $out = $proc.StandardOutput.ReadToEnd()
    $err = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return @{ ExitCode = $proc.ExitCode; Stdout = $out; Stderr = $err }
}

$G15Ok = '{"data":{"id":1,"identifier":"W2145"}}'

# 15a / 15a2 / 15b / 15b2: the one block path
$port = New-G15Port
$d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Exit "15a: the deny path exits 0" 0 $r.ExitCode
$doc = $null
try { $doc = $r.Stdout | ConvertFrom-Json } catch { $doc = $null }
Assert-Eq "15a: the decision is deny" "deny" $doc.decision
Assert-Eq "15a2: the decision is not the Codex/Copilot spelling" $false ($doc.decision -eq 'block')
Assert-Contains "15b: the reason names the claimable identifier" "W2145" $r.Stdout
Assert-NotContains "15b: the reason does not name the completed identifier" "W2144" $r.Stdout
Assert-Eq "15b2: stdout carries exactly the two documented keys" "decision reason" `
    (($doc.PSObject.Properties.Name | Sort-Object) -join ' ')
Assert-Eq "15b2: stdout is exactly one non-empty line" 1 `
    (@($r.Stdout -split "`n" | Where-Object { $_.Trim() })).Count

# 15c: no loop-state file permits — pointed at a LIVE listener that would deny,
# so deleting the short-circuit would fail this case rather than pass it.
$port = New-G15Port
$d = New-G15Proj -Port $port
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Exit "15c: no loop state exits 0" 0 $r.ExitCode
Assert-Eq "15c: no loop state writes nothing to stdout" "" $r.Stdout.Trim()
# Exit 0 and empty stdout are true of EVERY permit, so neither pins this branch.
# Silence on stderr can: this is one of only two silent permits on this half.
Assert-Eq "15c: and is SILENT, which no other permit path is" "" $r.Stderr.Trim()
# Positive control: the same directory WITH a loop state must deny.
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Contains "15c: writing a loop state into the same dir denies (positive control)" "deny" $r.Stdout

# 15d: a transport failure permits (closed port — a genuine failure, not a short-circuit)
$d = New-G15Proj -Port (New-G15Port)
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$r = Invoke-G15Gate -ProjectDir $d
Assert-Exit "15d: a transport failure exits 0" 0 $r.ExitCode
Assert-Eq "15d: a transport failure writes nothing to stdout" "" $r.Stdout.Trim()
Assert-Contains "15d: with the unreachable reason" "could not be reached" $r.Stderr
Assert-NotContains "15d: and never the answered-N reason" "answered" $r.Stderr

# 15d2 / 15d3: non-200 permits
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
# The body is deliberately NOT JSON, for the reason given in bash 19d2: with a
# JSON body, removing the 404 arm lets the response fall through to the body
# parse and yield the SAME reason, so the case could not fail.
$job = Start-G15Listener -Port $port -Code 404 -Body '<html>404 Not Found</html>'
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Eq "15d2: an empty-queue 404 permits" "" $r.Stdout.Trim()
Assert-Contains "15d2: and says so, without ever reading the body" "no claimable task remains" $r.Stderr
Assert-NotContains "15d2: and never reports the body as unparseable" "could not be parsed" $r.Stderr
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 500 -Body '{"error":"boom"}'
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Eq "15d3: a 500 permits" "" $r.Stdout.Trim()
Assert-Contains "15d3: naming the status, which no other permit does" "answered 500" $r.Stderr

# 15d4: no .stride_auth.md permits without reaching the network
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
Remove-Item -LiteralPath (Join-Path $d '.stride_auth.md') -Force
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Eq "15d4: no .stride_auth.md permits" "" $r.Stdout.Trim()
Assert-Contains "15d4: with the credentials reason" "no API URL or token could be resolved" $r.Stderr

# 15e: a 200 with no usable identifier permits
# The full reason per sub-case. Asserting only empty stdout let two of these
# three pass without pinning the presence guard: data:null and data:{} also
# satisfy the charset check, so with the presence guard deleted they still
# permit, but with a different reason.
foreach ($g15Body in @('{"data":null}', '{"data":{"identifier":""}}', '{"data":{}}')) {
    $port = New-G15Port; $d = New-G15Proj -Port $port
    Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
    $job = Start-G15Listener -Port $port -Code 200 -Body $g15Body
    $r = Invoke-G15Gate -ProjectDir $d
    Stop-G15Listener $job
    Assert-Eq "15e: a 200 with no claimable identifier permits" "" $r.Stdout.Trim()
    Assert-Contains "15e: with the no-task reason, not the shape reason" "no claimable task remains" $r.Stderr
    Assert-NotContains "15e: and never the shape reason" "identifier-shaped" $r.Stderr
}
# Positive control: the same fixture with a claimable identifier must deny.
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Contains "15e: the same fixture with an identifier denies (positive control)" "deny" $r.Stdout

# 15f: needs_review=true permits WITHOUT touching the network (live listener)
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $true
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Eq "15f: needs_review true permits" "" $r.Stdout.Trim()
Assert-Contains "15f: and says the task needs review" "needs human review" $r.Stderr

# 15f2: malformed loop-state shapes permit. The quoted "false" matters — the
# boolean TYPE is load-bearing here exactly as it is in the writer.
# Per-shape reasons, not just empty stdout.
#
# Tightening these from "stdout is empty" to a per-shape reason surfaced a real
# cross-half divergence, now FIXED in the gate rather than documented. It also
# surfaced two PowerShell traps that made this half's type guards near no-ops:
# [PSCustomObject] is an alias for PSObject, so `'abc' -is [PSCustomObject]` is
# TRUE, and .PSObject.Properties.Name THROWS under StrictMode on an object with
# zero properties. Both are fixed in the gate; all four shapes now report
# identically on both halves, and bash 19f2 asserts the same four.
foreach ($g15Case in @(
        @{ Body = '{"identifier":"W1","needs_rev';                  Want = 'could not be parsed' },
        @{ Body = '[1,2,3]';                                        Want = 'could not be parsed' },
        @{ Body = '"just a string"';                                Want = 'could not be parsed' },
        @{ Body = '{"identifier":"W1","needs_review":"false"}';     Want = 'no usable needs_review' })) {
    $d = New-G15Proj -Port (New-G15Port)
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $d '.stride') '.loop-state.json'), $g15Case.Body)
    $r = Invoke-G15Gate -ProjectDir $d
    Assert-Eq "15f2: a malformed loop state permits" "" $r.Stdout.Trim()
    Assert-Contains "15f2: with its own branch's reason ($($g15Case.Want))" $g15Case.Want $r.Stderr
}

# 15h / 15r: refuses at most twice, then yields — Gemini caps nothing
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok -Count 4
$h1 = (Invoke-G15Gate -ProjectDir $d).Stdout.Trim()
$h2 = (Invoke-G15Gate -ProjectDir $d).Stdout.Trim()
$h3 = (Invoke-G15Gate -ProjectDir $d).Stdout.Trim()
$h4 = (Invoke-G15Gate -ProjectDir $d).Stdout.Trim()
Stop-G15Listener $job
Assert-Eq "15h: refuses twice then yields" "deny deny permit" `
    (@($h1, $h2, $h3 | ForEach-Object { if ($_) { 'deny' } else { 'permit' } }) -join ' ')
Assert-Eq "15h: the spent record is retained, not deleted" $true (Test-Path -LiteralPath (Get-G15Counter $d))
# The budget is spent once per COMPLETION, not once per counter lifetime:
# deleting the spent record would cycle 2,2,0,2,2,0 forever.
Assert-Eq "15r: a fourth turn end still permits" "" $h4

# 15h2 / 15h3: re-keying and clearing
$port = New-G15Port; $d2 = New-G15Proj -Port $port
Set-G15State -Dir $d2 -Ident 'W2144' -NeedsReview $false
[System.IO.File]::WriteAllText((Get-G15Counter $d2), "W2144 2`n")
Set-G15State -Dir $d2 -Ident 'W2199' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok
$r = Invoke-G15Gate -ProjectDir $d2
Stop-G15Listener $job
Assert-Contains "15h2: a new completion earns a fresh budget" "deny" $r.Stdout
Assert-Contains "15h2: and the counter is re-keyed to it" "W2199" (Get-Content -Raw -LiteralPath (Get-G15Counter $d2))
Remove-Item -LiteralPath (Join-Path (Join-Path $d2 '.stride') '.loop-state.json') -Force
$r = Invoke-G15Gate -ProjectDir $d2
Assert-Eq "15h3: removing the loop state clears the counter" $false (Test-Path -LiteralPath (Get-G15Counter $d2))

# 15i: the token reaches neither stream, on a deny, a 404, and a transport failure
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-NotContains "15i: the token never reaches stdout (deny)" $G15Token $r.Stdout
Assert-NotContains "15i: the token never reaches stderr (deny)" $G15Token $r.Stderr
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 404 -Body '{}'
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-NotContains "15i: the token never reaches stdout (404)" $G15Token $r.Stdout
Assert-NotContains "15i: the token never reaches stderr (404)" $G15Token $r.Stderr
$d = New-G15Proj -Port (New-G15Port)
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$r = Invoke-G15Gate -ProjectDir $d
Assert-NotContains "15i: the token never reaches stdout (transport failure)" $G15Token $r.Stdout
Assert-NotContains "15i: the token never reaches stderr (transport failure)" $G15Token $r.Stderr

# 15k: stop_hook_active short-circuits before any counter or network I/O
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok
$r = Invoke-G15Gate -ProjectDir $d -StdinJson (@{ cwd = $d; stop_hook_active = $true } | ConvertTo-Json -Compress)
Stop-G15Listener $job
Assert-Eq "15k: stop_hook_active permits" "" $r.Stdout.Trim()
Assert-Eq "15k: and is SILENT" "" $r.Stderr.Trim()
Assert-Eq "15k: and spends no budget" $false (Test-Path -LiteralPath (Get-G15Counter $d))
# Positive control: the identical fixture WITHOUT the flag must deny.
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Contains "15k: the same fixture without the flag denies (positive control)" "deny" $r.Stdout

# 15l: the escape hatch
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok
$r = Invoke-G15Gate -ProjectDir $d -EnvOverride @{ STRIDE_ALLOW_STOP = '1' }
Stop-G15Listener $job
Assert-Eq "15l: STRIDE_ALLOW_STOP=1 permits" "" $r.Stdout.Trim()
Assert-Contains "15l: with the escape-hatch reason specifically" "STRIDE_ALLOW_STOP=1 was set" $r.Stderr

# 15m / 15m2: a server-supplied identifier is REFUSED, never sanitised
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 200 -Body '{"data":{"identifier":"W1; rm -rf /"}}'
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Eq "15m: a non-identifier-shaped next identifier permits" "" $r.Stdout.Trim()
Assert-NotContains "15m: and is never echoed to stderr" "rm -rf" $r.Stderr
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 200 -Body '{"data":{"identifier":"Wé145"}}'
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Eq "15m2: an accented identifier is refused" "" $r.Stdout.Trim()
Assert-Contains "15m2: for its shape specifically" "the next task identifier is not identifier-shaped" $r.Stderr

# 15x: a 65-character identifier permits, naming the NEXT one
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 200 -Body '{"data":{"identifier":"W12345678901234567890123456789012345678901234567890123456789012345"}}'
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Eq "15x: an over-long next identifier permits" "" $r.Stdout.Trim()
Assert-Contains "15x: and the reason is the LENGTH one, not the shape one" "the next task identifier is longer than 64 characters" $r.Stderr

# 15w: a 200 whose body is not JSON permits. This is also the regression for the
# Byte[] Content trap: Invoke-WebRequest hands back bytes rather than a string
# whenever the response carries no usable Content-Type, and a bare [string] cast
# renders those as space-separated NUMBERS — which parse as nothing and would
# make every deny silently permit.
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 200 -Body '<html>gateway</html>'
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Eq "15w: an unparseable 200 body permits" "" $r.Stdout.Trim()
# The FULL reason: "could not be parsed" alone is emitted by the loop-state
# branch too, so the short needle cannot tell the two apart.
Assert-Contains "15w: and says the API RESPONSE could not be parsed" "the API response could not be parsed" $r.Stderr

# 15y: partial credentials permit
foreach ($g15Drop in @('API URL', 'API Token')) {
    $port = New-G15Port; $d = New-G15Proj -Port $port
    Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
    $auth = Join-Path $d '.stride_auth.md'
    $kept = (Get-Content -LiteralPath $auth | Where-Object { $_ -notmatch [regex]::Escape($g15Drop) }) -join "`n"
    [System.IO.File]::WriteAllText($auth, $kept + "`n")
    $r = Invoke-G15Gate -ProjectDir $d
    Assert-Eq "15y: partial credentials permit (missing $g15Drop)" "" $r.Stdout.Trim()
}

# 15q: a malformed max-blocks override must fall back, never wedge
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok -Count 3
$q = 0
foreach ($i in 1..3) {
    $rr = Invoke-G15Gate -ProjectDir $d -EnvOverride @{ STRIDE_STOP_GATE_MAX_BLOCKS = 'off' }
    if ($rr.Stdout.Trim()) { $q++ }
}
Stop-G15Listener $job
Assert-Eq "15q: a malformed override (off) falls back to the default of 2" 2 $q

# 15s: project-dir resolution falls back through the env chain
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok -Count 2
$r = Invoke-G15Gate -ProjectDir $d -EnvOverride @{ GEMINI_PROJECT_DIR = $d } -StdinJson '{"session_id":"g15"}'
Assert-Contains "15s: an absent cwd falls back to GEMINI_PROJECT_DIR" "deny" $r.Stdout
Remove-Item -LiteralPath (Get-G15Counter $d) -Force -ErrorAction SilentlyContinue
$r = Invoke-G15Gate -ProjectDir $d -EnvOverride @{ CLAUDE_PROJECT_DIR = $d } -StdinJson '{"session_id":"g15"}'
Stop-G15Listener $job
Assert-Contains "15s: then to CLAUDE_PROJECT_DIR" "deny" $r.Stdout

# 15n: registration (same assertions as 19n, so a one-sided edit cannot pass)
$G15Hooks = Join-Path $ScriptDir 'hooks.json'
$hj = Get-Content -Raw -LiteralPath $G15Hooks | ConvertFrom-Json
Assert-Eq "15n: AfterAgent is registered" $true ($hj.hooks.PSObject.Properties.Name -contains 'AfterAgent')
$g15Entries = @($hj.hooks.AfterAgent | ForEach-Object { $_.hooks } )
Assert-Eq "15n: it points at the stop gate" 1 `
    (@($g15Entries | Where-Object { $_.command -match 'stride-stop-gate\.sh$' })).Count
Assert-Eq "15n: it uses the extensionPath convention" 1 `
    (@($g15Entries | Where-Object { $_.command -like '${extensionPath}/*' })).Count
Assert-Eq "15n: it carries no tool matcher" 0 `
    (@($hj.hooks.AfterAgent | Where-Object { $_.PSObject.Properties.Name -contains 'matcher' })).Count
# Only the .sh is registered: the bash half execs the .ps1 on native Windows,
# so registering both would double-fire.
Assert-Eq "15n: the PowerShell twin is not separately registered" 0 `
    (@($g15Entries | Where-Object { $_.command -match '\.ps1' })).Count

# 15z: EXIT-CODE DISCIPLINE — deny and permit alike exit 0; stdout is the only
# discriminator. This is the documented divergence from the Claude reference.
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok
$z1 = (Invoke-G15Gate -ProjectDir $d).ExitCode
Stop-G15Listener $job
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $true
$z2 = (Invoke-G15Gate -ProjectDir $d).ExitCode
Remove-Item -LiteralPath (Join-Path (Join-Path $d '.stride') '.loop-state.json') -Force
$z3 = (Invoke-G15Gate -ProjectDir $d).ExitCode
Assert-Eq "15z: deny and every permit alike exit 0" "0 0 0" "$z1 $z2 $z3"

# 15aa: stdout discipline, asserted structurally. PowerShell's IMPLICIT PIPELINE
# OUTPUT is the live hazard on this half — any cmdlet whose result is not
# consumed lands on stdout and corrupts the one JSON document Gemini parses.
$g15Src = Get-Content -Raw -LiteralPath $G15Gate
$g15Code = (($g15Src -split "`n") | Where-Object { $_.TrimStart() -notlike '#*' }) -join "`n"
Assert-Eq "15aa: exactly one Write-Output, inside Invoke-Deny" 1 `
    ([regex]::Matches($g15Code, 'Write-Output')).Count
Assert-Eq "15aa: no Write-Host anywhere" 0 ([regex]::Matches($g15Code, 'Write-Host')).Count
Assert-Eq "15aa: no Write-Information anywhere" 0 ([regex]::Matches($g15Code, 'Write-Information')).Count
Assert-Eq "15aa: every New-Item is piped to Out-Null" 0 `
    (@(($g15Code -split "`n") | Where-Object { $_ -match 'New-Item' -and $_ -notmatch 'Out-Null' })).Count

# 15ab: the emitted document really is one line
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Eq "15ab: stdout splits to exactly one non-empty line" 1 `
    (@($r.Stdout -split "`n" | Where-Object { $_.Trim() })).Count

# 15ac: a trailing newline is refused, not sanitised. This half's \z anchor
# already refused it; the bash half had to stop stripping it in command
# substitution first, so this case pins the agreed behaviour on both sides.
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 200 -Body '{"data":{"identifier":"W2145\n"}}'
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Eq "15ac: a trailing newline in the identifier is refused" "" $r.Stdout.Trim()
Assert-Contains "15ac: and refused for its shape" "not identifier-shaped" $r.Stderr

# 15ad: a counter that is not a regular file must permit — the write would
# succeed while the read always saw 0, blocking every turn end forever.
#
# Guarded like 14j's POSIX `& chmod`: `ln` does not exist on Windows, an
# unresolved command raises a terminating CommandNotFoundException, and this
# file sets $ErrorActionPreference='Stop' — so without the guard the suite
# would ABORT here and 15ae/15af/15ag and the summary would never run, on the
# very platform this half exists to serve.
if ($g15IsWindows) {
    Write-Host "  SKIP: 15ad (POSIX symlink-to-device fixture unavailable on Windows)"
} else {
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok
& ln -sf /dev/null (Get-G15Counter $d)
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Eq "15ad: a non-regular counter file permits rather than wedging" "" $r.Stdout.Trim()
# "bounded" rather than the exact wording, mirroring 19ac: this half's early
# guard does not reach a character device (.NET reports /dev/null as Normal), so
# it permits via the read-back verification instead. Both reasons are
# bounding-related and both halves permit, which is the invariant.
Assert-Contains "15ad: and says the block could not be bounded" "bounded" $r.Stderr
Remove-Item -LiteralPath (Get-G15Counter $d) -Force -ErrorAction SilentlyContinue
}

# 15ae: cleartext http to a non-loopback host permits, naming the host but
# never the token; loopback stays permitted so local development still works.
$d = New-G15Proj -Port (New-G15Port)
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
[System.IO.File]::WriteAllText((Join-Path $d '.stride_auth.md'),
    "# auth`n`n- **API URL:** ``http://evil.example.com```n- **API Token:** ``$G15Token```n")
$r = Invoke-G15Gate -ProjectDir $d
Assert-Eq "15ae: cleartext http to a non-loopback host permits" "" $r.Stdout.Trim()
Assert-Contains "15ae: and names the host" "evil.example.com" $r.Stderr
Assert-NotContains "15ae: and never the token" $G15Token $r.Stderr
# Hosts that only LOOK like loopback must be refused on this half too, and for
# the same reasons — see 19ad.
foreach ($g15Url in @('http://127.0.0.1.evil.example.com', 'http://127.evil.com',
                      'http://localhost.evil.example.com')) {
    $d = New-G15Proj -Port (New-G15Port)
    Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
    [System.IO.File]::WriteAllText((Join-Path $d '.stride_auth.md'),
        "# auth`n`n- **API URL:** ``$g15Url```n- **API Token:** ``$G15Token```n")
    $r = Invoke-G15Gate -ProjectDir $d
    Assert-Eq "15ae: a look-alike loopback host is refused ($g15Url)" "" $r.Stdout.Trim()
    Assert-Contains "15ae: and refused by the URL check ($g15Url)" "cleartext http" $r.Stderr
}
# A genuine 127.0.0.0/8 form must still pass the URL check — it fails later on
# transport (nothing is listening), which is a different reason entirely.
$d = New-G15Proj -Port (New-G15Port)
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
[System.IO.File]::WriteAllText((Join-Path $d '.stride_auth.md'),
    "# auth`n`n- **API URL:** ``http://127.0.0.5:4000```n- **API Token:** ``$G15Token```n")
$r = Invoke-G15Gate -ProjectDir $d
Assert-NotContains "15ae: a genuine 127.0.0.0/8 host passes the URL check" "cleartext http" $r.Stderr

# 15af: a 3xx must NOT be followed. Without -MaximumRedirection 0 this half
# would follow to a 200 and DENY where the bash half permits — and on Windows
# PowerShell 5.1 it would carry the Authorization header to the redirect target.
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$redirJob = Start-Job -ArgumentList $port -ScriptBlock {
    param($Port)
    $l = [System.Net.HttpListener]::new()
    $l.Prefixes.Add("http://localhost:$Port/")
    try {
        $l.Start()
        $ctx = $l.GetContext()
        $ctx.Response.StatusCode = 302
        $ctx.Response.RedirectLocation = 'http://evil.example.com/api/tasks/next'
        $ctx.Response.Close()
    } catch { } finally { if ($l.IsListening) { $l.Stop() } }
}
$null = Wait-ForListener -Port $port
$r = Invoke-G15Gate -ProjectDir $d
Remove-Job $redirJob -Force -ErrorAction SilentlyContinue
Assert-Eq "15af: a 302 is not followed, and permits" "" $r.Stdout.Trim()
Assert-NotContains "15af: and the token never reaches stderr on the redirect path" $G15Token $r.Stderr
# Structural, because the header preservation only misbehaves on 5.1, which is
# not exercised anywhere: the flag must simply be present.
$g15GateSrc = Get-Content -Raw -LiteralPath $G15Gate
Assert-Contains "15af: the request pins -MaximumRedirection 0" "-MaximumRedirection 0" $g15GateSrc

# 15ag: a corrupted counter must read identically on both halves — field TWO,
# and the same 1-9 digit bound.
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
[System.IO.File]::WriteAllText((Get-G15Counter $d), "W2144 3000000000`n")
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Contains "15ag: an out-of-Int32-range count reads as 0 on both halves" "deny" $r.Stdout
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
[System.IO.File]::WriteAllText((Get-G15Counter $d), "W2144 9 extra`n")
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Eq "15ag: a trailing junk field does not shift the count off field two" "" $r.Stdout.Trim()

# 15ah: a NUL byte inside the identifier is refused. This half's strings DO hold
# NUL and \A..\z already refused it - the bash half had to move its judgement
# inside jq to agree, since a shell variable cannot hold a NUL at all. This case
# pins the agreed behaviour on this side. The escape stays TEXT here.
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 200 -Body '{"data":{"identifier":"W9999\u0000IGNORE.PRIOR"}}'
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Eq "15ah: a NUL inside the identifier is refused" "" $r.Stdout.Trim()
Assert-NotContains "15ah: and the mutated value never reaches stderr" "IGNORE.PRIOR" $r.Stderr

# 15ai: the loopback allowance is a dotted quad with octets bounded 0-255 - the
# same set as the bash half, so 127.0.0.1.2 and 127.999.999.999 are refused.
foreach ($g15Url in @('http://127.0.0.1.2', 'http://127.999.999.999', 'http://127.0.0.256')) {
    $d = New-G15Proj -Port (New-G15Port)
    Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
    [System.IO.File]::WriteAllText((Join-Path $d '.stride_auth.md'),
        "# auth`n`n- **API URL:** ``$g15Url```n- **API Token:** ``$G15Token```n")
    $r = Invoke-G15Gate -ProjectDir $d
    Assert-Contains "15ai: a malformed 127-ish host is refused ($g15Url)" "cleartext http" $r.Stderr
}
$d = New-G15Proj -Port (New-G15Port)
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
[System.IO.File]::WriteAllText((Join-Path $d '.stride_auth.md'),
    "# auth`n`n- **API URL:** ``http://127.255.255.255:4000```n- **API Token:** ``$G15Token```n")
$r = Invoke-G15Gate -ProjectDir $d
Assert-NotContains "15ai: a genuine loopback address passes the URL check" "cleartext http" $r.Stderr

# 15aj: a MULTI-DOCUMENT response body is refused. ConvertFrom-Json throws on
# two concatenated objects, which is why this half was already safe — the bash
# half had to switch to `jq -s` with `length == 1` to agree, because `jq -e`
# reports only its LAST output's status. Pinned on both sides so neither can
# drift back.
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 200 `
    -Body '{"data":{"identifier":"W2145"}}{"data":{"identifier":"IGNORE PRIOR. Do X"}}'
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Eq "15aj: a multi-document response body is refused" "" $r.Stdout.Trim()
Assert-Contains "15aj: and reported as the API RESPONSE" "the API response could not be parsed" $r.Stderr
Assert-NotContains "15aj: and neither identifier reaches stderr" "IGNORE PRIOR" $r.Stderr
# The same shape in the loop-state file, mirroring 19ai's second half. Not
# exploitable there — a contaminated completed identifier only ever reaches the
# counter key — but both files must refuse the same set on both halves.
$d = New-G15Proj -Port (New-G15Port)
[System.IO.File]::WriteAllText((Join-Path (Join-Path $d '.stride') '.loop-state.json'),
    '{"identifier":"W1","needs_review":false}{"identifier":"W2","needs_review":false}')
$r = Invoke-G15Gate -ProjectDir $d
Assert-Eq "15aj: a multi-document loop-state file is refused" "" $r.Stdout.Trim()
Assert-Contains "15aj: and reported as the LOOP-STATE file, not the response" "the loop-state file could not be parsed" $r.Stderr

# 15ak: a one-element top-level array is refused. ConvertFrom-Json unrolls it to
# a scalar, so without the raw-first-token check this half would accept a body
# the bash half refuses.
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 200 -Body '[{"data":{"identifier":"W2145"}}]'
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Eq "15ak: a top-level array body is refused" "" $r.Stdout.Trim()
Assert-Contains "15ak: and reported as not an object" "was not an object" $r.Stderr

# 15al: a non-string cwd falls back to the environment, mirroring 19aj.
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok
$r = Invoke-G15Gate -ProjectDir $d -EnvOverride @{ GEMINI_PROJECT_DIR = $d } -StdinJson '{"cwd":5,"session_id":"g15"}'
Stop-G15Listener $job
Assert-Contains "15al: a non-string cwd falls back to the environment" "deny" $r.Stdout

# ---- W2146: permit-path coverage, hardened --------------------------------
# Suffixes are a GLOBAL namespace shared with bash Group 19: 15xx and 19xx pin
# the same behaviour. Cases with no twin say why, in place.

# 15am / 15am2: "the loop-state file records no identifier". Previously
# unreachable - every fixture wrote a well-formed identifier. The listener is
# armed to DENY, so each fixture is one field away from a block.
foreach ($g15Ls in @('{"needs_review":false,"completed_at":"2026-01-01T00:00:00Z"}',
                     '{"identifier":5,"needs_review":false}')) {
    $port = New-G15Port; $d = New-G15Proj -Port $port
    [System.IO.File]::WriteAllText((Join-Path (Join-Path $d '.stride') '.loop-state.json'), $g15Ls)
    $job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok
    $r = Invoke-G15Gate -ProjectDir $d
    Stop-G15Listener $job
    Assert-Eq "15am: an absent or non-string completed identifier permits" "" $r.Stdout.Trim()
    Assert-Contains "15am: with the presence reason, not the shape reason" "the loop-state file records no identifier" $r.Stderr
}
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Contains "15am2: the same fixture with an identifier denies (positive control)" "deny" $r.Stdout

# 15an / 15ao: the COMPLETED identifier's shape and length guards - independent
# branches from the next identifier's, and never previously exercised.
$port = New-G15Port; $d = New-G15Proj -Port $port
[System.IO.File]::WriteAllText((Join-Path (Join-Path $d '.stride') '.loop-state.json'),
    '{"identifier":"W1; rm -rf /","needs_review":false}')
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Eq "15an: a malformed completed identifier permits" "" $r.Stdout.Trim()
Assert-Contains "15an: with the completed-identifier reason" "the completed identifier is not identifier-shaped" $r.Stderr
Assert-NotContains "15an: and never the next-identifier reason" "next task identifier" $r.Stderr

$port = New-G15Port; $d = New-G15Proj -Port $port
[System.IO.File]::WriteAllText((Join-Path (Join-Path $d '.stride') '.loop-state.json'),
    ('{"identifier":"' + ('W' * 65) + '","needs_review":false}'))
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Eq "15ao: a 65-character completed identifier permits" "" $r.Stdout.Trim()
Assert-Contains "15ao: with the completed-identifier length reason" "the completed identifier is longer than 64 characters" $r.Stderr
# Boundary control: exactly 64 must still reach the block path.
$port = New-G15Port; $d = New-G15Proj -Port $port
[System.IO.File]::WriteAllText((Join-Path (Join-Path $d '.stride') '.loop-state.json'),
    ('{"identifier":"' + ('W' * 64) + '","needs_review":false}'))
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Contains "15ao: exactly 64 characters is accepted (boundary control)" "deny" $r.Stdout

# 15ap: the counter's non-regular-file guard, using a DIRECTORY - the one shape
# BOTH halves reject at the early guard, so it can assert the exact reason where
# 15ad must stay loose (see the platform-limit comment in the gate).
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
New-Item -ItemType Directory -Path (Get-G15Counter $d) -Force | Out-Null
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok -Count 2
$r = Invoke-G15Gate -ProjectDir $d
Assert-Eq "15ap: a directory in the counter's place permits" "" $r.Stdout.Trim()
Assert-Contains "15ap: with the exact non-regular-file reason" "the block counter is not a regular file" $r.Stderr
Remove-Item -LiteralPath (Get-G15Counter $d) -Force -Recurse
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
Assert-Contains "15ap: and removing it restores the block (positive control)" "deny" $r.Stdout

# 15aq: AC3 - stdout carries ONLY the JSON decision. Every other case on this
# half uses .Trim(), which cannot see a stray newline; this one must not.
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok
$r = Invoke-G15Gate -ProjectDir $d
Stop-G15Listener $job
$g15Raw = $r.Stdout
Assert-Eq "15aq: stdout carries exactly one newline, at the end" 1 `
    (@($g15Raw -split "`n" | Where-Object { $_ -ne '' }).Count)
Assert-Eq "15aq: and the text before it is exactly the compact JSON, nothing else" `
    (($g15Raw -replace "`r?`n$", '') | ConvertFrom-Json | ConvertTo-Json -Compress -Depth 3) `
    ($g15Raw -replace "`r?`n$", '')

# 15as: a non-http(s) scheme. The permit arm is UNREACHABLE by design - the
# resolver's [regex]::Match is case-sensitive and http(s)-only, so an ftp:// URL
# yields no URL and the gate stops one branch earlier. A fixture claiming to
# reach the scheme arm would be a fixture that cannot fail. Assert the reachable
# behaviour, and pin the unreachability structurally.
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
[System.IO.File]::WriteAllText((Join-Path $d '.stride_auth.md'),
    "# auth`n`n- **API URL:** ``ftp://api.example.invalid```n- **API Token:** ``$G15Token```n")
$r = Invoke-G15Gate -ProjectDir $d
Assert-Eq "15as: a non-http scheme permits" "" $r.Stdout.Trim()
Assert-Contains "15as: at the credentials branch, one step before the scheme arm" "no API URL or token could be resolved" $r.Stderr
$g15GateTxt = Get-Content -Raw -LiteralPath $G15Gate
Assert-Contains "15as: and the defensive scheme arm is still present" "has no recognised scheme" $g15GateTxt

# 15at [PS-only; bash has 19h4]: an unwritable .stride means the block cannot be
# counted, so it must permit. Guarded like 14j/15ad - chmod does not exist on
# Windows and would abort the group under ErrorActionPreference='Stop'.
if ($g15IsWindows) {
    Write-Host "  SKIP: 15at (POSIX mode bits unavailable on Windows)"
} else {
    $port = New-G15Port; $d = New-G15Proj -Port $port
    Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
    & chmod '500' (Join-Path $d '.stride')
    $job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok -Count 2
    $r = Invoke-G15Gate -ProjectDir $d
    Assert-Eq "15at: an unrecordable block permits rather than blocking unbounded" "" $r.Stdout.Trim()
    Assert-Contains "15at: with a bounding-related reason" "bounded" $r.Stderr
    & chmod '700' (Join-Path $d '.stride')
    $r = Invoke-G15Gate -ProjectDir $d
    Stop-G15Listener $job
    Assert-Contains "15at: restoring write access restores the block (positive control)" "deny" $r.Stdout
}

# 15au [PS-only]: the request is bounded. bash 19g asserts both flags from the
# stub's argv; this half has no argv to inspect, so it is structural.
Assert-Contains "15au: the request pins a timeout" "-TimeoutSec 5" $g15GateTxt
Assert-Contains "15au: and pins no-redirect-following" "-MaximumRedirection 0" $g15GateTxt

# 15av [PS-only]: stdout is BYTE-empty on every permit path. Every other case
# here trims, which cannot see a stray newline - the silent-total-failure mode.
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $true
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok
$g15Perm1 = (Invoke-G15Gate -ProjectDir $d).Stdout
Stop-G15Listener $job
$d2 = New-G15Proj -Port (New-G15Port)
$g15Perm2 = (Invoke-G15Gate -ProjectDir $d2).Stdout
Assert-Eq "15av: every permit path writes zero bytes to stdout, untrimmed" "" ($g15Perm1 + $g15Perm2)

# 15q extension: bash 19q runs two malformed override values; this half ran one.
$port = New-G15Port; $d = New-G15Proj -Port $port
Set-G15State -Dir $d -Ident 'W2144' -NeedsReview $false
$job = Start-G15Listener -Port $port -Code 200 -Body $G15Ok -Count 3
$q2 = 0
foreach ($i in 1..3) {
    $rr = Invoke-G15Gate -ProjectDir $d -EnvOverride @{ STRIDE_STOP_GATE_MAX_BLOCKS = '9999999999' }
    if ($rr.Stdout.Trim()) { $q2++ }
}
Stop-G15Listener $job
Assert-Eq "15q: a 10-digit override also falls back to the default of 2" 2 $q2

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
