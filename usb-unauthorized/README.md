# USB Unauthorized Device Monitoring and Blocking (OS-Native + Wazuh)

This project provides an offline-capable USB blocking solution using native OS policies (GPO for Windows, `udev` for Linux) while utilizing Wazuh strictly for alerting and auditing.

Windows နှင့် Linux စက်များတွင် ခွင့်ပြုချက်မရှိသော USB များကို Native OS Policy (GPO / udev) များဖြင့် ပိတ်ပင်ပြီး Wazuh ကို Alert/Audit အတွက်သာ အသုံးပြုမည့် စနစ်ဖြစ်ပါသည်။

![Architecture Flow](assets/flow.svg)

---

## 📦 Architecture

This approach shifts the blocking mechanism from Wazuh Active Response (which fails if the agent is offline) to OS-level enforcement.

-   **Blocking Layer:** Handled entirely by the Operating System (Registry/GPO on Windows, `udev` on Linux). Works 100% offline.
-   **Alerting Layer:** Wazuh Agent monitors OS event logs. If offline, it queues the logs and sends alerts to the Manager once online.

---

## 🚀 Quick Start / အမြန်စတင်ရန်

> **⚠️ Administrator (Windows) သို့မဟုတ် Root (Linux) လိုအပ်ပါသည်**

### 🪟 Windows (GPO Setup)

**CDN version (recommended / အကြံပြု):**
```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12';iwr https://cdn.jsdelivr.net/gh/yekyawhan/wazuh@master/usb-unauthorized/windows_gpo_setup.ps1 -UseBasicParsing | iex
```

**GitHub raw version:**
```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12';iwr https://raw.githubusercontent.com/yekyawhan/wazuh/master/usb-unauthorized/windows_gpo_setup.ps1 -UseBasicParsing | iex
```

*Note: Default whitelist တွင် `USB\VID_0951&PID_1666` ကို ထည့်သွင်းပေးထားပါသည်။ Script ကို ဒေါင်းလုဒ်ဆွဲပြီး `-Whitelist` parameter ဖြင့် မိမိစိတ်ကြိုက် ပြောင်းလဲအသုံးပြုနိုင်ပါသည်။*

### 🐧 Linux (udev Setup)

**CDN version (recommended / အကြံပြု):**
```bash
curl -sL https://cdn.jsdelivr.net/gh/yekyawhan/wazuh@master/usb-unauthorized/linux_udev_setup.sh | sudo bash
```

**GitHub raw version:**
```bash
curl -sL https://raw.githubusercontent.com/yekyawhan/wazuh/master/usb-unauthorized/linux_udev_setup.sh | sudo bash
```

*Note: Default whitelist တွင် `0951:1666` ကို ထည့်သွင်းပေးထားပါသည်။ Script ကို ဒေါင်းလုဒ်ဆွဲပြီး `-w` parameter ဖြင့် မိမိစိတ်ကြိုက် ပြောင်းလဲအသုံးပြုနိုင်ပါသည်။*

---

## 📋 Files / ဖိုင်များ

| File | Description / ရှင်းလင်းချက် |
| --- | --- |
| `windows_gpo_setup.ps1` | **Windows Script** — Local GPO registry keys များကို ပြင်ဆင်ပြီး USB အားလုံးကို ပိတ်ကာ Whitelist ID များကိုသာ ခွင့်ပြုပေးပါသည်။ |
| `linux_udev_setup.sh` | **Linux Script** — `udev` rules များကို ဖန်တီး၍ USB များကို block လုပ်ပြီး Whitelist ID များကိုသာ ခွင့်ပြုပေးပါသည်။ |
| `wazuh_rules.xml` | **Wazuh Rules** — OS မှ USB ကို ပိတ်လိုက်သောအခါ (Windows Event 219, Linux syslog) Wazuh Manager မှ Alert ထုတ်ပေးမည့် rules ဖြစ်ပါသည်။ |
| `assets/flow.excalidraw` | Architecture diagram file (Excalidraw). |

---

## ⚙️ Wazuh Manager Configuration

1. `wazuh_rules.xml` ဖိုင်ထဲမှ contents များကို Wazuh Manager ၏ `/var/ossec/etc/rules/local_rules.xml` တွင် ကူးထည့်ပါ။
2. Manager ကို Restart ချပါ:
   ```bash
   sudo systemctl restart wazuh-manager
   ```

---

## ✅ Verify / စစ်ဆေးရန်

**Windows တွင် စစ်ဆေးရန်:**
- Event Viewer ကိုဖွင့်ပါ။ `Applications and Services Logs` -> `Microsoft` -> `Windows` -> `Kernel-PnP` -> `Configuration` တွင် စစ်ဆေးပါ။ ခွင့်မပြုထားသော USB ထိုးလျှင် **Event ID 219** တက်ရပါမည်။

**Linux တွင် စစ်ဆေးရန်:**
- Terminal တွင် `dmesg | tail` သို့မဟုတ် `cat /var/log/syslog | grep usb` ရိုက်၍ စစ်ဆေးပါ။ ခွင့်မပြုထားသော USB ထိုးလျှင် `not authorized` ဟု ပေါ်ရပါမည်။
