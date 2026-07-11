# Testing — Windows V2

How to run the Pester test suite on a real Windows agent.

---

## 0. Prerequisites

- Windows 10 (1809+) / 11 / Server 2019 / 2022
- PowerShell 5.1 (built-in) or PowerShell 7.x
- **Administrator** shell (Registry tests write to `HKLM`)
- Wazuh agent installed (so the shared dir exists after Manager push)

Open PowerShell **as Administrator**:

```
Win + X → Windows PowerShell (Admin)   # or Terminal (Admin)
```

---

## 1. Install Pester

Run once. Needs internet (PowerShell Gallery):

```powershell
Install-Module -Name Pester -Force -SkipPublisherCheck -Scope CurrentUser
```

Verify:

```powershell
Get-Module -ListAvailable Pester | Select-Object Name,Version
```

> If `Install-Module` is blocked by execution policy, run first:
> `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass`

---

## 2. Extract the release

If you came from the ZIP:

```powershell
Expand-Archive usb-unauthorized-windows-v2.zip -DestinationPath C:\temp\usbv2
cd C:\temp\usbv2\usb-unauthorized-windows-v2
```

Or from a git checkout:

```powershell
cd C:\path\to\usb-unauthorized\windows
```

---

## 3. Run Parser tests (no admin needed, but run in the admin shell anyway)

```powershell
Invoke-Pester -Path .\tests\Parser.Tests.ps1 -Output Detailed
```

Expected: all green. Covers:
- Windows / Linux / garbage / whitespace format detection
- Linux→Windows ID conversion (padding + uppercase)
- blank + comment skip
- invalid-line flagging
- missing-file handling
- dedupe across formats
- lowercase windows form rejected

---

## 4. Run Registry tests (REQUIRES Administrator)

These write/restore `HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions`.

```powershell
Invoke-Pester -Path .\tests\Registry.Tests.ps1 -Output Detailed
```

Expected: all green. Covers:
- backup captures non-existent state
- backup captures existing values
- `Test-PolicyState` matches / mismatches
- `Set-UsbAllowList` writes + verifies
- `Remove-UsbAllowList` clears the policy

> The suite cleans up after itself (`AfterAll` removes the policy key).
> If a test is interrupted, manually verify cleanup:
> ```powershell
> Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions' -ErrorAction SilentlyContinue
> ```

---

## 5. Optional — run both at once

```powershell
Invoke-Pester -Path .\tests\ -Output Detailed
```

---

## 6. Manual end-to-end smoke test (no Pester)

Good to confirm the real sync path works after code changes.

### a. Create a whitelist

```powershell
$shared = 'C:\Program Files (x86)\ossec-agent\shared'
if (-not (Test-Path $shared)) { New-Item -ItemType Directory -Path $shared -Force }
@(
    '# test whitelist'
    'USB\VID_0951&PID_1666'
    '0951:1666'
) | Set-Content -LiteralPath (Join-Path $shared 'usb_whitelist.txt') -Encoding UTF8
```

### b. Run the sync

```powershell
.\hybrid_sync_usb_v2.ps1
```

### c. Check the registry

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
```

You should see:
- `AllowDeviceIDsEnabled = 1`
- `AllowDeviceIDs` = `USB\VID_0951&PID_1666` (1 entry — the Linux form deduped to the Windows form)

### d. Check the log

```powershell
Get-Content 'C:\ProgramData\Wazuh\Logs\UsbSync\usb-sync.log'
```

### e. Test empty-whitelist = block-all

```powershell
'' | Set-Content -LiteralPath (Join-Path $shared 'usb_whitelist.txt') -Encoding UTF8
.\hybrid_sync_usb_v2.ps1
Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeviceInstall\Restrictions'
```

`AllowDeviceIDsEnabled` stays `1`, `AllowDeviceIDs` is **absent** → Windows blocks all USB.
This is the security-critical behavior fixed in commit `7e7b9df`.

### f. Cleanup

```powershell
Remove-Item 'C:\Program Files (x86)\ossec-agent\shared\usb_whitelist.txt' -Force -ErrorAction SilentlyContinue
.\hybrid_sync_usb_v2.ps1   # re-syncs to block-all (safe default)
```

---

## 7. Common failures

| Symptom | Cause | Fix |
|---------|-------|-----|
| `Registry tests require Administrator` | not elevated | reopen shell as Admin |
| `Module … not found` | ran from wrong dir | `cd` into the `windows/` folder |
| `$UsbSync is null` | (should not happen post-`7e7b9df`) | ensure `config.ps1` is dot-sourced; report if seen |
| Pester old version warnings | Pester 4.x installed | `Install-Module Pester -Force -AllowClobber` |
