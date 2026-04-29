# test-stride-skill-gate.ps1 — tests for stride-skill-gate.ps1 (Gemini variant)
#
# Mirrors test-stride-skill-gate.sh on PowerShell. Each test creates an
# isolated temp project dir, optionally writes a marker, pipes a Gemini
# BeforeTool(activate_skill) fixture into the gate, and asserts on exit code
# and stdout.
#
# Run: pwsh test-stride-skill-gate.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Gate = Join-Path $ScriptDir 'stride-skill-gate.ps1'

if (-not (Test-Path $Gate)) {
    Write-Error "FATAL: $Gate not found"
    exit 1
}

$script:Pass = 0
$script:Fail = 0

function Assert-Eq {
    param([string]$Label, $Expected, $Actual)
    if ($Expected -eq $Actual) {
        Write-Host "PASS $Label (=$Actual)" -ForegroundColor Green
        $script:Pass++
    } else {
        Write-Host "FAIL $Label (expected=$Expected got=$Actual)" -ForegroundColor Red
        $script:Fail++
    }
}

function Assert-Contains {
    param([string]$Label, [string]$Needle, [string]$Haystack)
    if ($Haystack -like "*$Needle*") {
        Write-Host "PASS $Label (stdout contains '$Needle')" -ForegroundColor Green
        $script:Pass++
    } else {
        Write-Host "FAIL $Label (stdout missing '$Needle'): $Haystack" -ForegroundColor Red
        $script:Fail++
    }
}

function Assert-Empty {
    param([string]$Label, [string]$Actual)
    if ([string]::IsNullOrEmpty($Actual)) {
        Write-Host "PASS $Label (no output)" -ForegroundColor Green
        $script:Pass++
    } else {
        Write-Host "FAIL $Label (expected empty, got: $Actual)" -ForegroundColor Red
        $script:Fail++
    }
}

function New-TempProject {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    return $tmp
}

function Write-Marker {
    param([string]$ProjectDir, [string]$StartedAt)
    $stride = Join-Path $ProjectDir '.stride'
    if (-not (Test-Path $stride)) { New-Item -ItemType Directory -Path $stride -Force | Out-Null }
    $marker = Join-Path $stride '.orchestrator_active'
    $payload = '{"session_id":"test","started_at":"' + $StartedAt + '","pid":12345}'
    Set-Content -Path $marker -Value $payload -NoNewline
}

