# check-plugin-current.ps1 — stale-install check run once at Step 0 (W2465).
# Same behaviour as hooks/check-plugin-current.sh; a change to one belongs in both.
#
# Ports stride W2251 to the Gemini CLI. Gemini runs every custom agent and
# skill from the copy under its extensions directory, so a published fix does
# nothing for a user whose installed copy is behind it, and the claim's
# skills_version is "1.0" on every release, so the server never notices.
#
# WHAT IT READS
#   installed: the "version" string of gemini-extension.json in the directory
#              ABOVE this script's own hooks\ directory (the extension root,
#              which hooks.json reaches as ${extensionPath}). The script takes
#              no path argument; any argument is ignored.
#   published: the "version" of the entry named exactly "stride-gemini" in the
#              stride-gemini-marketplace catalog (a JSON array), fetched once
#              over HTTPS.
#
# WHAT IT PRINTS: one line, only when installed < published, naming both
# numbers and `gemini extensions update stride-gemini`. Otherwise nothing —
# including when the manifest is missing (the README's copy-the-skills
# install), a version is not dotted numbers, the fetch fails or times out, the
# body is not the expected array, or no stride-gemini entry exists. It never
# guesses a version. EXIT STATUS is always 0.
#
# SAFETY: the catalog address is fixed in this file and nothing passed in can
# change it; with redirects refused (AllowAutoRedirect off) the request cannot
# be bounced to another host. ConvertFrom-Json reads the body as plain data, it
# is never run, and stdout only ever sees text that passed the version pattern.
# The request carries no token, cookie or credential header.
#
# ORDERING is per dot-separated part, as numbers (1.50.0 is newer than 1.9.0);
# a missing part counts as 0; a pre-release is older than its own release; two
# pre-releases of one release are left unordered, which means silence.
# The [version] type is avoided: it cannot parse a pre-release suffix.
#
# TIMEOUT: the request runs through HttpClient with a 3-second Timeout that
# covers connecting, the headers and the whole body (see Invoke-StridePinRequest).
# The bash script gets the same effect from curl --max-time 3. One gap remains on
# Windows PowerShell 5.1, whose name resolution is not bounded by that Timeout.
#
# PS7 NOTE: ConvertFrom-Json unrolls a one-element array into a bare object
# unless -NoEnumerate is given, so ConvertFrom-StrideJson passes it wherever the
# cmdlet has it (Windows PowerShell 5.1 has no such switch and never unrolls).
# That keeps a manifest or catalog of the wrong shape from passing for the
# right one, as it cannot in the bash half.
#
# TESTING: when this file is dot-sourced it only defines its functions and does
# not run, which lets test-stride-hook.ps1 swap Get-StridePinBody for a fixture
# instead of turning the address into a parameter.

Set-StrictMode -Version Latest

$script:StrideGeminiPinUrl = 'https://raw.githubusercontent.com/cheezy/stride-gemini-marketplace/main/extensions.json'
$script:StrideGeminiUpdateCmd = 'gemini extensions update stride-gemini'
# \z, not $: in .NET a $ anchor also matches before a trailing newline. The
# trailing newlines themselves are stripped first by ConvertTo-StrideBashValue,
# so \z only has to refuse a newline anywhere else.
$script:StrideGeminiVersionRe = '^[0-9]+(\.[0-9]+)*(-[0-9A-Za-z.-]+)?\z'
$script:StrideGeminiExtensionRoot = ''
if (-not [string]::IsNullOrEmpty($PSScriptRoot)) {
    $script:StrideGeminiExtensionRoot = Split-Path -Parent $PSScriptRoot
}

# Parse JSON text without unrolling a one-element array (see PS7 NOTE above).
function ConvertFrom-StrideJson {
    param([string]$Text)
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('NoEnumerate')) {
        return , ($Text | ConvertFrom-Json -NoEnumerate -ErrorAction Stop)
    }
    return , ($Text | ConvertFrom-Json -ErrorAction Stop)
}

function Test-StrideVersionShape {
    param([string]$Version)
    if ([string]::IsNullOrEmpty($Version)) { return $false }
    return ($Version -cmatch $script:StrideGeminiVersionRe)
}

# Strip every trailing LF, exactly what bash's $(...) does to the same value,
# so both halves read "1.51.0\n" as 1.51.0 (bash Test Group 36k, here 21j).
# Only LF: $(...) leaves a CR, and so does this, for VERSION_RE to refuse.
function ConvertTo-StrideBashValue {
    param([string]$Value)
    return $Value.TrimEnd([char]10)
}

