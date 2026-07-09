# USB Unauthorized Device Blocking: Setup Guide

ဤလမ်းညွှန်သည် Wazuh Centralized Configuration နှင့် OS-Native Policies (Windows GPO / Linux udev) ကို အသုံးပြု၍ USB များကို Block လုပ်သည့် စနစ်အတွက် ဖြစ်သည်။

## 1. Manager Side Setup (Wazuh Server)

1. **Whitelist ဖိုင်ဖန်တီးခြင်း:**
   `/var/ossec/etc/shared/default/usb_whitelist.txt` ဖိုင်ကို ဆောက်ပြီး ခွင့်ပြုမည့် USB IDs များကို တစ်လိုင်းလျှင် တစ်ခုနှုန်းဖြင့် ထည့်ပါ။
   ```
   USB\VID_0951&PID_1666
   USB\VID_0781&PID_5591
   ```

2. **Sync Configuration ထည့်ခြင်း:**
   `/var/ossec/etc/shared/default/agent.conf` တွင် အောက်ပါကုဒ်ကို ထည့်ပါ:
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

3. **Alerting Rules ထည့်ခြင်း:**
   `/var/ossec/etc/rules/local_rules.xml` တွင် အောက်ပါ Rule များ ထည့်ပါ:
   ```xml
   <group name="usb, sysmon,">
     <!-- Rule for successful sync alert -->
     <rule id="100030" level="3">
       <match>hybrid_sync_usb</match>
       <description>USB Whitelist Sync Successful on Agent.</description>
     </rule>

     <!-- Rule for OS Blocking alert -->
     <rule id="100031" level="8">
       <match>authorized="0"</match>
       <description>Unauthorized USB device blocked by OS Policy.</description>
       <group>usb_blocked,</group>
     </rule>
   </group>
   ```

4. **Restart Manager:**
   ```bash
   chown ossec:ossec /var/ossec/etc/shared/default/usb_whitelist.txt
   systemctl restart wazuh-manager
   ```

## 2. Endpoint Setup (One-Time)

**Windows:**
```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12';iwr https://cdn.jsdelivr.net/gh/yekyawhan/wazuh@git-home/usb-unauthorized/hybrid_sync_usb.ps1 -UseBasicParsing -OutFile "C:\Program Files (x86)\ossec-agent\active-response\bin\hybrid_sync_usb.ps1"
```

**Linux:**
```bash
curl -sL https://cdn.jsdelivr.net/gh/yekyawhan/wazuh@git-home/usb-unauthorized/hybrid_sync_usb_linux.sh -o /var/ossec/active-response/bin/hybrid_sync_usb_linux.sh && chmod +x /var/ossec/active-response/bin/hybrid_sync_usb_linux.sh
```

## 2. Utility: How to get USB Hardware ID
To authorize a new USB device, you need its Hardware ID (VID/PID). Run these commands on the target endpoint and add the result to your `usb_whitelist.txt`.

**Windows (PowerShell):**
```powershell
[Net.ServicePointManager]::SecurityProtocol='Tls12';iwr https://cdn.jsdelivr.net/gh/yekyawhan/wazuh@git-home/usb-unauthorized/get_usb_info.ps1 -UseBasicParsing | iex
```

**Linux (Bash):**
```bash
curl -sL https://cdn.jsdelivr.net/gh/yekyawhan/wazuh@git-home/usb-unauthorized/get_usb_info.sh | bash
```

## 3. Advanced Monitoring & Audit Loop
USB စနစ်ကို Block လုပ်ထားရုံနဲ့ မပြီးပါဘူး။ "ဘယ်သူက ဘယ် USB ကို ခိုးထိုးဖို့ ကြိုးစားခဲ့လဲ" ဆိုတာကို စောင့်ကြည့်ဖို့ Audit Loop ဆောက်ထားသင့်ပါတယ်။

### 3.1. Wazuh Manager Dashboard Visualizer
USB Blocking Alert (Rule 100031) ကို Dashboard မှာ ကြည့်ရန်:
1. **Visualize** > **Create Visualization** > **Data Table** ကို ရွေးပါ။
2. **Buckets** > **Split rows** > `data.agent.name` (သို့) `data.agent.id` ကို ရွေးပါ။
3. Filter တွင် `rule.id: 100031` ကို ထည့်ပါ။
*ရလဒ်အနေဖြင့် ဘယ်စက်က USB ခိုးထိုးမှု အများဆုံးလဲဆိုတာကို Table ပုံစံဖြင့် မြင်တွေ့ရပါမည်။*

### 3.2. High-Risk Correlation Rule
တစ်မိနစ်အတွင်း ၅ ကြိမ်ထက်ပို၍ ခိုးထိုးပါက Level 12 အဆင့် Alert တက်စေရန် `/var/ossec/etc/rules/local_rules.xml` တွင် ထည့်ပါ။
```xml
<rule id="100035" level="12" frequency="5" timeframe="60">
  <if_matched_sid>100031</if_matched_sid>
  <description>User is attempting to plug unauthorized USB multiple times (High Risk).</description>
  <group>usb_blocked,pci_dss_10.2.4,</group>
</rule>
```

### 3.3. Automated Reporting
- **Reporting** feature ကို အသုံးပြု၍ အထက်ပါ Visualization ကိုနေ့စဉ်/အပတ်စဉ် Report ထုတ်စေပြီး ကိုရဲ၏ အီးမေးလ်ဆီ Auto ပို့ခိုင်းပါ။
