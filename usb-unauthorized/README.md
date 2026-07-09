# USB Unauthorized Device Monitoring and Blocking (Hybrid Approach: Wazuh Centralized + OS-Native)

This project provides an enterprise-grade USB blocking solution. It uses **Wazuh Centralized Configuration** to distribute a whitelist of allowed USBs, and **OS-Native Policies (Windows GPO / Linux udev)** to enforce the block even when endpoints are offline. Wazuh is used for configuration sync and alerting.

Windows နှင့် Linux စက်များတွင် ခွင့်ပြုချက်မရှိသော USB များကို Native OS Policy (GPO / udev) များဖြင့် ပိတ်ပင်ပြီး (Offline အလုပ်လုပ်ရန်)၊ Manager ဘက်မှနေ၍ USB Whitelist ဖိုင်ကို တစ်နေရာတည်းမှ ထိန်းချုပ်ဖြန့်ဝေနိုင်သော (Centralized) စနစ်ဖြစ်ပါသည်။ 

![Architecture Flow](assets/flow.svg)

---

## 📦 Architecture

-   **Centralized Control (Manager):** Maintain one `usb_whitelist.txt` file on the Wazuh Manager.
-   **Distribution (Wazuh Sync):** Wazuh automatically pushes this file to all agents.
-   **Enforcement Layer (OS):** Agent-side script periodically reads the synced file and applies it to Local GPO (Windows) or `udev` (Linux). USBs are blocked at the OS level (100% Offline Capable).
-   **Alerting Layer:** Wazuh Agent monitors OS event logs and alerts the Manager when a block occurs.

---

## 🚀 Setup Guide / တပ်ဆင်ရန် လမ်းညွှန်

### 1. Wazuh Manager Setup (Central Control)
Run these on your Wazuh Manager:

1. Create the whitelist file:
   ```bash
   nano /var/ossec/etc/shared/default/usb_whitelist.txt
   ```
   *Add your allowed USB IDs (one per line). The script supports both Windows format (`USB\VID_0951&PID_1666`) and Linux format (`0951:1666`).*

2. Configure Agents to sync it via `agent.conf`:
   ```bash
   nano /var/ossec/etc/shared/default/agent.conf
   ```
   *Add the following block:*
   ```xml
   <agent_config os="Windows">
     <localfile>
       <log_format>command</log_format>
       <command>powershell -ExecutionPolicy Bypass -File "C:\Program Files (x86)\ossec-agent\active-response\bin\hybrid_sync_usb.ps1"</command>
       <frequency>3600</frequency>
     </localfile>
   </agent_config>

   <agent_config os="Linux">
     <localfile>
       <log_format>command</log_format>
       <command>/var/ossec/active-response/bin/hybrid_sync_usb_linux.sh</command>
       <frequency>3600</frequency>
     </localfile>
   </agent_config>
   ```

3. Configure Alerting Rules:
   Copy `wazuh_rules.xml` content into your `/var/ossec/etc/rules/local_rules.xml`.

4. Fix permissions and restart:
   ```bash
   chown ossec:ossec /var/ossec/etc/shared/default/usb_whitelist.txt
   systemctl restart wazuh-manager
   ```

### 2. Windows Endpoint Setup
Run this **ONCE** on the Windows endpoint to place the sync script.

**CDN version (recommended):**
```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12';iwr https://cdn.jsdelivr.net/gh/yekyawhan/wazuh@git-home/usb-unauthorized/hybrid_sync_usb.ps1 -UseBasicParsing -OutFile "C:\Program Files (x86)\ossec-agent\active-response\bin\hybrid_sync_usb.ps1"
```

**GitHub raw version:**
```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12';iwr https://raw.githubusercontent.com/yekyawhan/wazuh/git-home/usb-unauthorized/hybrid_sync_usb.ps1 -UseBasicParsing -OutFile "C:\Program Files (x86)\ossec-agent\active-response\bin\hybrid_sync_usb.ps1"
```

### 3. Linux Endpoint Setup
Run this **ONCE** on the Linux endpoint as root to place the sync script.

**CDN version (recommended):**
```bash
curl -sL https://cdn.jsdelivr.net/gh/yekyawhan/wazuh@git-home/usb-unauthorized/hybrid_sync_usb_linux.sh -o /var/ossec/active-response/bin/hybrid_sync_usb_linux.sh && chmod +x /var/ossec/active-response/bin/hybrid_sync_usb_linux.sh
```

**GitHub raw version:**
```bash
curl -sL https://raw.githubusercontent.com/yekyawhan/wazuh/git-home/usb-unauthorized/hybrid_sync_usb_linux.sh -o /var/ossec/active-response/bin/hybrid_sync_usb_linux.sh && chmod +x /var/ossec/active-response/bin/hybrid_sync_usb_linux.sh
```

---

## 📋 Files / ဖိုင်များ

| File | Description / ရှင်းလင်းချက် |
| --- | --- |
| `usb_whitelist.txt` | Manager ဘက်တွင် ထားရမည့် ခွင့်ပြုထားသော USB ID စာရင်း (Centralized Control) |
| `agent.conf.snippet` | Manager မှ Agent များဆီ sync လုပ်ခိုင်းမည့် Configuration |
| `hybrid_sync_usb.ps1` | Windows Agent မှ Manager ပို့ပေးသော whitelist ကို ဖတ်၍ GPO ကို Auto Update လုပ်ပေးမည့် Script |
| `hybrid_sync_usb_linux.sh` | Linux Agent မှ Manager ပို့ပေးသော whitelist ကို ဖတ်၍ `udev` rules ကို Auto Update လုပ်ပေးမည့် Script |
| `wazuh_rules.xml` | OS မှ USB ပိတ်လိုက်သောအခါ Wazuh Manager မှ Alert ထုတ်ပေးမည့် rules |
| `assets/flow.svg` | Architecture diagram |
