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

👉 **[Detailed Implementation Guide](assets/guide.md)**
(Manager စက် နှင့် Endpoint စက်များတွင် အသေးစိတ် သွင်းရမည့် လမ်းညွှန်ချက်)

---

## 📋 Files / ဖိုင်များ

| File | Description / ရှင်းလင်းချက် |
| --- | --- |
| `usb_whitelist.txt` | Manager ဘက်တွင် ထားရမည့် ခွင့်ပြုထားသော USB ID စာရင်း (Centralized Control) |
| `agent.conf.snippet` | Manager မှ Agent များဆီ sync လုပ်ခိုင်းမည့် Configuration |
| `hybrid_sync_usb.ps1` | Windows Agent မှ Manager ပို့ပေးသော whitelist ကို ဖတ်၍ GPO ကို Auto Update လုပ်ပေးမည့် Script |
| `hybrid_sync_usb_linux.sh` | Linux Agent မှ Manager ပို့ပေးသော whitelist ကို ဖတ်၍ `udev` rules ကို Auto Update လုပ်ပေးမည့် Script |
| `assets/guide.md` | အသေးစိတ် တပ်ဆင်ရန် လမ်းညွှန်ချက် |
| `assets/flow.svg` | Architecture diagram |
