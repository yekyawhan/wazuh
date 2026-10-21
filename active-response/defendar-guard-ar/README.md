# Wazuh Active Response — Auto Re-Enable Windows Defender

**Purpose:** When Windows Defender real-time protection is turned OFF on an agent, Wazuh rule **100620** fires and a layered local defense immediately forces it back ON.

**Author:** [redacted] · **Date:** 2026-06-26

---

## Quick Reference (TL;DR)

**On agent (elevated PowerShell):**
```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# Cache-bust on every run: ?v= forces IRM to treat it as a fresh request,
# and the destination path includes the timestamp so the file is new even
# if Remove-Item fails silently. Both layers needed on PS 7 where IRM
# sometimes refuses to overwrite an existing file.
$stamp   = Get-Date -Format 'yyyyMMddHHmmss'
$destDir = Join-Path $env:TEMP "defender-guard-$stamp"
New-Item -ItemType Directory -Path $destDir -Force | Out-Null
irm "https://raw.githubusercontent.com/yekyawhan/wazuh/git-home/active-response/defendar-guard-ar/install.ps1?v=$stamp" -OutFile "$destDir\install.ps1"
Unblock-File "$destDir\install.ps1"
& "$destDir\install.ps1"
```

> **If you have been running an OLD copy of `install.ps1` (it errors on
> line 156 with `Test-Path: ... null ...`), remove all old `defender-guard-*`
> folders under `$env:TEMP` first:**
> ```powershell
> Get-ChildItem $env:TEMP -Filter 'defender-guard-*' -Directory | Remove-Item -Recurse -Force
> ```

**On manager** (`/var/ossec/etc/ossec.conf` inside `<ossec_config>`):
```xml
<command>
  <name>reenable-defender</name>
  <executable>reenable-defender.cmd</executable>
  <timeout_allowed>no</timeout_allowed>
</command>

<active-response>
  <command>reenable-defender</command>
  <location>local</location>
  <rules_id>100010</rules_id>
</active-response>
```

**Validate + restart:**
```bash
sudo /var/ossec/bin/wazuh-analysisd -t
sudo systemctl restart wazuh-manager
```
```powershell
Restart-Service WazuhSvc   # on agent
```

---

## 1. Defense Layers

| Layer | Component | Reaction | Resource use |
|-------|-----------|----------|--------------|
| **0 - prevent** | Tamper Protection ON (`enable-tamper-protection.ps1`) | **0 ms** — disable is rejected at source | — |
| **1 - poll** | `Defender-Guard-Service-Watch` (Scheduled Task, 1 s poll) | **≤ 1 s** | ~20 MB RAM, ~0.01 % CPU |
| **2 - event** | `Defender-Guard-Event-Watch` (Scheduled Task, Event 5001/5010/5012) | **~100 ms** | 0 % CPU at idle |
| **3 - audit** | Wazuh manager AR (rule 100010) | **a few seconds** | log only |

All four are independent. Layer 0 stops the disable entirely. The rest are belt-and-suspenders coverage in case Tamper ever turns off.

The Wazuh manager AR is reactive (alert → manager → agent). Layer 1 + 2 react directly on the **agent**, so the very first disable attempt is re-enabled within ≤ 1 s, with no manager round-trip.

> **Tamper Protection is the only mechanism that completely eliminates the disable window.**
> Tamper ON → `Set-MpPreference -DisableRealtimeMonitoring $true` is REJECTED → no re-enable ever needed.

### Layer 0 — Tamper Protection auto-enable

`enable-tamper-protection.ps1` turns Tamper Protection ON. Run by `install.ps1`,
by `enforce-tamper-protection.ps1`, and on every AR/watcher run.

**It drives the Windows Security UI (UIAutomation), not the registry.** On
Windows 11 26H1 (build 26200) Tamper Protection is a `WdFilter.sys` minifilter
that gates on the *caller token*, not on the value written. Measured on a real
host, as elevated admin **and** as SYSTEM:

