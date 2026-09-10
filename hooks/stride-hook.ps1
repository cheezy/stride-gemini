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
# (W2144) The loop-state record the Stop/AfterAgent gate reads. THE HOOK writes
# this, never the agent: an agent-written marker is exactly as skippable as the
# instruction it replaces. Path is identical to the bash half and to the Claude
# Code original (W2123) - all three must interoperate on one path. Nested
# Join-Path rather than a '.stride/.loop-state.json' literal: Windows
# PowerShell 5.1's Join-Path takes only two path arguments.
$LoopStateFile = Join-Path (Join-Path $ProjectDir '.stride') '.loop-state.json'

# (W1519) Keys the server supplied with an empty value. SetEnvironmentVariable
# with '' DELETES the Process env var, so Invoke-StrideSection re-adds these to
# each bash child's env block to honor the defined-but-empty contract (a
# server-omitted GOAL_* must be visible as empty, never trigger set -u aborts).
$StrideEmptyEnvKeys = @()

# (W1457) Record the set of paths already modified or untracked at claim time,
# each with its current blob hash, so Invoke-ChangedFilesUpload can exclude
# changes that predate the claim. Persisted on disk (claim and completion can
# happen in different sessions), cleaned up with the other hook artifacts.
# Best-effort: failure leaves an absent baseline, which the filter treats as
# "no exclusion".
function Write-DirtyBaseline {
    param([string]$BaseRef)
    $blFile = Join-Path $ProjectDir '.stride-dirty-baseline'
    Remove-Item -Force $blFile -ErrorAction SilentlyContinue
    if (-not $BaseRef) { return }
    try {
        $tracked = @(& git -C $ProjectDir diff --name-only $BaseRef 2>$null)
        if ($LASTEXITCODE -ne 0) { $tracked = @() }
        $untracked = @(& git -C $ProjectDir ls-files --others --exclude-standard 2>$null)
        if ($LASTEXITCODE -ne 0) { $untracked = @() }
        $paths = @(($tracked + $untracked) | Where-Object { $_ } | Select-Object -Unique)
        if ($paths.Count -eq 0) { return }
        $lines = @()
        foreach ($p in $paths) {
            $full = Join-Path $ProjectDir $p
            if (Test-Path -LiteralPath $full -PathType Leaf) {
                $h = (& git -C $ProjectDir hash-object -- $p 2>$null | Out-String).Trim()
                if ($LASTEXITCODE -ne 0 -or -not $h) { $h = 'unhashable' }
            } else {
                $h = 'absent'
            }
            $lines += "$h $p"
        }
        Set-Content -Path $blFile -Value $lines -Encoding UTF8
    } catch {
        # Best-effort — an absent baseline just means no exclusion.
    }
}

# (W1457) Load the dirty baseline as a path->hash map; $null when absent.
function Read-DirtyBaseline {
    $blFile = Join-Path $ProjectDir '.stride-dirty-baseline'
    if (-not (Test-Path -LiteralPath $blFile -PathType Leaf)) { return $null }
    $map = @{}
    try {
        foreach ($line in Get-Content -Path $blFile -Encoding UTF8) {
            if ($line -match '^(\S+) (.+)$') { $map[$Matches[2]] = $Matches[1] }
        }
    } catch {
        return $null
    }
    if ($map.Count -eq 0) { return $null }
    return $map
}

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

# =========================================================================
# The stdout-preservation guard (W2183) — Windows half
# =========================================================================
#
# The bash half carries the full rationale. The short version: this port reads a
# Stride response off a `run_shell_command` call's stdout and NOWHERE ELSE -- there is no canonical
# response file here -- so every hiding form is refused, with no target
# exemption. A file-first sibling permits `--output <its canonical file>`; that
# reasoning does not transfer and must not be imported.
#
# THIS HALF EXISTS BECAUSE THE OTHER ONE CANNOT RUN HERE: stride-hook.sh execs
# this script on native Windows BEFORE it reads stdin, so a bash-only guard
# would leave every Windows session unguarded while looking complete.
#
# The four refusal messages are BYTE-IDENTICAL to the bash half's, and the suite
# asserts that. They are fixed literals selected by a switch: the command text
# carries a Bearer token and nothing derived from it may reach a message.
#
# The token is `deny` -- not `block`, which belongs to other runtimes in this
# fleet. Both documented BeforeTool forms are emitted (stdout document and exit
# 2), because neither has been measured against a live CLI from this repository.

$GeminiGuardMaxScan = 65536

function Get-GeminiGuardCmdWord {
    param([string]$Stage)
    foreach ($w in ($Stage -split '\s+')) {
        if ($w -eq '') { continue }
        if ($w -match '=') { continue }
        if ($w -in @('env','command','builtin','exec','nohup','time')) { continue }
        # Compound-command keywords, so a curl inside `if`/`while`/`( )`/`{ }`
        # is still found. Without these the whole segment was skipped.
        if ($w -in @('if','then','elif','else','fi','while','until','do','done','!')) { continue }
        return ($w -split '[\\/]')[-1]
    }
    return ''
}

# Quote blanking with state carried ACROSS NEWLINES, honouring the shell's
# escape asymmetry. Length-preserving, so the raw and blanked views can be cut
# at shared offsets.
function Get-GeminiGuardBlanked {
    param([string]$Text)
    $sb = New-Object System.Text.StringBuilder
    $q = ''; $i = 0; $n = $Text.Length
    while ($i -lt $n) {
        $c = $Text[$i]
        if ($q -eq '') {
            if ($c -eq '\') {
                [void]$sb.Append(' ')
                if ($i + 1 -lt $n) { [void]$sb.Append(' '); $i += 2 } else { $i += 1 }
                continue
            }
            if ($c -eq '"' -or $c -eq "'") { $q = $c; [void]$sb.Append(' '); $i += 1; continue }
            [void]$sb.Append($c); $i += 1; continue
        }
        if ($q -eq '"' -and $c -eq '\') {
            [void]$sb.Append(' ')
            if ($i + 1 -lt $n) { [void]$sb.Append(' '); $i += 2 } else { $i += 1 }
            continue
        }
        if ($c -eq $q) { $q = ''; [void]$sb.Append(' '); $i += 1; continue }
        [void]$sb.Append(' '); $i += 1
    }
    return $sb.ToString()
}

# Raw text with every redirect TARGET blanked, for the scope test only: without
# it, `curl https://x/y > /tmp/api/tasks/9/complete` is refused because the
# endpoint appears -- but only where the output was going, never where the
# request was.
function Get-GeminiGuardScopeText {
    param([string]$Raw, [string]$Blanked)
    $out = [System.Text.StringBuilder]::new($Raw)
    $n = $Blanked.Length
    $i = 0
    while ($i -lt $n) {
        if ($Blanked[$i] -ne '>') { $i++; continue }
        $j = $i + 1
        while ($j -lt $n -and ($Blanked[$j] -eq '>' -or $Blanked[$j] -eq '|' -or $Blanked[$j] -eq '&')) { $j++ }
        while ($j -lt $n -and ($Blanked[$j] -eq ' ' -or $Blanked[$j] -eq "`t")) { $j++ }
        while ($j -lt $n -and $Blanked[$j] -notmatch '[\s;|&]') {
            if ($j -lt $out.Length) { $out[$j] = ' ' }
            $j++
        }
        $i = $j
    }
    return $out.ToString()
}

function Get-GeminiGuardRedirectKind {
    param([string]$Segment)
    $n = $Segment.Length
    for ($i = 0; $i -lt $n; $i++) {
        if ($Segment[$i] -ne '>') { continue }
        # The stderr-only exemption is tested FIRST, for the reason given on the
        # bash half: the other order refuses `2>&2`, which leaves the body on
        # stdout.
        $prev = if ($i -gt 0) { $Segment[$i - 1] } else { ' ' }
        if ($prev -eq '>') { continue }
        if ($prev -eq '2') {
            $before = if ($i -gt 1) { $Segment[$i - 2] } else { ' ' }
            if ($before -eq ' ' -or $before -eq "`t" -or $i -eq 1) { continue }
        }
        if ($i + 2 -lt $n -and $Segment.Substring($i, 3) -eq '>&2') { return 'redirect' }
        if ($prev -eq '&') { return 'redirect' }
        return 'redirect'
    }
    return ''
}

