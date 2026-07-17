# ============================================================================
# sync-ips-rules.ps1 - Wazuh shared folder -> C:\SuricataIPS\rules
# ============================================================================
# WHY THIS EXISTS
#   Rules edited on the manager
#   (/var/ossec/etc/shared/<group>/suricata-win-offline/rules/) reach every
#   agent's shared folder automatically via merged.mg - but NOTHING carried
#   them the last hop into C:\SuricataIPS\rules, where the running IPS engine
#   actually reads from. Only two things ever wrote that folder:
#
#     1. build-suricata-ips.ps1 Step 11 - reads the shared folder correctly
#        (via the -LocalRulesRepo auto-detect) but only when you run the
#        whole build, which re-downloads ~46 MB of ET Open.
#     2. refresh-suricata-ips-rules.ps1 - pulls from GitHub, NOT the manager,
#        so manager edits were invisible to it. Two sources of truth.
#
#   This script closes that gap: the manager becomes the single source of
#   truth for the agb-* rules, and edits flow to the engine on their own.
#
# WHAT IT SYNCS (and what it deliberately does NOT)
#     agb-white.rules       -> agb-white.rules        verbatim
#     agb-heuristics.rules  -> agb-heuristics.rules   verbatim
#     agb-black.rules       -> agb-black-drop.rules   ^alert converted to drop
#
#   suricata.rules and agb-tor-drop.rules are NOT touched - those are derived
#   from the ET Open download by the build/refresh scripts. Overwriting them
#   from the shared folder would wipe ~50,000 signatures.
#
# SAFETY
#   - skips source files that are 0 bytes or still being written (the manager
#     rewrites shared\ on its own schedule; landing mid-write copies garbage)
#   - syntax whitelist per file: only blank / comment / pass / alert / drop /
#     reject lines. Kills a truncated push or injected content before it can
#     reach the engine.
#   - backs up every replaced file, validates the FULL config with
#     suricata -T, and rolls back + leaves the service alone on failure
#   - restarts SuricataIPS ONCE, and only if something actually changed and
#     the service was already running (each restart is a brief fail-open gap)
#   - no changes = no restart, no log noise
#
# USAGE
#   .\sync-ips-rules.ps1            # sync, validate, restart if needed
#   .\sync-ips-rules.ps1 -DryRun    # report what WOULD change, touch nothing
#
# Needs Administrator / SYSTEM. Log: C:\SuricataIPS\log\sync-ips-rules.log
# ============================================================================
[CmdletBinding()]
param(
    [string]$SourceDir  = "C:\Program Files (x86)\ossec-agent\shared\suricata-win-offline\rules",
    [string]$RuleDir    = "C:\SuricataIPS\rules",
    [string]$DeployRoot = "C:\SuricataIPS",
    [string]$ServiceName = "SuricataIPS",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$SuricataExe = "$DeployRoot\suricata.exe"
$SuricataYaml = "$DeployRoot\suricata.yaml"
$LogDir = "$DeployRoot\log"
$LogFile = "$LogDir\sync-ips-rules.log"

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }
if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) {
    Move-Item $LogFile "$LogFile.old" -Force -ErrorAction SilentlyContinue
}

function Log([string]$m) {
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $m"
    Write-Host $line
    try { Add-Content -Path $LogFile -Value $line -ErrorAction Stop } catch { }
}

# source file -> dest file, and whether to convert alert to drop
$Map = @(
    @{ Src = "agb-white.rules";      Dst = "agb-white.rules";      ToDrop = $false },
    @{ Src = "agb-heuristics.rules"; Dst = "agb-heuristics.rules"; ToDrop = $false },
    @{ Src = "agb-black.rules";      Dst = "agb-black-drop.rules"; ToDrop = $true  }
)