| Attempt | Result |
|---|---|
| `Features\TamperProtection = 5` (registry) | `Requested registry access is not allowed` |
| take ownership of the Features key | `Attempted to perform an unauthorized operation` (`NtSetSecurityObject` is vetoed) |
| `reg.exe add ... /f` | `ERROR: Access is denied.` |
| `Set-MpPreference -DisableTamperProtection $false` | `0x80004001` (E_NOTIMPL — the parameter is reserved by design) |
| `Invoke-CimMethod` on `MSFT_MpPreference` | same `0x80004001` |
| `Policies\...\Windows Defender\TamperProtection` | write succeeds, Defender **ignores** it (also after `gpupdate /force`) |
| `Invoke-CommandInDesktopPackage` in SecHealthUI | child token carries **no** package SID → still rejected |

The only caller Defender whitelists for Defender-control RPC is the Windows
Security app package itself:

```
Microsoft.SecHealthUI_8wekyb3d8bbwe
S-1-15-3-1024-3153509613-960666767-3724611135-2725662640-12138253-543910227-1950414635-4190290187
```

So the helper opens `windowsdefender://threatsettings`, finds the
`Tamper Protection` `ToggleSwitch` in the XAML tree, and flips it. The click is
executed *by* SecHealthUI, whose token is on the allow-list.

Verified end-to-end on the test host:

```
toggle state Off -> On, IsTamperProtected False -> True,
Features\TamperProtection 4 -> 5, TamperProtectionSource=UI,
Set-MpPreference -DisableRealtimeMonitoring $true is then overridden
(RTP stays True) == tamper is genuinely enforcing.
```

**Session requirement.** The UI only accepts input from a process in the
interactive user session. A process in session 0 (Wazuh AR, SYSTEM) cannot see
the window at all, so the AR path calls `Start-DefenderGuardTamperInSession`,
which relaunches the helper inside the signed-in session via a Scheduled Task
with `LogonType=Interactive` and waits for the result.

Outcomes, all logged:
- toggle flipped and `IsTamperProtected=True` → success
- toggle flipped but runtime still False → pending Defender refresh/reboot
- toggle not reachable (no interactive session, or UI layout changed) → falls
  back to the GUI/Intune instructions in `tamper-protection-policy.xml`

> On Windows 11 **Pro** the Tamper Protection GPO does not exist
> (`WindowsDefender.admx` is absent on that SKU). For domain-joined Pro fleets
> use Intune; the local GPO path only exists on Enterprise/Education.

---

## 2. Quick Install — Agent side

`install.ps1` does it all in one shot: downloads the four files, places them in the right folders, registers the two Scheduled Tasks, audits Tamper Protection, prints a summary.