function Get-GeminiGuardReason {
    param([string]$Raw)
    if ($Raw -notmatch '/api/tasks/') { return '' }
    if ($Raw -notmatch 'curl') { return '' }

    $joined = ($Raw -replace "\\\r?\n", ' ')
    $whole = $false
    if ([System.Text.Encoding]::UTF8.GetByteCount($joined) -le $GeminiGuardMaxScan) {
        $scan = Get-GeminiGuardBlanked -Text $joined
    } else {
        # Above the ceiling: stateless AND judged as one unit. Segmenting
        # unblanked text shatters the command on the `;` inside its own payload.
        $scan = $joined
        $whole = $true
    }
    # Neutralise the grouping characters, length-preservingly.
    $scan = ($scan -replace '[()`{}]', ' ')
    if ($scan.Length -ne $joined.Length) { $scan = $joined; $whole = $true }

    $pairs = @()
    if ($whole) {
        $pairs += ,@($joined, $scan)
    } else {
        $start = 0; $i = 0; $n = $scan.Length
        while ($i -lt $n) {
            $two = if ($i + 1 -lt $n) { $scan.Substring($i, 2) } else { '' }
            if ($two -eq '&&' -or $two -eq '||') {
                if ($i -gt $start) { $pairs += ,@($joined.Substring($start, $i - $start), $scan.Substring($start, $i - $start)) }
                $i += 2; $start = $i; continue
            }
            if ($scan[$i] -eq ';' -or $scan[$i] -eq "`n") {
                if ($i -gt $start) { $pairs += ,@($joined.Substring($start, $i - $start), $scan.Substring($start, $i - $start)) }
                $i += 1; $start = $i; continue
            }
            $i += 1
        }
        if ($n -gt $start) { $pairs += ,@($joined.Substring($start, $n - $start), $scan.Substring($start, $n - $start)) }
    }

    foreach ($pair in $pairs) {
        $segRaw = $pair[0]
        $seg    = $pair[1]
        # In WHOLE mode $seg is the unblanked command, so a `>` in a live payload
        # reads as an operator and the token after it -- possibly the URL -- would
        # be blanked out of the scope view, permitting the call on the branch that
        # exists to over-refuse. There the raw text is the scope text. The bash
        # half cuts at the same place, as do both sibling ports (W2184).
        $scopeText = if ($whole) { $segRaw } else { Get-GeminiGuardScopeText -Raw $segRaw -Blanked $seg }
        if ($scopeText -notmatch '/api/tasks/') { continue }

        $sawCurl = $false
        $first = $true
        foreach ($stage in ($seg -split '\|')) {
            $word = Get-GeminiGuardCmdWord -Stage $stage
            $isCurl = ($word -eq 'curl') -or ($whole -and ($stage -match '(^|\s)curl(\s|$)'))
            if ($isCurl) {
                $sawCurl = $true
                $tokens = @($stage -split '\s+' | Where-Object { $_ -ne '' })
                foreach ($tok in $tokens) {
                    # -ceq / -cmatch throughout: PowerShell's default matching is
                    # case-insensitive, and -o versus -O is the whole of this
                    # rule's two kinds.
                    if ($tok -ceq '-O' -or $tok -ceq '--remote-name') { return 'remote' }
                    # Named before the generic --* skip below, for the reason
                    # given on the bash half.
                    if ($tok -ceq '--remote-name-all') { return 'remote' }
                    if ($tok -ceq '-o' -or $tok -ceq '--output') { return 'flag' }
                    if ($tok.StartsWith('--output=')) { return 'flag' }
                    if ($tok.StartsWith('--')) { continue }
                    if ($tok.StartsWith('-')) {
                        if ($tok -cmatch 'O') { return 'remote' }
                        if ($tok -cmatch 'o') { return 'flag' }
                    }
                }
                $first = $false
                continue
            }
            # An ALLOWLIST: anything downstream of curl that is not `tee`
            # consumes the body, and a fixed list silently permits every
            # consumer nobody named. `tee` earns no follow-on exemption here,
            # because nothing reads the file it writes.
            if (-not $first -and $sawCurl -and $word -ne '' -and $word -ne 'tee') {
                return 'pipe'
            }
            $first = $false
        }
        if (-not $sawCurl) { continue }
        $kind = Get-GeminiGuardRedirectKind -Segment $seg
        if ($kind -ne '') { return $kind }
    }
    return ''
}

function Deny-GeminiGuard {
    param([string]$Kind)
    # BYTE-IDENTICAL to the bash half. Fixed strings; the command is never
    # interpolated, because it carries a Bearer token.
    switch ($Kind) {
        'flag'     { $msg = 'Refused by Gemini BeforeTool deny: this writes the Stride response to a file with -o/--output, so it never reaches stdout. This port reads a response off the tool stdout and nowhere else -- there is no canonical response file here to fall back to -- so hiding it means no loop state is recorded, the AfterAgent gate cannot see that the task was completed, and changed_files lands empty, none of it with an error. Let the body print.' }
        'remote'   { $msg = 'Refused by Gemini BeforeTool deny: -O/--remote-name writes the Stride response to a local file named after the URL, so it never reaches stdout. This port reads a response off the tool stdout and nowhere else -- there is no canonical response file here to fall back to -- so hiding it means no loop state is recorded, the AfterAgent gate cannot see that the task was completed, and changed_files lands empty, none of it with an error. Let the body print.' }
        'pipe'     { $msg = 'Refused by Gemini BeforeTool deny: piping the Stride response into another command consumes it before this hook reads it. This port reads a response off the tool stdout and nowhere else, so a consumer leaves nothing behind: no loop state is recorded, the AfterAgent gate cannot see that the task was completed, and changed_files lands empty, silently. tee is the only pipe permitted here, because it passes stdout through unchanged; every other command is refused rather than matched against a list of known ones. To inspect a field, let the body print and read it from the response you already have.' }
        'redirect' { $msg = 'Refused by Gemini BeforeTool deny: this redirect takes the Stride response off stdout. This port reads a response off the tool stdout and nowhere else, so redirecting it means no loop state is recorded, the AfterAgent gate cannot see that the task was completed, and changed_files lands empty, with no error anywhere. A stderr-only redirect (2>, 2>>, 2>&1) is fine and is NOT refused, because it leaves the body where this hook reads it. Let the body print.' }
        default    { return }
    }
    $doc = [ordered]@{ decision = 'deny'; reason = $msg } | ConvertTo-Json -Compress -Depth 3
    [Console]::Out.Write($doc + "`n")
    [Console]::Error.Write($msg + "`n")
    exit 2
}

