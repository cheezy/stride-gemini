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
Assert-Contains "claim runs before_doing" "pulling latest" $r.Stderr

# 1b: Complete command extracts correctly
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/123/complete"}}' -Phase 'pre' -ProjectDir $proj
Assert-Exit "complete URL exits 0" 0 $r.ExitCode
Assert-Contains "pre-complete runs after_doing" "running tests" $r.Stderr

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
Assert-Contains "basic: before_doing line 1" 'pulling latest' $r.Stderr
Assert-Contains "basic: before_doing line 2" 'getting deps' $r.Stderr

$r = Invoke-HookScript -InputJson $CompleteJson -Phase 'pre' -ProjectDir $proj2
Assert-Contains "basic: after_doing line 1" 'running tests' $r.Stderr
Assert-Contains "basic: after_doing line 2" 'running credo' $r.Stderr

$r = Invoke-HookScript -InputJson $CompleteJson -Phase 'post' -ProjectDir $proj2
Assert-Contains "basic: before_review" 'creating pr' $r.Stderr

$r = Invoke-HookScript -InputJson $ReviewJson -Phase 'post' -ProjectDir $proj2
Assert-Contains "basic: after_review" 'deploying' $r.Stderr

# 2e: Sections don't bleed
$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $proj2
Assert-NotContains "sections do not bleed" 'running tests' $r.Stderr

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
Assert-Contains "first block captured" 'first command' $r.Stderr
Assert-NotContains "second block ignored" 'should not appear' $r.Stderr

# 2i: Section with no bash block
Copy-Item (Join-Path $TmpDir 'no-bash-block.stride.md') (Join-Path $proj2 '.stride.md') -Force
$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $proj2
Assert-Exit "no bash block exits 0" 0 $r.ExitCode

# 2j: Adjacent sections
Copy-Item (Join-Path $TmpDir 'adjacent-sections.stride.md') (Join-Path $proj2 '.stride.md') -Force
$r = Invoke-HookScript -InputJson $ClaimJson -Phase 'post' -ProjectDir $proj2
Assert-Contains "adjacent: before_doing correct" 'echo "before"' ($r.Stderr + $r.Stdout)
Assert-NotContains "adjacent sections do not bleed" 'echo "after"' $r.Stderr

$r = Invoke-HookScript -InputJson $CompleteJson -Phase 'pre' -ProjectDir $proj2
Assert-Contains "adjacent: after_doing correct" 'echo "after"' ($r.Stderr + $r.Stdout)

# ============================================================
# Test Group 3: Whitespace trimming
# ============================================================
Write-Host ""
Write-Host "=== Test Group 3: Whitespace trimming ==="

# Test the TrimStart behavior used in command list building
function Test-TrimStart {
    param([string]$Input)
    return $Input.TrimStart()
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
$result = Build-CmdList $commands
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
Assert-Contains "claim runs before_doing" "before_doing_executed" $r.Stderr

# 5b: Pre-complete triggers after_doing
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}}' -Phase 'pre' -ProjectDir $proj5
Assert-Exit "pre-complete exits 0" 0 $r.ExitCode
Assert-Contains "pre-complete runs after_doing" "after_doing_executed" $r.Stderr

# 5c: Post-complete triggers before_review
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/complete"}}' -Phase 'post' -ProjectDir $proj5
Assert-Exit "post-complete exits 0" 0 $r.ExitCode
Assert-Contains "post-complete runs before_review" "before_review_executed" $r.Stderr

# 5d: Mark-reviewed triggers after_review
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X PATCH https://stridelikeaboss.com/api/tasks/99/mark_reviewed"}}' -Phase 'post' -ProjectDir $proj5
Assert-Exit "mark-reviewed exits 0" 0 $r.ExitCode
Assert-Contains "mark-reviewed runs after_review" "after_review_executed" $r.Stderr

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
Assert-Contains "failing hook ran step one" "step one passes" $r.Stderr
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
Assert-Contains "multi-command: step 1" "test_one" $r.Stderr
Assert-Contains "multi-command: step 2" "test_two" $r.Stderr
Assert-Contains "multi-command: step 3" "test_three" $r.Stderr

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
Assert-Contains "no trailing newline runs command" "no trailing newline" $r.Stderr

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
Assert-Contains "env var expanded" "home=" $r.Stderr

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
Assert-Contains "CRLF runs command" "crlf test" $r.Stderr

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
Assert-Contains "env cache: identifier" "id=W99" $r.Stderr
Assert-Contains "env cache: title" "title=Test Task" $r.Stderr
# Clean up cache
$cacheFile = Join-Path $cacheProj '.stride-env-cache'
if (Test-Path $cacheFile) { Remove-Item -Force $cacheFile }

# 6e: Structured JSON output on success
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}' -Phase 'post' -ProjectDir $proj5
Assert-Contains "success JSON has hook field" '"hook"' $r.Stdout
Assert-Contains "success JSON has status" '"success"' $r.Stdout

# 6f: Structured JSON output on failure
$r = Invoke-HookScript -InputJson '{"tool_input":{"command":"curl -X POST https://stridelikeaboss.com/api/tasks/claim"}}' -Phase 'post' -ProjectDir $failProj
Assert-Contains "failure JSON has hook field" '"hook"' $r.Stdout
Assert-Contains "failure JSON has failed status" '"failed"' $r.Stdout

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