function Test-SourceReady([string]$File) {
    # the Wazuh manager rewrites shared\ from merged.mg on its own schedule.
    # A file caught mid-write is 0 bytes or still locked - leave it for the
    # next run rather than copying a half-written ruleset into the engine.
    $info = Get-Item -LiteralPath $File -ErrorAction SilentlyContinue
    if (-not $info) { return $false }
    if ($info.Length -eq 0) { return $false }
    try {
        $fs = [IO.File]::Open($File, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        $fs.Close()
        return $true
    } catch { return $false }
}

function Test-RulesSyntax([string]$Text, [string]$Name) {
    # A rules file may contain ONLY blank lines, comments, and
    # pass/alert/drop/reject signatures. Anything else means the file is not
    # a ruleset (truncated download, HTML error page, injected content).
    $bad = @()
    $n = 0
    foreach ($line in ($Text -split "`r?`n")) {
        $n++
        if ($line -match '^\s*$') { continue }
        if ($line -match '^\s*#') { continue }
        if ($line -match '^\s*(pass|alert|drop|reject)\s') { continue }
        $bad += "line ${n}: $line"
    }
    if ($bad.Count -gt 0) {
        Log "[!] $Name REJECTED - $($bad.Count) line(s) are neither comment nor signature:"
        $bad | Select-Object -First 3 | ForEach-Object { Log "      $_" }
        return $false
    }
    return $true
}

Log "===== sync-ips-rules starting$(if($DryRun){' (DRY RUN)'}) ====="

# ---------- preflight ----------
foreach ($p in @($SourceDir, $RuleDir, $SuricataExe, $SuricataYaml)) {
    if (-not (Test-Path $p)) { Log "[!] missing: $p - ABORTING"; exit 1 }
}

# ---------- stage ----------
$staged = @()   # files that actually differ
foreach ($m in $Map) {
    $src = Join-Path $SourceDir $m.Src
    $dst = Join-Path $RuleDir  $m.Dst

    if (-not (Test-Path $src)) { Log "[=] $($m.Src) not in shared folder - skipping"; continue }
    if (-not (Test-SourceReady $src)) { Log "[=] $($m.Src) empty or still being written - skipping this run"; continue }

    $text = [IO.File]::ReadAllText($src)

    if ($m.ToDrop) {
        # identical transform to build-suricata-ips.ps1's Get-AgbBlackDropRuleset
        $text = [regex]::Replace($text, '(?m)^alert\s', 'drop ')
        # GOTCHA GUARD: same idea as the build's ET TOR drift check. A rule
        # written with leading whitespace will NOT be converted by the anchored
        # regex above and would silently stay alert-only inside a *-drop file,
        # i.e. it would never block. Surface it instead of hiding it.
        $stillAlert = ([regex]::Matches($text, '(?m)^\s+alert\s')).Count
        if ($stillAlert -gt 0) { Log "[!] WARNING: $stillAlert rule(s) in $($m.Src) start with whitespace before 'alert' - NOT converted to drop, they will not block. Remove the leading space in the source." }
    }

    if (-not (Test-RulesSyntax $text $m.Src)) { Log "[!] refusing to deploy $($m.Src) - ABORTING, nothing changed"; exit 1 }

    # compare the TRANSFORMED text against what is live
    $newHash = [BitConverter]::ToString((New-Object Security.Cryptography.SHA256Managed).ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))
    $oldHash = ""
    if (Test-Path $dst) {
        $oldHash = [BitConverter]::ToString((New-Object Security.Cryptography.SHA256Managed).ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($dst))))
    }

    if ($newHash -eq $oldHash) { Log "[=] $($m.Dst) already current"; continue }

    $sigs = ([regex]::Matches($text, '(?m)^\s*(pass|alert|drop|reject)\s')).Count
    Log "[+] $($m.Src) -> $($m.Dst) CHANGED ($sigs signatures)"
    $staged += @{ Dst = $dst; Text = $text; Name = $m.Dst }
}

if ($staged.Count -eq 0) {
    Log "[=] nothing changed - no restart needed"
    Log "===== sync-ips-rules SUCCEEDED (no-op) ====="
    exit 0
}

if ($DryRun) {
    Log "[=] DRY RUN: $($staged.Count) file(s) would be updated, service would be restarted. Nothing written."
    Log "===== sync-ips-rules DRY RUN complete ====="
    exit 0
}