| File | Destination |
|------|-------------|
| `reenable-defender.cmd` | `C:\Program Files (x86)\ossec-agent\active-response\bin\` |
| `reenable-defender.ps1` | `C:\Program Files\Sysinternals\` |
| `enable-tamper-protection.ps1` | `C:\Program Files\Sysinternals\` |
| `watchdog-service.ps1` | `C:\Program Files\Sysinternals\` |
| `enforce-tamper-protection.ps1` | `C:\Program Files\Sysinternals\` |
| `tamper-protection-policy.xml` | `C:\Program Files\Sysinternals\` |

After it finishes, do the **manager-side** config above, then restart the agent (`Restart-Service WazuhSvc`).

> **All three PowerShell lines matter.**
> - Without line 1: `Invoke-RestMethod: Unable to read data from the transport connection` (PS 5.1 default is TLS 1.0/1.1; GitHub decommisioned those).
> - Without line 2: `This script contains malicious content and has been blocked by your antivirus software` (Mark-of-the-Web triggers AMSI).
> - Do NOT pipe into `iex` — streaming flattens the body and breaks the parser (`The string is missing the terminator: '@`).
>
> **AMSI on hardened agents will block the script anyway.** When Defender AMSI is
> unsure about a script it creates a probe file `__PSScriptPolicyTest_<hash>.ps1`
> in `C:\Windows\SystemTemp\` to inspect it. If you see that path in alerts
> (Sysmon EventID 11, rule 92205), the AR launched but AMSI flagged the script.
> Persistent on this agent every AR run will leave that probe.
>
> **Fix once with a self-signed code-signing cert.**
>
> Run **once** on any Windows dev box (PowerShell 5.1 or 7+):
> ```powershell
> # cd into a fresh clone of this folder
> .\sign-once.ps1
> # follow the printed "Next steps" - commit and push the regenerated .ps1/.cmd + defender-guard.cer
> ```
> What that does:
> 1. Creates a self-signed code-signing cert (5-year, `CurrentUser\My`)
> 2. Exports the public cert as `defender-guard.cer`
> 3. Signs every `.ps1` and `.cmd` in the folder with `Set-AuthenticodeSignature`
>
> After you commit and push, agents that run `install.ps1` will:
> 1. Download `defender-guard.cer`
> 2. Import it into `LocalMachine\TrustedPeople`
> 3. From that point AMSI sees a trusted publisher for every signed script - no test probe, no quarantine, no `malicious content blocked` error

---

## 3. Files in this Repository

| File | Role |
|------|------|
| `reenable-defender.cmd` | Wrapper Wazuh calls. Prefers PowerShell 7, falls back to Windows PowerShell 5.1. |
| `reenable-defender.ps1` | Does the actual work. AR mode (reads JSON from stdin via `ReadLine()`) or standalone (no stdin). |
| `enable-tamper-protection.ps1` | Layer-0 helper: turns Tamper Protection ON by driving the Windows Security UI (`Enable-TamperProtectionBestEffort`), plus `Start-DefenderGuardTamperInSession` for the session-0 AR path. Dot-sourced by the AR, the install, and the audit script. |
| `watchdog-service.ps1` | 1 s poll: keeps `WinDefend` alive + re-issues `Set-MpPreference -DisableRealtimeMonitoring $false`. |
| `enforce-tamper-protection.ps1` | Audit + re-enforce; attempts the enable via the shared helper, then surfaces GUI/Intune/GPO enable path if it did not stick. |
| `tamper-protection-policy.xml` | Ready-to-paste Intune OMA-URI + GPO ADMX policy for Tamper Protection. |
| `install.ps1` | One-shot installer. Downloads, places, registers both Scheduled Tasks, imports publisher cert, attempts Tamper enable. |
| `sign-once.ps1` | Run once on a Windows dev box. Creates cert, signs every script, exports `.cer`. |
| `defender-guard.cer` | Public cert produced by `sign-once.ps1`; trusted by `install.ps1` on the agent. (Only present after you run `sign-once.ps1`.) |
| `ossec.conf` | Manager-side `<command>` + `<active-response>` blocks. |

### reenable-defender.cmd
```bat
@echo off
setlocal EnableExtensions

set SCRIPT_PATH=C:\Program Files\Sysinternals\reenable-defender.ps1

REM PowerShell 7 first, then Windows PowerShell 5.1 fallback
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" (
    "%ProgramFiles%\PowerShell\7\pwsh.exe" ^
        -NoProfile -NonInteractive -ExecutionPolicy Bypass ^
        -WindowStyle Hidden -File "%SCRIPT_PATH%"
    goto :end
)

if exist "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe" (
    "%ProgramFiles(x86)%\PowerShell\7\pwsh.exe" ^
        -NoProfile -NonInteractive -ExecutionPolicy Bypass ^
        -WindowStyle Hidden -File "%SCRIPT_PATH%"
    goto :end
)

if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" (
    "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" ^
        -NoProfile -NonInteractive -ExecutionPolicy Bypass ^
        -WindowStyle Hidden -File "%SCRIPT_PATH%"
    goto :end
)

powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass ^
    -WindowStyle Hidden -File "%SCRIPT_PATH%"

:end
endlocal
```

---

## 4. Manager-Side Configuration

```bash
ssh <wazuh-manager-user>@<wazuh-manager-ip>

# back up
sudo cp /var/ossec/etc/ossec.conf /var/ossec/etc/ossec.conf.bak.$(date +%F_%H%M)

# check for existing entry (must print nothing)
sudo grep -n 'reenable-defender' /var/ossec/etc/ossec.conf
```

Edit `/var/ossec/etc/ossec.conf` and add inside `<ossec_config>`:
```xml
<command>
  <name>reenable-defender</name>
  <executable>reenable-defender.cmd</executable>
  <timeout_allowed>no</timeout_allowed>