if ($Phase -eq 'pre') {
    $GeminiGuardHit = Get-GeminiGuardReason -Raw $Command
    if ($GeminiGuardHit -ne '') { Deny-GeminiGuard -Kind $GeminiGuardHit }
}


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

            # Shape 3: raw API JSON object directly in tool_response.
            # Guard property access by name first — under Set-StrictMode Latest,
            # reading a non-existent property (e.g. .data on the stdout-wrapper
            # object) throws, which would otherwise abort the whole caching block
            # before the persisted-output fallback and base-ref refresh run.
            if (-not $taskJson -and $response -is [PSCustomObject]) {
                $responseProps = $response.PSObject.Properties.Name
                if (($responseProps -contains 'data') -and $response.data -and $response.data.id) {
                    $taskJson = $response.data
                } elseif (($responseProps -contains 'id') -and $response.id) {
                    $taskJson = $response
                }
            }

            # Shape 4: persisted-output file fallback (W1087, mirrors the bash
            # Shape 4). When the claim response is large, the host writes the
            # tool output to a file and leaves only a "Full output saved to:
            # <absolute path>" notice in stdout. Recover the API JSON by reading
            # that file. The path is harness-controlled, so require an existing
            # regular file and parse it with ConvertFrom-Json only — never
            # invoke, dot-source, or write to it.
            if (-not $taskJson) {
                $notice = $null
                if ($response -is [PSCustomObject] -and $response.PSObject.Properties.Name -contains 'stdout') {
                    $notice = $response.stdout
                } elseif ($response -is [string]) {
                    $notice = $response
                }
                if ($notice -and ($notice -imatch 'saved to')) {
                    # Keep the path from its first "/" to end of the notice line so
                    # a path containing spaces survives; tolerate a wrapping quote.
                    $noticeLine = ($notice -split "`n" | Where-Object { $_ -imatch 'saved to' } | Select-Object -First 1)
                    if ($noticeLine) {
                        $persistPath = '/' + ($noticeLine -replace '^[^/]*/', '')
                        $persistPath = ($persistPath.TrimEnd()) -replace '"$', ''
                        if (Test-Path -LiteralPath $persistPath -PathType Leaf) {
                            try {
                                $persistObj = (Get-Content -LiteralPath $persistPath -Raw -ErrorAction SilentlyContinue) | ConvertFrom-Json
                                # Guard property access by name (StrictMode) so an
                                # id-only persisted payload caches identity lines
                                # exactly as the bash reference does, rather than
                                # throwing and falling through to the base-ref-only
                                # refresh.
                                $persistProps = $persistObj.PSObject.Properties.Name
                                if (($persistProps -contains 'data') -and $persistObj.data -and $persistObj.data.id) {
                                    $taskJson = $persistObj.data
                                } elseif (($persistProps -contains 'id') -and $persistObj.id) {
                                    $taskJson = $persistObj
                                }
                            } catch {
                                # persisted file not parseable JSON — fall through
                            }
                        }
                    }
                }
            }

            # (D142) This block refreshes IDENTITY only. TASK_BASE_REF is
            # deliberately NOT written here: the ## before_doing section has not
            # run yet, and its `git pull` moves HEAD — a base captured now would
            # anchor the diff at the PRE-pull commit and span another clone's
            # pulled work (D132/W1678). Invoke-FinalizeBeforeDoing writes the
            # base (and the dirty baseline) after the section finishes.
            if ($taskJson) {
                # Identity lines ONLY — overwriting the whole cache here also
                # strips any inherited TASK_BASE_REF / TASK_BASE_REF_TRUSTED.
                $cacheLines = @(
                    "TASK_ID=$($taskJson.id)"
                    "TASK_IDENTIFIER=$($taskJson.identifier)"
                    "TASK_TITLE=$($taskJson.title)"
                    "TASK_STATUS=$($taskJson.status)"
                    "TASK_COMPLEXITY=$($taskJson.complexity)"
                    "TASK_PRIORITY=$($taskJson.priority)"
                )
                $cacheLines | Set-Content -Path $EnvCache -Encoding UTF8
            } elseif (Test-Path $EnvCache) {
                # (W1086/D142) No parseable response and no usable persisted
                # file: keep the existing TASK_ identity lines (a later
                # completion can still recover TASK_ID) but STRIP the inherited
                # TASK_BASE_REF (and its trust marker) NOW — even if this process
                # dies before Invoke-FinalizeBeforeDoing rewrites it, a base from
                # a previous task or session must never survive a claim.
                $preserved = @(Get-Content $EnvCache -Encoding UTF8 | Where-Object { $_ -notmatch '^TASK_BASE_REF=' -and $_ -notmatch '^TASK_BASE_REF_TRUSTED=' })
                if ($preserved.Count -gt 0) {
                    $preserved | Set-Content -Path $EnvCache -Encoding UTF8
                } else {
                    Remove-Item -Force $EnvCache -ErrorAction SilentlyContinue
                }
            }

            # A claim always opens a new task window: clear the previous task's
            # snapshot, upload state (W1095 — a stale 2xx would suppress the
            # before_review self-heal retry), and dirty baseline unconditionally.
            Remove-Item -Force (Join-Path $ProjectDir '.stride-changed-files.json') -ErrorAction SilentlyContinue
            Remove-Item -Force (Join-Path $ProjectDir '.stride-diff-upload-state') -ErrorAction SilentlyContinue
            Remove-Item -Force (Join-Path $ProjectDir '.stride-dirty-baseline') -ErrorAction SilentlyContinue
        }
    } catch {
        # Caching failure is non-fatal
    }

    # (W2144) Deliberately OUTSIDE the try/catch above: the three sibling
    # clears sit inside it, so an exception anywhere in the env-cache parse
    # skips them. This one must be reached on EVERY claim, including one whose
    # response body is unparsable, which is what makes it match the bash half
    # (where the clears sit under no error trap at all).
    #
    # The clear is UNCONDITIONAL - it runs on a failed claim, an empty-queue
    # claim and an unparsable claim body alike. The most common failed claim is
    # against an empty Ready queue, which is how essentially every session ends;
    # a record preserved there is byte-identical to one left by an agent that
    # completed and never claimed again, yet a gate must refuse in the second
    # case and must not in the first. An over-eager clear costs only a missed
    # gate, and missed is the safe side.
    #
    # Announced on failure, unlike the silent siblings: their staleness is
    # benign, a stale loop state is the one direction this design calls
    # dangerous. Gemini requires JSON-only stdout, so it goes to stderr.
    try {
        if (Test-Path -LiteralPath $LoopStateFile) {
            Remove-Item -LiteralPath $LoopStateFile -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $LoopStateFile) {
                [Console]::Error.WriteLine("stride-hook: could not clear the loop state at $LoopStateFile; a stale completion record remains")
            }
        }
    } catch { }
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