function Invoke-Gate {
    param(
        [string]$ProjectDir,
        [string]$SkillName,
        [bool]$AllowDirect = $false
    )
    # Gemini BeforeTool fixture: tool_name=activate_skill, tool_input.name=<skill>,
    # cwd=<proj>. The gate prefers stdin cwd; CLAUDE_PROJECT_DIR is set as a
    # fallback so the gate works even if cwd extraction fails.
    $cwdEscaped = $ProjectDir -replace '\\','\\\\'
    $inputJson = '{"tool_name":"activate_skill","cwd":"' + $cwdEscaped + '","tool_input":{"name":"' + $SkillName + '"}}'

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $psi.FileName) {
        $psi.FileName = (Get-Command powershell -ErrorAction Stop).Source
    }
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Gate`""
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.EnvironmentVariables['CLAUDE_PROJECT_DIR'] = $ProjectDir
    if ($AllowDirect) {
        $psi.EnvironmentVariables['STRIDE_ALLOW_DIRECT'] = '1'
    } else {
        $psi.EnvironmentVariables.Remove('STRIDE_ALLOW_DIRECT') | Out-Null
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Write($inputJson)
    $proc.StandardInput.Close()
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()

    return @{
        ExitCode = $proc.ExitCode
        Stdout   = $stdout.Trim()
        Stderr   = $stderr.Trim()
    }
}

function Now-Iso { [datetime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }
function FiveHoursAgoIso { [datetime]::UtcNow.AddHours(-5).ToString('yyyy-MM-ddTHH:mm:ssZ') }

# --- Tests ---

function Test-MarkerMissingBlocks {
    $proj = New-TempProject
    try {
        $r = Invoke-Gate -ProjectDir $proj -SkillName 'stride-claiming-tasks'
        Assert-Eq 'marker missing → blocks claiming' 2 $r.ExitCode
        Assert-Contains 'marker missing → block JSON' '"decision":"block"' $r.Stdout
    } finally { Remove-Item -Recurse -Force $proj }
}

function Test-MarkerFreshAllows {
    $proj = New-TempProject
    try {
        Write-Marker $proj (Now-Iso)
        $r = Invoke-Gate -ProjectDir $proj -SkillName 'stride-claiming-tasks'
        Assert-Eq 'marker fresh → allows' 0 $r.ExitCode
        Assert-Empty 'marker fresh → silent' $r.Stdout
    } finally { Remove-Item -Recurse -Force $proj }
}

function Test-MarkerStaleBlocks {
    $proj = New-TempProject
    try {
        Write-Marker $proj (FiveHoursAgoIso)
        $r = Invoke-Gate -ProjectDir $proj -SkillName 'stride-claiming-tasks'
        Assert-Eq 'marker stale (5h) → blocks' 2 $r.ExitCode
        Assert-Contains 'marker stale → reason mentions stale' 'stale' $r.Stdout
    } finally { Remove-Item -Recurse -Force $proj }
}

function Test-StrideWorkflowAlwaysAllowed {
    $proj = New-TempProject
    try {
        $r = Invoke-Gate -ProjectDir $proj -SkillName 'stride-workflow'
        Assert-Eq 'stride-workflow no marker → allowed' 0 $r.ExitCode
        Assert-Empty 'stride-workflow → silent' $r.Stdout

        $r2 = Invoke-Gate -ProjectDir $proj -SkillName 'stride:stride-workflow'
        Assert-Eq 'stride:stride-workflow no marker → allowed' 0 $r2.ExitCode
    } finally { Remove-Item -Recurse -Force $proj }
}

function Test-NonStrideSkillAllowed {
    $proj = New-TempProject
    try {
        $r = Invoke-Gate -ProjectDir $proj -SkillName 'superpowers:brainstorming'
        Assert-Eq 'non-Stride skill no marker → allowed' 0 $r.ExitCode
        Assert-Empty 'non-Stride skill → silent' $r.Stdout

        $r2 = Invoke-Gate -ProjectDir $proj -SkillName 'frontend-design'
        Assert-Eq 'non-Stride bare skill → allowed' 0 $r2.ExitCode
    } finally { Remove-Item -Recurse -Force $proj }
}

function Test-AllowDirectBypasses {
    $proj = New-TempProject
    try {
        $r = Invoke-Gate -ProjectDir $proj -SkillName 'stride-claiming-tasks' -AllowDirect $true
        Assert-Eq 'STRIDE_ALLOW_DIRECT=1 → bypass' 0 $r.ExitCode
        Assert-Empty 'STRIDE_ALLOW_DIRECT=1 → silent' $r.Stdout
    } finally { Remove-Item -Recurse -Force $proj }
}

function Test-PluginNamespacedNameGated {
    $proj = New-TempProject
    try {
        $r = Invoke-Gate -ProjectDir $proj -SkillName 'stride:stride-claiming-tasks'
        Assert-Eq 'stride:stride-claiming-tasks (no marker) → blocked' 2 $r.ExitCode
        Assert-Contains 'namespaced block JSON' '"decision":"block"' $r.Stdout
    } finally { Remove-Item -Recurse -Force $proj }
}

# --- Execute ---

Write-Host 'Running stride-skill-gate.ps1 tests (Gemini variant)...'
Write-Host ''

Test-MarkerMissingBlocks
Test-MarkerFreshAllows
Test-MarkerStaleBlocks
Test-StrideWorkflowAlwaysAllowed
Test-NonStrideSkillAllowed
Test-AllowDirectBypasses
Test-PluginNamespacedNameGated

Write-Host ''
Write-Host "Results: $script:Pass passed, $script:Fail failed"

if ($script:Fail -gt 0) { exit 1 }
exit 0