</command>

<active-response>
  <command>reenable-defender</command>
  <location>local</location>
  <rules_id>100010</rules_id>
</active-response>
```

---

## 5. Validate and Restart

```bash
sudo /var/ossec/bin/wazuh-analysisd -t ; echo "exit=$?"
sudo systemctl restart wazuh-manager
sudo systemctl status wazuh-manager --no-pager
```

On the agent:
```powershell
Restart-Service WazuhSvc
```

---

## 6. Test

```powershell
Set-MpPreference -DisableRealtimeMonitoring $true     # triggers rule 100620
Start-Sleep -Seconds 2
(Get-MpComputerStatus).RealTimeProtectionEnabled       # expect: True
Get-Content "C:\Program Files (x86)\ossec-agent\active-response\active-responses.log" -Tail 6

# Service watchdog (catches Stop-Service WinDefend)
Stop-Service WinDefend
Start-Sleep -Seconds 2
Get-Service WinDefend                                 # expect: Running
```

**PASS criteria:** one of these patterns within ~1 s (local watcher) or ~5 s (manager AR):
```
watchdog-service:  RTP disabled -> re-issued ...                # from service poll
reenable-defender: Starting (standalone).                       # from event-trigger watcher
reenable-defender: Starting (AR). stdin=...                    # from manager AR
reenable-defender: Verification Ended. RealTimeProtectionEnabled=True
```

---

## 7. Audit & Verify

```powershell
# 1. Tamper Protection state + recent events
powershell -ExecutionPolicy Bypass -File "C:\Program Files\Sysinternals\enforce-tamper-protection.ps1"

# 2. Both Scheduled Tasks
Get-ScheduledTask | Where-Object { $_.TaskName -like 'Defender-Guard-*' }

# 3. Real-time protection ON
(Get-MpComputerStatus).RealTimeProtectionEnabled

# 4. Wazuh AR wrapper present
Test-Path "C:\Program Files (x86)\ossec-agent\active-response\bin\reenable-defender.cmd"
```

---

## 8. Troubleshooting

| Symptom | Cause / Fix |
|---------|-------------|
| `Invoke-RestMethod: Unable to read data from the transport` | PS 5.1 default TLS 1.0; add `[Net.ServicePointManager]::SecurityProtocol = Tls12` BEFORE `irm`. |
| `This script contains malicious content and has been blocked by your antivirus` | Mark-of-the-Web; add `Unblock-File` after `irm`. |
| `The string is missing the terminator: '@` | Body streamed via `| iex`; use `-OutFile + &` instead. |
| `Registration of the ScheduledTask failed` | Run as Administrator; check `Get-ScheduledTask | ? State` |
| `Disable command is blocked (RTP stays True)` | Tamper Protection is ON — that's the win, not a bug. |
| Manager won't start after edit | XML typo — restore `ossec.conf.bak.*` and re-validate with `wazuh-analysisd -t`. |
| Agent shows disconnected | `Restart-Service WazuhSvc`; confirm agent key still valid. |

---

## 9. Rollback

**Manager:**
```bash
sudo cp /var/ossec/etc/ossec.conf.bak.<timestamp> /var/ossec/etc/ossec.conf
sudo systemctl restart wazuh-manager
```

**Agent:**
```powershell
Unregister-ScheduledTask 'Defender-Guard-Event-Watch','Defender-Guard-Service-Watch' -Confirm:$false
Remove-Item "C:\Program Files (x86)\ossec-agent\active-response\bin\reenable-defender.cmd"
Remove-Item "C:\Program Files\Sysinternals\reenable-defender.ps1"
Remove-Item "C:\Program Files\Sysinternals\enable-tamper-protection.ps1"
Remove-Item "C:\Program Files\Sysinternals\watchdog-service.ps1"
Remove-Item "C:\Program Files\Sysinternals\enforce-tamper-protection.ps1"
Remove-Item "C:\Program Files\Sysinternals\tamper-protection-policy.xml"
Restart-Service WazuhSvc
```

> Tamper Protection itself is a separate Intune / GPO policy — remove or disable it through the same channel you used to enable it.