# Return the "version" string of <Root>\gemini-extension.json, or ''.
function Get-StrideInstalledVersion {
    param([string]$Root)
    if ([string]::IsNullOrEmpty($Root)) { return '' }
    try {
        $manifest = Join-Path $Root 'gemini-extension.json'
        if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { return '' }
        $parsed = ConvertFrom-StrideJson (Get-Content -LiteralPath $manifest -Raw -ErrorAction Stop)
        if ($parsed -isnot [System.Management.Automation.PSCustomObject]) { return '' }
        if ($parsed.PSObject.Properties.Match('version').Count -gt 0 -and $parsed.version -is [string]) {
            return (ConvertTo-StrideBashValue $parsed.version)
        }
    } catch {
        return ''
    }
    return ''
}

# One GET of the catalog with the whole exchange - connecting, the headers and
# the body - inside a single 3-second budget. HttpClient.Timeout covers all of
# it because GetAsync buffers the full body (ResponseContentRead) before it
# returns, on PowerShell 7 and on Windows PowerShell 5.1 alike; that is why this
# does not use Invoke-WebRequest, whose -TimeoutSec stops applying once the
# headers arrive on several releases. Redirects, cookies and default
# credentials are all switched off. Throws on any failure.
function Invoke-StridePinRequest {
    Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $handler.UseDefaultCredentials = $false
    $client = New-Object System.Net.Http.HttpClient -ArgumentList $handler
    try {
        $client.Timeout = [TimeSpan]::FromSeconds(3)
        $null = $client.DefaultRequestHeaders.UserAgent.TryParseAdd('curl/stride-gemini-check')
        $resp = $client.GetAsync($script:StrideGeminiPinUrl).GetAwaiter().GetResult()
        if (-not $resp.IsSuccessStatusCode) { return '' }
        return [string]$resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    } finally {
        $client.Dispose()
    }
}

# Fetch the catalog text, or ''. The test suite replaces this in-process.
function Get-StridePinBody {
    try {
        return [string](Invoke-StridePinRequest)
    } catch {
        return ''
    }
}

# The stride-gemini entry's version in the catalog text, or '' when absent.
function Get-StridePublishedVersion {
    param([string]$Body)
    if ([string]::IsNullOrEmpty($Body)) { return '' }
    try {
        $catalog = ConvertFrom-StrideJson $Body
        if ($catalog -isnot [array]) { return '' }
        foreach ($entry in $catalog) {
            if ($entry -isnot [System.Management.Automation.PSCustomObject]) { continue }
            if ($entry.PSObject.Properties.Match('name').Count -eq 0) { continue }
            if ($entry.name -isnot [string] -or $entry.name -cne 'stride-gemini') { continue }
            if ($entry.PSObject.Properties.Match('version').Count -gt 0 -and $entry.version -is [string]) {
                return (ConvertTo-StrideBashValue $entry.version)
            }
            return ''
        }
    } catch {
        return ''
    }
    return ''
}

# $true only if the first version sorts below the second; callers pass two
# strings that already matched the version pattern.
function Test-StrideVersionOlder {
    param([string]$Older, [string]$Newer)
    $aCore = ($Older -split '-', 2)[0]
    $bCore = ($Newer -split '-', 2)[0]
    $aPre = $Older.Length -gt $aCore.Length
    $bPre = $Newer.Length -gt $bCore.Length
    $aParts = $aCore.Split('.')
    $bParts = $bCore.Split('.')
    $n = [Math]::Max($aParts.Count, $bParts.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = [decimal]0
        $y = [decimal]0
        if ($i -lt $aParts.Count) { $x = [decimal]::Parse($aParts[$i], [System.Globalization.CultureInfo]::InvariantCulture) }
        if ($i -lt $bParts.Count) { $y = [decimal]::Parse($bParts[$i], [System.Globalization.CultureInfo]::InvariantCulture) }
        if ($x -lt $y) { return $true }
        if ($x -gt $y) { return $false }
    }
    # Same numbers: the only ordered case left is a pre-release against its release.
    return ($aPre -and -not $bPre)
}

function Invoke-StridePluginCheck {
    param([string]$Root)
    $installed = Get-StrideInstalledVersion $Root
    if (-not (Test-StrideVersionShape $installed)) { return }
    $published = Get-StridePublishedVersion (Get-StridePinBody)
    if (-not (Test-StrideVersionShape $published)) { return }
    $older = $false
    try { $older = Test-StrideVersionOlder $installed $published } catch { return }
    if ($older) {
        Write-Output ("This stride-gemini extension is at {0}; stride-gemini-marketplace lists {1}. To catch up, run: {2}" -f $installed, $published, $script:StrideGeminiUpdateCmd)
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-StridePluginCheck $script:StrideGeminiExtensionRoot } catch { $null = $_ }
    exit 0
}