# ---------- swap in, with backup ----------
$backups = @()
$utf8NoBom = New-Object Text.UTF8Encoding($false)
foreach ($s in $staged) {
    if (Test-Path $s.Dst) {
        $bak = "$($s.Dst).bak"
        Copy-Item $s.Dst $bak -Force
        $backups += @{ Live = $s.Dst; Backup = $bak }
    } else {
        $backups += @{ Live = $s.Dst; Backup = $null }   # did not exist before
    }
    [IO.File]::WriteAllText($s.Dst, $s.Text, $utf8NoBom)
    Log "[+] wrote $($s.Name)"
}

function Restore-Backups {
    foreach ($b in $backups) {
        if ($b.Backup) { Copy-Item $b.Backup $b.Live -Force }
        elseif (Test-Path $b.Live) { Remove-Item $b.Live -Force }
    }
    Log "[!] rolled back to previous rules"
}

# ---------- validate BEFORE restarting ----------
# NOTE: suricata -T is strict and fails on the ET signatures using the
# file.magic keyword (no libmagic on Windows builds). That is expected and
# harmless - the engine loads fine at runtime and just skips those rules.
# Only a REAL parse error should block the restart.
#
# This is EXACTLY the bug that broke refresh-suricata-ips-rules.ps1: it gates
# on `if ($LASTEXITCODE -ne 0)` alone, but -T ALWAYS exits 1 while ET Open
# ships file.magic rules - so it rolled back 100% of the time and its rollback
# deleted the live rule files. Never gate on the exit code alone.
#
# "E: suricata: Loading signatures failed." must be filtered too: it is the
# SUMMARY line the file.magic errors produce, not an independent fault. It is
# safe to ignore because a genuine problem always ALSO emits its own specific
# E: line (e.g. "opening rule file ...: No such file or directory"), which is
# what actually trips the gate below.
Log "[*] validating full config with suricata -T ..."
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$testOutput = & $SuricataExe -T -c $SuricataYaml -l $LogDir 2>&1
$testExit = $LASTEXITCODE
$ErrorActionPreference = $prev

$errorLines = $testOutput | Where-Object { $_ -match '^\s*\[?-?\s*E:' -or $_ -match '<Error>' }
$realErrors = $errorLines | Where-Object { $_ -notmatch 'file\.magic' -and $_ -notmatch 'Loading signatures failed' }

if ($testExit -ne 0 -and $realErrors) {
    Log "[!] suricata -T FAILED with real errors - NOT restarting:"
    $realErrors | Select-Object -First 5 | ForEach-Object { Log "      $_" }
    Restore-Backups
    Log "===== sync-ips-rules FAILED (rolled back, service untouched) ====="
    exit 1
}
if ($errorLines) { Log "[+] config test passed (ignoring $($errorLines.Count) expected file.magic error(s))" }
else { Log "[+] config test passed" }

# ---------- restart once, only if it was running ----------
$svc = Get-Service $ServiceName -ErrorAction SilentlyContinue
if (-not $svc) {
    Log "[=] service $ServiceName not installed - rules updated, nothing to restart"
    Log "===== sync-ips-rules SUCCEEDED (no service) ====="
    exit 0
}
if ($svc.Status -ne 'Running') {
    Log "[=] service $ServiceName is $($svc.Status), not Running - rules updated, leaving it alone"
    Log "===== sync-ips-rules SUCCEEDED (service not running) ====="
    exit 0
}

try {
    Restart-Service $ServiceName -Force -ErrorAction Stop
    Start-Sleep -Seconds 3
    $svc = Get-Service $ServiceName
    if ($svc.Status -ne 'Running') {
        Log "[!] $ServiceName did not come back (status: $($svc.Status)) - rolling back rules"
        Restore-Backups
        Start-Service $ServiceName -ErrorAction SilentlyContinue
        Log "===== sync-ips-rules FAILED (rolled back) ====="
        exit 1
    }
    Log "[+] $ServiceName restarted, status: $($svc.Status)"
} catch {
    Log "[!] restart failed: $($_.Exception.Message) - rolling back rules"
    Restore-Backups
    Log "===== sync-ips-rules FAILED (rolled back) ====="
    exit 1
}

Log "===== sync-ips-rules SUCCEEDED ($($staged.Count) file(s) updated) ====="
exit 0