# PUT the on-disk snapshot to /api/tasks/<id>/changed_files as the
# transport-encoded envelope {"changed_files":{"encoding":"base64",
# "data":"<b64>"}} so an edge request filter does not misread a unified code
# diff as an attack and drop the upload (D61). The raw file bytes are
# encoded directly so the wire body carries no recognizable source text.
# Returns the HTTP status code as a string ('000' on transport failure),
# warns on stderr for non-2xx, and never throws. Mirror of stride-hook.sh's
# upload_changed_files_snapshot (W1094) — shared by Invoke-FinalizeAfterDoing
# and the before_review self-heal.
function Invoke-ChangedFilesUpload {
    param([string]$TaskId, [string]$ApiBase, [string]$Token)
    $snapshotPath = Join-Path $ProjectDir '.stride-changed-files.json'
    $httpCode = '000'
    try {
        $bytes = [System.IO.File]::ReadAllBytes($snapshotPath)
        # D67: defensively strip the hook's OWN root artifacts from the snapshot
        # before upload. The bash capture already excludes them, but this ps1
        # may PUT a snapshot produced by an older/unfiltered capture or one that
        # was committed into the repo. Match only the exact repo-root paths — a
        # same-named file in a subdirectory has a path prefix and is kept. Only
        # re-encode when an artifact was actually dropped, so an already-clean
        # snapshot uploads byte-for-byte as before; an unparseable snapshot
        # falls through to the raw bytes unchanged.
        try {
            $entries = @([System.Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json)
            # (W1457) Hard name exclusions (.stride.md, .stride_auth.md — the
            # auth file must NEVER be uploaded — and the baseline artifact),
            # plus the claim-time dirty-baseline exclusion: entries whose path
            # was already dirty at claim AND whose file is hash-identical now
            # are pre-existing unrelated edits, not task work. Hash mismatch,
            # deletion, or unhashable -> keep (include when in doubt).
            $dirtyBaseline = Read-DirtyBaseline
            # (D142) Paths that differ between TASK_BASE_REF and HEAD are
            # COMMITTED task work — the task's auto-commit contains them, so the
            # baseline filter below must never drop them (D137 silently lost 4
            # tracked edits and an untracked migration whose content matched
            # their claim-time hashes after the auto-commit).
            $committedRange = @()
            $cfBase = [System.Environment]::GetEnvironmentVariable('TASK_BASE_REF', 'Process')
            if ($cfBase) {
                try {
                    $committedRange = @(& git -C $ProjectDir diff --name-only $cfBase HEAD 2>$null)
                    if ($LASTEXITCODE -ne 0) { $committedRange = @() }
                } catch {
                    $committedRange = @()
                }
            }
            $filtered = @($entries | Where-Object {
                if ($_.path -eq '.stride-diff-upload-state' -or
                    $_.path -eq '.stride-changed-files.json' -or
                    $_.path -eq '.stride-dirty-baseline' -or
                    $_.path -eq '.stride.md' -or
                    $_.path -eq '.stride_auth.md') { return $false }
                if ($dirtyBaseline -and $dirtyBaseline.ContainsKey($_.path)) {
                    # (D142) Committed-range override: a path the task's commits
                    # contain is task work by definition — never baseline-excluded.
                    if ($committedRange -contains $_.path) { return $true }
                    $blHash = $dirtyBaseline[$_.path]
                    if ($blHash -eq 'unhashable') { return $true }
                    $full = Join-Path $ProjectDir $_.path
                    if (Test-Path -LiteralPath $full -PathType Leaf) {
                        $curHash = (& git -C $ProjectDir hash-object -- $_.path 2>$null | Out-String).Trim()
                        if ($LASTEXITCODE -ne 0 -or -not $curHash) { return $true }
                    } else {
                        $curHash = 'absent'
                    }
                    return ($curHash -ne $blHash)
                }
                return $true
            })
            if ($filtered.Count -ne $entries.Count) {
                # Pipe (not -InputObject) so an array is not double-wrapped into
                # [[...]]; guard the empty case explicitly because piping zero
                # items emits nothing rather than `[]`.
                if ($filtered.Count -eq 0) {
                    $filteredJson = '[]'
                } else {
                    $filteredJson = $filtered | ConvertTo-Json -Depth 10 -Compress -AsArray
                }
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($filteredJson)
            }
        } catch {
            # Snapshot not parseable as the expected array — keep the raw bytes.
        }
        $b64 = [System.Convert]::ToBase64String($bytes)
        $body = @{ changed_files = @{ encoding = 'base64'; data = $b64 } } |
            ConvertTo-Json -Depth 5 -Compress
        # -SkipHttpErrorCheck keeps non-2xx responses on the success path so
        # the real status code is recorded instead of a generic '000'.
        $resp = Invoke-WebRequest `
            -Uri "$ApiBase/api/tasks/$TaskId/changed_files" `
            -Method Put `
            -Body $body `
            -ContentType 'application/json' `
            -Headers @{ Authorization = "Bearer $Token" } `
            -UseBasicParsing -SkipHttpErrorCheck -TimeoutSec 10
        $httpCode = "$($resp.StatusCode)"
    } catch {
        # Transport failure (connection refused, DNS, timeout) — '000',
        # matching the bash twin's `|| printf '000'`.
        $httpCode = '000'
    }
    # Surface a failed upload instead of dropping it silently. The diff is
    # non-fatal to completion, so we warn rather than abort.
    if ($httpCode -notmatch '^2') {
        [Console]::Error.WriteLine(
            "stride-hook: changed_files upload failed (HTTP $httpCode) for task $TaskId")
    }
    return $httpCode
}

# Record the outcome of a changed_files PUT attempt (W1094) so the
# before_review self-heal can verify it on a fresh timeout budget. Task id
# and HTTP code ONLY — never the URL or bearer token (the file lives
# untracked in the project root alongside the other .stride artifacts).
function Write-DiffUploadState {
    param([string]$TaskId, [string]$HttpCode)
    try {
        Set-Content -Path (Join-Path $ProjectDir '.stride-diff-upload-state') `
            -Value "task_id=$TaskId`nhttp_code=$HttpCode" -Encoding UTF8
    } catch {
        # Best-effort: a failed state write must never block the hook.
    }
}

# Fire-and-forget upload of the per-file diff snapshot to the Stride server.
# Mirror of stride-hook.sh's finalize_after_doing PUT path. URL and token are
# resolved by Resolve-StrideApiUrl / Resolve-StrideApiToken — preferring
# $ProjectDir/.stride_auth.md so the upload works whether the agent's completion
# curl used literal values or shell variables, with the $Command literal
# extraction kept as a back-compat fallback. Silently no-ops if any prerequisite
# is missing (snapshot file, URL, token, TASK_ID) so behavior degrades to the
# legacy on-disk-only snapshot.
# (D127) Resolve the authoritative task id for the CURRENT completion from the
# /complete or /mark_reviewed URL in the command, independent of the env cache.
# Mirror of stride-hook.sh's task_id_from_command. Those URLs always carry
# /api/tasks/<id>/<action>, so the changed_files upload targets the task the
# agent is actually completing even when a hidden claim left a STALE TASK_ID in
# the env cache — the confirmed empty-changed_files root cause (G321/D126: the
# diff was PUT to the previous task). Returns '' for the claim path (whose URL
# has no id); callers fall back to the env-cache TASK_ID then.
function Get-TaskIdFromCommand {
    param([string]$CommandText)
    if ($CommandText -match '/api/tasks/([0-9]+)/(?:complete|mark_reviewed)') {
        return $Matches[1]
    }
    return ''
}

function Invoke-FinalizeAfterDoing {
    if ($HookName -ne 'after_doing') { return }
    $snapshotPath = Join-Path $ProjectDir '.stride-changed-files.json'
    if (-not (Test-Path $snapshotPath)) { return }

    $apiBase = Resolve-StrideApiUrl
    $token = Resolve-StrideApiToken

    # (D127) Target the task id from the /complete URL, not the env cache, so a
    # stale TASK_ID from a hidden claim response cannot route the diff to the
    # wrong task. Fall back to the env-cache TASK_ID only if the URL carries no id.
    $taskId = Get-TaskIdFromCommand -CommandText $Command
    if (-not $taskId) { $taskId = [System.Environment]::GetEnvironmentVariable('TASK_ID', 'Process') }
    if (-not $apiBase -or -not $token -or -not $taskId) { return }

    $httpCode = Invoke-ChangedFilesUpload -TaskId $taskId -ApiBase $apiBase -Token $token
    # (W1094) Record the outcome after EVERY PUT attempt so the before_review
    # self-heal can verify it on a fresh timeout budget. A skipped PUT
    # (missing preconditions) deliberately writes nothing: missing state
    # means "no healthy upload on record" and the retry re-checks the same
    # preconditions itself.
    Write-DiffUploadState -TaskId $taskId -HttpCode $httpCode
}

# (D142) Rewrite TASK_BASE_REF — and re-record the dirty baseline — AFTER the
# ## before_doing section has run. Mirror of stride-hook.sh's
# finalize_before_doing: the section's `git pull` moves HEAD, so a base captured
# before it anchors the after_doing diff at the PRE-pull commit and the snapshot
# spans another clone's pulled work (the D132/W1678 incident). Called from the
# main flow right after Invoke-StrideSection returns for the before_doing route,
# regardless of the section's exit code (the claim already succeeded — AfterTool
# cannot veto it). Skips silently when HEAD is unresolvable (not a git repo) —
# the pre-section strip already removed any inherited TASK_BASE_REF in that case.
function Invoke-FinalizeBeforeDoing {
    if ($HookName -ne 'before_doing') { return }
    $baseRef = ''
    try {
        $rev = & git -C $ProjectDir rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $rev) { $baseRef = ($rev | Out-String).Trim() }
    } catch {
        $baseRef = ''
    }
    if (-not $baseRef) { return }
    try {
        # TASK_BASE_REF_TRUSTED marks a base written by THIS post-before_doing
        # capture (the task branch point by construction) — the bash twin's
        # resolve_snapshot_base skips its branch-point rule for marked bases so a
        # workflow that pushes its own task commits before completing stays safe.
        $preserved = @()
        if (Test-Path $EnvCache) {
            $preserved = @(Get-Content $EnvCache -Encoding UTF8 | Where-Object { $_ -notmatch '^TASK_BASE_REF=' -and $_ -notmatch '^TASK_BASE_REF_TRUSTED=' })
        }
        $newLines = $preserved + "TASK_BASE_REF=$baseRef" + "TASK_BASE_REF_TRUSTED=1"
        $newLines | Set-Content -Path $EnvCache -Encoding UTF8
        [System.Environment]::SetEnvironmentVariable('TASK_BASE_REF', $baseRef, 'Process')
        [System.Environment]::SetEnvironmentVariable('TASK_BASE_REF_TRUSTED', '1', 'Process')
        # (W1457→D142) The dirty baseline moves with the base capture: post-pull
        # paths hashed against the post-pull tree, so the exclusion set and the
        # diff anchor can never disagree.
        Write-DirtyBaseline -BaseRef $baseRef
    } catch {
        # Best-effort — a failed rewrite must never block the hook.
    }
}

# (W1094) Self-heal for the changed_files upload — mirror of
# stride-hook.sh's self_heal_changed_files_upload. The after_doing gate can
# burn the whole hook budget, killing the process before or during the
# snapshot PUT — or the PUT itself returned non-2xx. before_review (AfterTool
# on the same completion curl) runs on a FRESH budget, so it verifies the
# recorded outcome and re-PUTs the on-disk snapshot when no healthy upload is
# on record for the current task. Best-effort: never throws, never changes
# the hook's exit semantics. Unlike the bash twin this script has no capture
# step — the on-disk snapshot is the source of truth, so the retry re-uploads
# it as-is.
function Invoke-SelfHealChangedFilesUpload {
    if ($HookName -ne 'before_review') { return }
    $snapshotPath = Join-Path $ProjectDir '.stride-changed-files.json'
    if (-not (Test-Path $snapshotPath)) { return }
    # (D127) Prefer the task id from the /complete URL over the env-cache TASK_ID
    # so the self-heal re-PUTs to the CORRECT task even after a stale claim.
    $taskId = Get-TaskIdFromCommand -CommandText $Command
    if (-not $taskId) { $taskId = [System.Environment]::GetEnvironmentVariable('TASK_ID', 'Process') }
    if (-not $taskId) { return }

    # Healthy 2xx recorded for THIS task → do not re-upload (snapshot
    # semantics anchor at after_doing time; avoid pointless API load).
    # Missing file, different task id, or non-2xx/empty code → retry.
    $stateFile = Join-Path $ProjectDir '.stride-diff-upload-state'
    $stateTask = ''
    $stateCode = ''
    if (Test-Path $stateFile) {
        try {
            foreach ($line in Get-Content -Path $stateFile -Encoding UTF8) {
                if ($line -match '^task_id=(.*)$' -and -not $stateTask) { $stateTask = $Matches[1] }
                if ($line -match '^http_code=(.*)$' -and -not $stateCode) { $stateCode = $Matches[1] }
            }
        } catch {
            # Unreadable state degrades to "retry".
        }
    }
    if ($stateTask -eq $taskId -and $stateCode -match '^2') { return }

    $apiBase = Resolve-StrideApiUrl
    $token = Resolve-StrideApiToken
    if (-not $apiBase -or -not $token) { return }

    $httpCode = Invoke-ChangedFilesUpload -TaskId $taskId -ApiBase $apiBase -Token $token
    Write-DiffUploadState -TaskId $taskId -HttpCode $httpCode
    # (W1658) before_review is the LAST retry. A non-2xx here means the diff is
    # definitively lost for this task — surface it loudly (distinct from the
    # per-attempt warning) and mark the state file unresolved so the failure is
    # actionable and never silently swallowed. A later successful PUT overwrites
    # the state file, clearing the mark.
    if ($httpCode -notmatch '^2') {
        [Console]::Error.WriteLine("stride-hook: CHANGED_FILES UPLOAD UNRESOLVED for task $taskId (HTTP $httpCode) after the before_review retry — the review will show NO file diffs. Re-run the changed_files PUT to recover.")
        try {
            Add-Content -Path (Join-Path $ProjectDir '.stride-diff-upload-state') -Value 'unresolved=yes' -Encoding UTF8
        } catch {
            # Best-effort: a failed marker write must never block the hook.
        }
    }
}

