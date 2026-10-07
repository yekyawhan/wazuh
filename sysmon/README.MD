# 🔧 Windows Sysmon Automated Installer (PowerShell)

---

## ⚡ One-Line Install Normal sysmon (IMPORTANT)
```
irm "https://raw.githubusercontent.com/yekyawhan/wazuh/refs/heads/git-home/sysmon/install-sysmon.ps1" | iex
```
## ⚡ One-Line Install custom sysmon (IMPORTANT)
```
irm "https://github.com/yekyawhan/wazuh/raw/refs/heads/git-home/sysmon/install-sysmon-custom.ps1" | iex
```



## ⚡ One-Line Clean Uninstall

Run this from an **elevated PowerShell** session. It removes the Sysmon service/driver using Sysmon's own uninstall mechanism, then removes the known Sysmon installation files. It does **not** remove the Wazuh agent's shared configuration.

```powershell
irm "https://raw.githubusercontent.com/yekyawhan/wazuh/refs/heads/git-home/sysmon/uninstall-sysmon-clean.ps1" | iex
```

### Manual clean uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\uninstall-sysmon-clean.ps1
```

### Verify clean uninstall

```powershell
Get-Service -Name Sysmon64 -ErrorAction SilentlyContinue
Test-Path "C:\Program Files (x86)\Sysmon"
Test-Path "C:\Program Files (x86)\Sysmon64.exe"
```

> **Note:** Run the uninstall only on endpoints where you intentionally want Sysmon removed. The script preserves `C:\Program Files (x86)\ossec-agent\shared\custom-sysmon-tuned.xml` so the Wazuh share-sync deployment source remains intact.

## Manual install လုပ်ချင်ရင်
```
powershell -ExecutionPolicy Bypass -File .\install-sysmon.ps1
```
### Uninstall
```
.\install-sysmon.ps1 -Uninstall
```
## 🔍 Verify Installation
```
Get-Service sysmon*
```
### Check event logs:
```
Get-WinEvent -LogName "Microsoft-Windows-Sysmon/Operational" -MaxEvents 10
```


## 🇲🇲 
ဒီ repository က Microsoft Sysmon ကို PowerShell နဲ့ အလိုအလျောက် install လုပ်ပေးတဲ့ script ဖြစ်ပါတယ်။

SOC / SIEM environment (Wazuh, Graylog, Splunk, TheHive) အတွက် ရည်ရွယ်ထားပါတယ်။

အောက်ပါလုပ်ဆောင်ချက်တွေကို automation လုပ်ပေးပါတယ် —

- Sysmon install
- Configuration setup
- Service check
- Event log verify
- Logging system
- Uninstall process

---

# 📁 Project Structure

```text
windows-sysmon-installer/
│
├── install-sysmon.ps1
├── README.md
├── LICENSE
├── screenshots/
│   └── sysmon-running.png
└── config/
    └── custom-sysmon.xml   (optional future)