# (W1456) Shell-semantics line-continuation check for the bash-section parser
# — mirror of line_continues in stride-hook.sh. Returns $true when the LOGICAL
# line ends in a backslash that escapes the newline: unescaped and not inside
# single quotes. Inside single quotes a backslash is a literal character; a
# trailing `\\` is an escaped backslash, not a continuation. Callers pass the
# accumulated logical line so quote state carries across joins.
function Test-LineContinues {
    param([string]$Line)

    $i = 0
    $state = 'none'
    while ($i -lt $Line.Length) {
        $c = $Line[$i]
        if ($state -eq 'single') {
            if ($c -eq "'") { $state = 'none' }
            $i++
        } elseif ($c -eq '\') {
            if (($i + 1) -eq $Line.Length) { return $true }
            $i += 2
        } elseif ($state -eq 'double') {
            if ($c -eq '"') { $state = 'none' }
            $i++
        } else {
            if ($c -eq "'") { $state = 'single' }
            elseif ($c -eq '"') { $state = 'double' }
            $i++
        }
    }
    return $false
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

    # (W1456) Join backslash-continued physical lines into logical lines first
    # (the backslash-newline pair is removed, per shell semantics); trimming
    # and comment/blank skipping apply to logical lines AFTER joining. Mirror
    # of the stride-hook.sh loop.
    $secCmdList = @()
    $secPending = ''
    foreach ($cmd in ($secCommands -split "`n")) {
        $cmd = $cmd.TrimEnd("`r")
        if ($secPending) {
            $cmd = $secPending + $cmd
            $secPending = ''
        } else {
            # Comments never continue: '#' lexes to end-of-line in shell, so a
            # trailing backslash on a standalone comment line is inert — skip
            # it here so it cannot swallow the next command.
            if ($cmd.TrimStart().StartsWith('#')) { continue }
        }
        if (Test-LineContinues -Line $cmd) {
            $secPending = $cmd.Substring(0, $cmd.Length - 1)
            continue
        }
        $trimmedCmd = $cmd.TrimStart()
        if (-not $trimmedCmd) { continue }
        if ($trimmedCmd.StartsWith('#')) { continue }
        $secCmdList += $trimmedCmd
    }
    # Trailing backslash on the section's last line — emit the accumulated
    # command with the marker already stripped; never hang or drop it.
    if ($secPending) {
        $trimmedCmd = $secPending.TrimStart()
        if ($trimmedCmd -and -not $trimmedCmd.StartsWith('#')) {
            $secCmdList += $trimmedCmd
        }
    }

    if ($secCmdList.Count -eq 0) {
        Invoke-FinalizeAfterDoing
        return 0
    }

    Set-Location $ProjectDir

    # Early per-file diff snapshot upload (W1093 parity, ported in W1095) —
    # the after_doing section runs the full quality gate, and the hook
    # timeout can kill this process mid-loop, silently losing the diff
    # upload. PUT the snapshot BEFORE the first command executes; the
    # post-loop call below is KEPT as a refresh once the gate succeeds. A
    # bare call is safe: Invoke-FinalizeAfterDoing gates internally on the
    # GLOBAL $HookName (so the after_goal reuse of this function stays
    # inert), emits nothing on stdout, and never throws.
    Invoke-FinalizeAfterDoing

    $secCompletedCmds = @()
    # Parallel to $secCompletedCmds: one object per successful command holding
    # its tail-truncated stdout/stderr, folded into the success JSON's
    # commands_output array (D65). Keeps passing-gate output off Console.Error
    # so the host does not render it under a false hook-error label.
    $secCmdOutputs = @()
    $secStartTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    # (W1455) Millisecond wall clock for duration_ms reporting; the seconds
    # clock above stays for any whole-second bookkeeping.
    $secStartMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $secCmdIndex = 0
    $secCmdTotal = $secCmdList.Count

    foreach ($execTrimmed in $secCmdList) {
        $secStdoutFile = [System.IO.Path]::GetTempFileName()
        $secStderrFile = [System.IO.Path]::GetTempFileName()

        try {
            # ProcessStartInfo.ArgumentList passes each element as an exact
            # argv entry on every platform. Start-Process -ArgumentList must
            # NOT be used here: it joins the elements into a single string,
            # which .NET on Unix re-splits on whitespace, so a multi-word
            # command reaches bash -c mangled and its output is lost.
            $secPsi = [System.Diagnostics.ProcessStartInfo]::new()
            $secPsi.FileName = 'bash'
            $secPsi.ArgumentList.Add('-c')
            $secPsi.ArgumentList.Add($execTrimmed)
            $secPsi.RedirectStandardOutput = $true
            $secPsi.RedirectStandardError = $true
            $secPsi.UseShellExecute = $false
            $secPsi.WorkingDirectory = (Get-Location).Path
            # (W1519) Re-add empty-valued keys the Process env block cannot
            # hold, so user commands see them defined-but-empty per the Step 6
            # env matrix contract (prevents ${VAR?} / set -u aborts).
            foreach ($emptyKey in $script:StrideEmptyEnvKeys) {
                $secPsi.Environment[$emptyKey] = ''
            }
            $proc = [System.Diagnostics.Process]::Start($secPsi)
            # Drain both pipes concurrently: a synchronous ReadToEnd on
            # stdout would deadlock if the child fills the stderr pipe
            # buffer (~64KB) while its stdout is still open — gate commands
            # like `mix compile` can emit that much warning text.
            $secOutTask = $proc.StandardOutput.ReadToEndAsync()
            $secErrTask = $proc.StandardError.ReadToEndAsync()
            $proc.WaitForExit()
            $secProcStdout = $secOutTask.Result
            $secProcStderr = $secErrTask.Result
            Set-Content -Path $secStdoutFile -Value $secProcStdout -Encoding UTF8 -NoNewline
            Set-Content -Path $secStderrFile -Value $secProcStderr -Encoding UTF8 -NoNewline

            if ($proc.ExitCode -eq 0) {
                $secCompletedCmds += $execTrimmed
                # Do NOT write the passing command's output to Console.Error:
                # the host renders any hook stderr under a red hook-error label
                # even on exit 0 (D65). Instead capture a tail-truncated copy —
                # same -50 cap as the failure path below — into $secCmdOutputs,
                # folded into the success JSON's commands_output array so agents
                # keep visibility.
                $secOkStdout = ''
                $secOkStderr = ''
                if (Test-Path $secStdoutFile) {
                    # @() guards against $null (empty file) under StrictMode.
                    $allLines = @(Get-Content $secStdoutFile -Encoding UTF8)
                    if ($allLines.Count -gt 50) { $allLines = $allLines[-50..-1] }
                    $secOkStdout = $allLines -join "`n"
                }
                if (Test-Path $secStderrFile) {
                    $allLines = @(Get-Content $secStderrFile -Encoding UTF8)
                    if ($allLines.Count -gt 50) { $allLines = $allLines[-50..-1] }
                    $secOkStderr = $allLines -join "`n"
                }
                $secCmdOutputs += [ordered]@{
                    command = $execTrimmed
                    stdout  = $secOkStdout
                    stderr  = $secOkStderr
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
    # (W1095) This is the REFRESH of the early pre-loop upload — keep it: the
    # gate's commands may rewrite the snapshot, and this re-uploads the
    # final state.
    Invoke-FinalizeAfterDoing

    $secEndTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $secDuration = $secEndTime - $secStartTime
    # (W1455) duration_ms is the hook-execution.md contract field; never
    # negative. duration_seconds is DEPRECATED — kept for one release for any
    # consumer still parsing it.
    $secDurationMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $secStartMs
    if ($secDurationMs -lt 0) { $secDurationMs = 0 }

    $successResult = [ordered]@{
        hook               = $Section
        status             = 'success'
        commands_completed = $secCompletedCmds
        commands_output    = $secCmdOutputs
        duration_ms        = $secDurationMs
        duration_seconds   = $secDuration
    }
    # Depth 6 so the commands_output array of objects serializes fully.
    [Console]::Out.WriteLine(($successResult | ConvertTo-Json -Depth 6 -Compress))

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

# --- Server-supplied hook env forwarding (W1519, mirrors stride W1453) ---
# The Step 6 env matrix (skills/stride-workflow/SKILL.md) declares the server's
# hook env block the single source of truth for the variables the executor
# exports. The functions below extract the `env` object from the hook entry of
# an intercepted response (singular `.hook` on claim responses, `.hooks[]` on
# /complete and /mark_reviewed), export every key into the Process environment
# (inherited by the bash -c children that run the sections), and append it to
# the env cache so follow-up agent commands (e.g. the after_goal PATCH) can
# still read the values. Keys the server omits export as empty strings. Mirrors
# the bash extract_response_payload / extract_hook_env / apply_env_lines /
# export_after_goal_env helpers — both scripts must agree on behavior.

# Peel the API payload out of the Gemini/Claude hook input. Same three shapes
# as Test-AfterGoalInResponse. Returns the parsed payload object, or $null.
function Get-ResponsePayload {
    param([string]$InputJson)

    if (-not $InputJson) { return $null }

    try {
        $parsed = $InputJson | ConvertFrom-Json
    } catch {
        return $null
    }

    # -cnotcontains: bash reads this with jq '.tool_response', which is
    # case-SENSITIVE. Get-CompletionRawBody reads the same two keys, so leaving
    # this case-insensitive would have the two readers of one field disagree.
    if ($parsed.PSObject.Properties.Name -cnotcontains 'tool_response') { return $null }

    $resp = $parsed.tool_response
    if (-not $resp) { return $null }

    $payload = $null

    # Shape 1: {"stdout":"<json>"} wrapper (Bash-tool host)
    if ($resp -is [PSCustomObject] -and $resp.PSObject.Properties.Name -ccontains 'stdout') {
        try { $payload = $resp.stdout | ConvertFrom-Json } catch { $payload = $null }
    }

    # Shape 2: tool_response is itself a JSON-encoded string
    if ($null -eq $payload -and $resp -is [string]) {
        try { $payload = $resp | ConvertFrom-Json } catch { $payload = $null }
    }

    # Shape 3: raw API JSON object directly
    if ($null -eq $payload -and $resp -is [PSCustomObject]) {
        $payload = $resp
    }

    return $payload
}

# (W2144) Loop-state helpers - the twin of the bash half's loop_state_safe /
# loop_state_payload_ok / write_loop_state / record_loop_state_for_completion.
# Both halves must produce a BYTE-IDENTICAL record for the same input, so every
# divergence risk is closed deliberately and commented where it is closed.

# Charset gate. \A and \z rather than ^ and $, and -cmatch rather than -match:
# in .NET, $ matches at end-of-string OR immediately before a trailing newline,
# so "abc`n" would pass a $-anchored pattern and be recorded verbatim while the
# bash half's charset glob refuses it. \z admits no such trailing newline.
function Test-LoopStateSafe {
    param([string]$Value)
    if (-not $Value) { return $false }
    if ($Value.Length -gt 64) { return $false }
    return ($Value -cmatch '\A[A-Za-z0-9_.:-]+\z')
}

# Strip trailing LFs, and ONLY trailing LFs. This exists solely because the
# bash half reads both values through $( ), and command substitution strips
# every trailing newline - without this the halves disagree on exactly one
# input class. Deliberately not \r?\n: stripping CRLF would record "abc" for
# "abc`r`n" where bash records "unknown", closing the LF divergence by opening
# a CR one. Interior newlines are untouched and both halves still refuse them.
function ConvertTo-LoopStateValue {
    param([string]$Value)
    if ($null -eq $Value) { return '' }
    return ($Value -creplace '\n+\z', '')
}

# A payload describes a SUCCESSFUL completion only when it carries the two
# fields the state file is built from, AT THE RIGHT JSON TYPES. Every
# non-success body the API emits (validation errors, 404s, 422s) lacks .data
# entirely, so this is the discriminator.
#
# -isnot [bool] is the exact mirror of the bash half's jq `type == "boolean"`:
# ConvertFrom-Json maps JSON true to [bool], "true" to [string] and 1 to an
# integer, so a body carrying "needs_review":"true" is refused on both halves
# for the same reason. Set-StrictMode -Version Latest is active file-wide, so
# every property read is existence-guarded first.
#
# -cnotcontains, not -notcontains: jq's `.data.identifier` is CASE-SENSITIVE,
# whereas both -contains and PowerShell property access are case-INSENSITIVE.
# Without the case-sensitive form a body carrying "Data" or "Identifier" would
# be accepted and recorded here and refused by the bash half - the same
# parse-boundary divergence class the task's pitfalls warn about, latent only
# because the Stride API happens to emit lowercase keys.
function Test-LoopStatePayloadOk {
    param($Payload)
    if ($null -eq $Payload) { return $false }
    if ($Payload -isnot [PSCustomObject]) { return $false }
    if ($Payload.PSObject.Properties.Name -cnotcontains 'data') { return $false }
    $d = $Payload.data
    if ($null -eq $d) { return $false }
    if ($d -isnot [PSCustomObject]) { return $false }
    if ($d.PSObject.Properties.Name -cnotcontains 'identifier') { return $false }
    if ($d.PSObject.Properties.Name -cnotcontains 'needs_review') { return $false }
    # [datetime] is accepted because it can only arise from ConvertFrom-Json
    # coercing a JSON STRING - jq's `type == "string"` is true for the original,
    # so refusing it here would diverge from bash. The literal is recovered in
    # Write-LoopStateForCompletion via Get-RawJsonString.
    if (($d.identifier -isnot [string]) -and ($d.identifier -isnot [datetime])) { return $false }
    if (-not $d.identifier) { return $false }
    if ($d.needs_review -isnot [bool]) { return $false }
    return $true
}

# Return the UNPARSED tool_response body, so the unparsable-body diagnostic can
# be decided by an actual parse attempt. This helper has no bash counterpart
# and is required: bash's RESPONSE_PAYLOAD *is* the raw string, so `jq empty`
# can test it directly, whereas Get-ResponsePayload returns $null for four
# distinct reasons of which only one is a parse failure. Without this, an
# ABSENT tool_response would be announced as a body that failed to parse.
function Get-CompletionRawBody {
    param([string]$InputJson)
    if (-not $InputJson) { return '' }
    try { $parsed = $InputJson | ConvertFrom-Json } catch { return '' }
    if ($null -eq $parsed) { return '' }
    if ($parsed -isnot [PSCustomObject]) { return '' }
    if ($parsed.PSObject.Properties.Name -cnotcontains 'tool_response') { return '' }
    $resp = $parsed.tool_response
    if ($null -eq $resp) { return '' }
    if ($resp -is [string]) { return $resp }
    if ($resp -is [PSCustomObject] -and $resp.PSObject.Properties.Name -ccontains 'stdout') {
        if ($null -eq $resp.stdout) { return '' }
        return [string]$resp.stdout
    }
    return ''
}

# ConvertFrom-Json silently coerces any ISO-8601-shaped JSON STRING into a
# [DateTime] - on every PowerShell version, and with -AsHashtable too - and the
# original text is NOT recoverable from the resulting object ("2026-01-01T00:00:00Z"
# comes back as 01/01/2026 00:00:00). jq performs no such coercion, so without
# this recovery a date-shaped identifier or session id is recorded by the bash
# half and refused here: one input, two outcomes, which is exactly what AC5
# forbids. Re-read the literal out of the raw JSON text instead.
#
# The pattern deliberately matches only an ESCAPE-FREE literal. Any value
# carrying a backslash or a quote would fail the charset gate regardless, so
# declining to recover it costs nothing and keeps this well clear of having to
# reimplement JSON string unescaping. A $null return means "could not recover",
# which every caller treats as a refusal rather than a fallback.
function Get-RawJsonString {
    param([string]$Raw, [string]$Key)
    if (-not $Raw) { return $null }
    $m = [regex]::Match($Raw, '"' + [regex]::Escape($Key) + '"\s*:\s*"([^"\\]*)"')
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value
}

# Atomic and never fatal, mirroring the bash half: the temp is staged in the
# DESTINATION directory so the move is same-volume, a failure at any point
# leaves no temp behind, and the function still returns normally. A completion
# must never fail because a gate input could not be recorded.
function Write-LoopState {
    param([string]$Json)

    # Refuse a destination that exists and is not a regular file, for the same
    # reason the bash half does: a move onto a DIRECTORY relocates the temp
    # inside it and reports success, so the record would land where no reader
    # looks and the temp would survive indefinitely.
    try {
        if ((Test-Path -LiteralPath $LoopStateFile) -and -not (Test-Path -LiteralPath $LoopStateFile -PathType Leaf)) {
            [Console]::Error.WriteLine('stride-hook: loop-state path is not a regular file; not recording')
            return
        }
    } catch { return }

    # Assigned before the try: under Set-StrictMode -Version Latest, reading an
    # unassigned variable in the catch cleanup is itself a terminating error.
    $_tmp = $null
    try {
        $_dir = Split-Path -Parent $LoopStateFile
        if (-not (Test-Path -LiteralPath $_dir)) {
            New-Item -ItemType Directory -Path $_dir -Force -ErrorAction Stop | Out-Null
        }
        $_tmp = Join-Path $_dir ('loop-state.{0}.tmp' -f [System.IO.Path]::GetRandomFileName())

        # WriteAllText with an explicit BOM-less UTF8 encoder and a literal LF.
        # Set-Content and Out-File are BOTH forbidden here: they append
        # [Environment]::NewLine (CRLF on Windows) and, under Windows
        # PowerShell 5.1, -Encoding UTF8 emits a BOM. Either alone breaks
        # byte-identity with the bash half.
        [System.IO.File]::WriteAllText($_tmp, $Json + "`n", (New-Object System.Text.UTF8Encoding $false))

        # Windows PowerShell 5.1 runs on .NET Framework, whose Move-Item -Force
        # is delete-then-move: never partial, but there is a window where the
        # destination is ABSENT. That path is live in this port, not
        # theoretical - stride-hook.sh delegates to powershell.exe (5.1), not
        # pwsh, on native Windows without bash. File::Replace is an atomic
        # overwrite on NTFS; File::Move is an atomic create. Move-Item remains
        # the fallback for the volumes Replace refuses (FAT, some SMB shares).
        # This is an intentional improvement over the reference ps1 - do not
        # "fix" it back on a 1:1 diff.
        try {
            if (Test-Path -LiteralPath $LoopStateFile -PathType Leaf) {
                [System.IO.File]::Replace($_tmp, $LoopStateFile, $null)
            } else {
                [System.IO.File]::Move($_tmp, $LoopStateFile)
            }
        } catch {
            Move-Item -LiteralPath $_tmp -Destination $LoopStateFile -Force -ErrorAction Stop
        }
    } catch {
        [Console]::Error.WriteLine('stride-hook: could not write the loop state; continuing')
        if ($_tmp) {
            try { Remove-Item -LiteralPath $_tmp -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
}

# Self-gates on before_review - the hook that fires AFTER a /complete succeeds.
# Never writes to stdout: Gemini CLI parses this script's stdout as one JSON
# document, so every diagnostic goes to stderr.
#
# The Claude Code original's Tier 2 snapshot-recovery branch is deliberately
# NOT ported: this port has neither .stride/.last-api-response.json nor
# STRIDE_ROUTE_TASK_ID, so there is nothing to fall back to. A harness-
# truncated success simply records nothing, which is the safe direction.
function Write-LoopStateForCompletion {
    param([string]$InputJson, $ResponsePayload)

    if ($HookName -ne 'before_review') { return }

    if (-not (Test-LoopStatePayloadOk -Payload $ResponsePayload)) {
        # A 422 legitimately records nothing and is silent - announcing every
        # failed completion would be noise. An UNPARSABLE body is the different
        # case: the completion may well have succeeded server-side and the
        # evidence is simply lost. Decided by an actual parse of the raw body,
        # never by ($null -eq $ResponsePayload), which conflates four causes.
        $raw = Get-CompletionRawBody -InputJson $InputJson
        if ($raw) {
            $parsedOk = $true
            try { $null = $raw | ConvertFrom-Json } catch { $parsedOk = $false }
            if (-not $parsedOk) {
                [Console]::Error.WriteLine('stride-hook: completion response was unparsable; no loop state recorded')
            }
        } else {
            # W2183 overturns the silence here, on the bash half's reasoning: the
            # 422 excuse does not cover an ABSENT body. A 422 arrives WITH a
            # well-formed body that parses and correctly records nothing. An
            # absent body means the response never reached this hook, so the
            # completion may have landed while no loop state exists -- and the
            # AfterAgent gate reads a missing file as "nothing to gate on" and
            # PERMITS. Byte-identical to the bash line.
            [Console]::Error.WriteLine('stride-hook: no completion response reached this hook; no loop state recorded, so the AfterAgent gate cannot tell this task was completed -- send the completion curl with its stdout intact')
        }
        return
    }

    $identRaw = $ResponsePayload.data.identifier
    if ($identRaw -is [datetime]) {
        # Coerced from a JSON string - recover the literal bash would have seen.
        $identRaw = Get-RawJsonString -Raw (Get-CompletionRawBody -InputJson $InputJson) -Key 'identifier'
        if ($null -eq $identRaw) { return }
    }
    $ident = ConvertTo-LoopStateValue -Value ([string]$identRaw)
    if (-not (Test-LoopStateSafe -Value $ident)) { return }

    # The session id is the ONLY field read out of the hook input, which also
    # carries the Bearer token in .tool_input.command - never widen this read.
    # GEMINI_ before CLAUDE_, the same order the bash half uses and the same
    # order $ProjectDir uses at the top of this file.
    $sid = ''
    try {
        $parsedInput = $InputJson | ConvertFrom-Json
        if ($null -ne $parsedInput -and $parsedInput -is [PSCustomObject] -and
            $parsedInput.PSObject.Properties.Name -ccontains 'session_id' -and
            $null -ne $parsedInput.session_id) {
            # The ladder below mirrors `jq -r '.session_id // empty'` exactly. A
            # bare [string] cast does NOT: it unwraps a single-element array to
            # its element (bash renders the array multi-line and refuses it),
            # renders a PSCustomObject as a dotted type name the charset gate
            # would ACCEPT, and capitalises booleans.
            $v = $parsedInput.session_id
            if ($v -is [string]) {
                $sid = $v
            } elseif ($v -is [bool]) {
                # jq's `//` treats `false` as absent, so bash falls through to
                # the environment for a literal false; `true` renders lowercase.
                $sid = if ($v) { 'true' } else { '' }
            } elseif ($v -is [datetime]) {
                # Must precede the [ValueType] arm - DateTime IS a value type,
                # and Convert.ToString would render it "01/01/2026 00:00:00",
                # which the charset gate refuses while bash records the literal.
                $rec = Get-RawJsonString -Raw $InputJson -Key 'session_id'
                $sid = if ($null -eq $rec) { '<non-scalar>' } else { $rec }
            } elseif ($v -is [ValueType]) {
                # InvariantCulture, or a de-DE host renders 1.5 as "1,5" - a
                # string the bash half could never produce.
                $sid = [System.Convert]::ToString($v, [System.Globalization.CultureInfo]::InvariantCulture)
            } else {
                # An array or object. jq renders it multi-line, so bash's gate
                # refuses it WITHOUT falling back to the environment. This
                # sentinel is non-empty (so no fallback) and cannot pass the
                # gate (so it degrades to "unknown") - the same two steps bash
                # performs, in the same order.
                $sid = '<non-scalar>'
            }
        }
    } catch { $sid = '' }
    if (-not $sid) { $sid = [string]$env:GEMINI_SESSION_ID }
    if (-not $sid) { $sid = [string]$env:CLAUDE_SESSION_ID }
    $sid = ConvertTo-LoopStateValue -Value $sid
    if (-not (Test-LoopStateSafe -Value $sid)) { $sid = 'unknown' }

    # [ordered] is load-bearing: a plain @{} is unordered and would scramble the
    # key order against the bash half's jq object literal. InvariantCulture is
    # equally load-bearing and is a deliberate divergence from the reference
    # ps1, which omits it: '-' is the culture's date separator and ':' its time
    # separator, so under th-TH this would write a Buddhist-era year and under
    # a '.'-separator culture it would write 12.30.00. 'Z' is appended as a
    # literal rather than formatted, so no custom-specifier ambiguity arises.
    $ts = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) + 'Z'
    $obj = [ordered]@{
        identifier   = $ident
        needs_review = [bool]$ResponsePayload.data.needs_review
        completed_at = $ts
        session_id   = $sid
    }

    try { $json = $obj | ConvertTo-Json -Compress -Depth 4 } catch { return }
    if (-not $json) { return }

    Write-LoopState -Json $json
}

# Collect the env object of the named hook entry as an ordered map. Keys must
# be valid shell identifiers — anything else is dropped, because the values
# reach a bash -c child via the environment and the cache loader is
# line-based. HOOK_NAME is excluded (the executor routes on its own value; a
# cached HOOK_NAME line would misroute later invocations). TASK_BASE_REF is
# excluded (client-only diff anchor owned by the claim branch).
function Get-HookEnvFromPayload {
    param($Payload, [string]$HookEntryName)

    $envMap = [ordered]@{}
    if ($null -eq $Payload) { return $envMap }

    $payloadProps = $Payload.PSObject.Properties.Name
    $entries = @()
    if (($payloadProps -contains 'hooks') -and $Payload.hooks) {
        $entries += @($Payload.hooks)
    }
    if (($payloadProps -contains 'hook') -and $Payload.hook -is [PSCustomObject]) {
        $entries += $Payload.hook
    }

    foreach ($entry in $entries) {
        if (-not ($entry -is [PSCustomObject])) { continue }
        if ($entry.PSObject.Properties.Name -notcontains 'name') { continue }
        if ($entry.name -ne $HookEntryName) { continue }
        if ($entry.PSObject.Properties.Name -notcontains 'env') { continue }
        $envObj = $entry.env
        if (-not ($envObj -is [PSCustomObject])) { continue }
        foreach ($prop in $envObj.PSObject.Properties) {
            $key = $prop.Name
            if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
            if ($key -eq 'HOOK_NAME' -or $key -eq 'TASK_BASE_REF') { continue }
            $envMap[$key] = [string]$prop.Value
        }
        break
    }

    return $envMap
}

# Export a map into the Process environment (inherited by the bash -c children
# that run sections) and append it to the env cache, best-effort, so the
# values survive for follow-up agent commands. The cache loader is line-based,
# so embedded newlines are collapsed to spaces in the cached copy — the
# process env keeps the exact value. SetEnvironmentVariable involves no shell
# parsing, so crafted values have no injection surface. Never echoes values to
# stdout/stderr.
function Set-HookEnv {
    param($EnvMap)

    if ($null -eq $EnvMap -or $EnvMap.Count -eq 0) { return }

    $cacheLines = @()
    foreach ($key in @($EnvMap.Keys)) {
        $value = [string]$EnvMap[$key]
        [System.Environment]::SetEnvironmentVariable($key, $value, 'Process')
        if ($value -eq '') {
            # SetEnvironmentVariable('', 'Process') DELETED the variable —
            # remember the key so sections still see it defined-but-empty.
            if ($script:StrideEmptyEnvKeys -notcontains $key) {
                $script:StrideEmptyEnvKeys += $key
            }
        } else {
            $script:StrideEmptyEnvKeys = @($script:StrideEmptyEnvKeys | Where-Object { $_ -ne $key })
        }
        $cacheLines += "$key=" + ($value -replace "`r?`n", ' ')
    }
    try {
        Add-Content -Path $EnvCache -Value $cacheLines -Encoding UTF8
    } catch {
        # Best-effort cache append — export already succeeded.
    }
}

# after_goal env: export what the server supplied, default every documented
# GOAL_* key it omitted to an empty string (defined-but-empty, never an
# error), and fall back to the completed task's parent_id from the same
# response payload when GOAL_ID itself is missing or empty. The fallback is
# response-local — the executor still never queries the API for goal state.
function Set-AfterGoalEnv {
    param($Payload)

    $envMap = Get-HookEnvFromPayload -Payload $Payload -HookEntryName 'after_goal'

    foreach ($key in @('GOAL_ID', 'GOAL_IDENTIFIER', 'GOAL_TITLE', 'GOAL_DESCRIPTION')) {
        if (-not $envMap.Contains($key)) { $envMap[$key] = '' }
    }

    # Parent-id fallback: the server built the after_goal env from the
    # completed child task and omitted GOAL_ID (or sent it empty). The parent
    # id in the same response's data object IS the goal id.
    if (-not $envMap['GOAL_ID'] -and $null -ne $Payload) {
        $parentId = $null
        $payloadProps = $Payload.PSObject.Properties.Name
        if (($payloadProps -contains 'data') -and $Payload.data -and
            ($Payload.data.PSObject.Properties.Name -contains 'parent_id')) {
            $parentId = $Payload.data.parent_id
        } elseif ($payloadProps -contains 'parent_id') {
            $parentId = $Payload.parent_id
        }
        if ($null -ne $parentId -and "$parentId") { $envMap['GOAL_ID'] = "$parentId" }
    }

    Set-HookEnv -EnvMap $envMap
}

# (W1519) Forward the server-supplied hook env for the routed hook. Applied
# AFTER the cache load so server-supplied keys override stale cached values;
# keys the server does not supply keep their cached values. The pre phase has
# no tool_response yet, so this is post-only.
$afterGoalRouted = $false
$responsePayload = $null
if ($Phase -eq 'post') {
    $responsePayload = Get-ResponsePayload -InputJson $RawInput
    Set-HookEnv -EnvMap (Get-HookEnvFromPayload -Payload $responsePayload -HookEntryName $HookName)
}

# (W1094 parity, ported in W1095) Verify-and-retry the changed_files upload
# before the primary before_review section runs — fresh AfterTool budget;
# TASK_ID is in scope from the env cache. Self-gates on
# $HookName == 'before_review'; best-effort, never fails the hook.
try { Invoke-SelfHealChangedFilesUpload } catch { }

# (W2144) Record the loop state for a successful completion. Self-gates on
# $HookName -eq 'before_review' and is best-effort: a failure to record is
# logged to stderr and swallowed, never fatal to the completion. Placed BEFORE
# the primary section because the record is built only from the hook input and
# $responsePayload - nothing the section produces - so a before_review section
# that fails (and exits below) must not cost us the record. The completion
# already succeeded server-side by then; AfterTool cannot un-complete it.
# $responsePayload is $null on the pre phase, where the $HookName gate already
# returns.
try { Write-LoopStateForCompletion -InputJson $RawInput -ResponsePayload $responsePayload } catch { }

# --- Execute the primary hook ---
$primaryRc = Invoke-StrideSection -Section $HookName

# (D142) Capture TASK_BASE_REF only now — AFTER ## before_doing ran its
# `git pull` / branch checkout — so the base is the post-pull branch point.
# Runs even when the section failed: the claim already succeeded (AfterTool
# cannot veto it) and a partially-run section still leaves HEAD more accurate
# than the pre-pull value. No-op for every other hook route.
try { Invoke-FinalizeBeforeDoing } catch { }

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
        $afterGoalRouted = $true
        # (W1519) Export GOAL_* (server-supplied, with the parent-id fallback
        # for GOAL_ID) before the section runs. The section observes
        # HOOK_NAME=after_goal per the documented contract; the prior value is
        # restored afterwards.
        Set-AfterGoalEnv -Payload $responsePayload
        $savedHookNameEnv = [System.Environment]::GetEnvironmentVariable('HOOK_NAME', 'Process')
        [System.Environment]::SetEnvironmentVariable('HOOK_NAME', 'after_goal', 'Process')
        $null = Invoke-StrideSection -Section 'after_goal'
        [System.Environment]::SetEnvironmentVariable('HOOK_NAME', $savedHookNameEnv, 'Process')
    }
}

# Clean up per-lifecycle state after the final hook. after_goal piggy-backs
# on after_review when present, so this gate stays on $HookName ==
# 'after_review'. Mirrors stride-hook.sh, which removes both the env cache and
# the changed-files snapshot here.
if ($HookName -eq 'after_review') {
    # (W1519) Keep the env cache when after_goal rode this response — the agent
    # still needs GOAL_ID from it for the follow-up
    # PATCH /api/tasks/:goal_id/after_goal. The next claim rewrites the cache.
    if (-not $afterGoalRouted) {
        Remove-Item -Force $EnvCache -ErrorAction SilentlyContinue
    }
    Remove-Item -Force (Join-Path $ProjectDir '.stride-changed-files.json') -ErrorAction SilentlyContinue
    # (W1095) Remove the upload state alongside the snapshot at lifecycle end.
    Remove-Item -Force (Join-Path $ProjectDir '.stride-diff-upload-state') -ErrorAction SilentlyContinue
    # (W1457) Clear the claim-time dirty baseline alongside the other artifacts.
    Remove-Item -Force (Join-Path $ProjectDir '.stride-dirty-baseline') -ErrorAction SilentlyContinue
}

exit 0
