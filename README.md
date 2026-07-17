# Wazuh Lab Toolkit

A modular **Wazuh / SIEM / EDR / SOAR lab repository** for deploying and testing security monitoring components across **Windows** and **Linux** environments.

This repository contains scripts, automation, and lab resources for:

* **Wazuh agent deployment**
* **Windows Sysmon integration**
* **Suricata integration**
* **Active Response automation**
* **Docker-based Wazuh lab setup**

It is designed for **SOC labs, blue team testing, detection engineering, incident response automation, and security monitoring experiments**.

---

## Repository Overview

This repository is organized into separate modules so each part of the Wazuh monitoring stack can be managed independently.

```text
wazuh/
├── active-response/
│   └── pstools/
├── docker/
├── suricata-linux/
├── suricata-win/
├── suricata-win-offline/
├── sysmon/
├── wz-agent-linux/
└── wz-agent-windows/
```

---

## Folder Overview

| Folder                    | Purpose                                                                                                                                              | Platform             |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------- |
| `active-response/pstools` | Custom **Wazuh Active Response** scripts and utilities for automated response actions such as process suspension, blocking, or remediation workflows | Windows / Wazuh      |
| `docker`                  | Docker-based files and lab resources for building a **Wazuh test environment** quickly                                                               | Lab / Infrastructure |
| `suricata-linux`          | Scripts and configuration for deploying **Suricata on Linux** and forwarding alerts into Wazuh                                                       | Linux                |
| `suricata-win`            | Windows-focused **Suricata integration / testing** resources for Wazuh environments                                                                  | Windows              |
| `suricata-win-offline`    | **Offline Suricata IPS build + rule distribution** — compiles Suricata with WinDivert for inline blocking, syncs rules from Wazuh manager            | Windows              |
| `sysmon`                  | PowerShell automation for installing and configuring **Microsoft Sysmon** on Windows endpoints for richer telemetry in Wazuh                         | Windows              |
| `wz-agent-linux`          | Wazuh agent installation and setup resources for **Linux endpoints**                                                                                 | Linux                |
| `wz-agent-windows`        | Wazuh agent installation and setup resources for **Windows endpoints**                                                                               | Windows              |

---

# What This Repository Is For

This repository is intended to help build a practical **Wazuh monitoring lab** that covers both **host-based** and **network-based** visibility.

Typical use cases include:

* Deploying **Wazuh agents** to Windows and Linux endpoints
* Installing **Sysmon** to collect rich Windows telemetry
* Integrating **Suricata** alerts into Wazuh
* Building **custom active response** workflows
* Testing **detection engineering** and SOC automation use cases
* Creating a repeatable **Wazuh lab environment** for research or training

---

# Modules

## `active-response/pstools`

Custom scripts and supporting tools for **Wazuh Active Response** workflows.

This area is useful when you want Wazuh to take action automatically after an alert is triggered, for example:

* suspend or terminate suspicious processes
* launch PowerShell-based remediation
* trigger popup warnings to the endpoint user
* log automated response actions
* experiment with containment workflows in a lab

This folder is especially useful for **Windows endpoint response automation**.

---

## `docker`

Contains resources for building a **containerized Wazuh lab**.

This module is useful for:

* quickly deploying a Wazuh test environment
* standing up a temporary SIEM lab
* testing Wazuh rules, agent connectivity, and integrations
* creating a repeatable local lab for experiments

Typical content may include:

* Docker Compose files
* Wazuh stack deployment examples
* containerized lab helpers
* test environment setup notes

---

## `suricata-linux`

Linux-side **Suricata deployment and integration** for Wazuh.

This module is intended for environments where you want to collect **network intrusion detection** telemetry from Linux systems and centralize it in Wazuh.

Typical use cases:

* install Suricata on Linux hosts
* configure Eve JSON / alert output
* forward Suricata logs to Wazuh
* build network detection use cases
* test Linux-based IDS scenarios in a Wazuh lab

---

## `suricata-win`

Windows-focused Suricata integration resources.

This folder is useful for:

* experimenting with Suricata on Windows hosts
* forwarding Suricata alerts into Wazuh
* testing hybrid **host + network monitoring** on Windows
* evaluating Suricata behavior in Windows lab environments

---

## `suricata-win-offline`

**Offline Suricata IPS (WinDivert) build + rule distribution chain** for Windows endpoints managed by Wazuh.

Unlike the MSI-based IDS deployment in `suricata-win`, this module builds **inline-blocking Suricata from source** — Npcap is passive and can never block, so real IPS on Windows requires WinDivert.

What's inside:

* `build-suricata-ips.ps1` — compiles Suricata + WinDivert under MSYS2, deploys to `C:\SuricataIPS`, generates the ET refresh script, registers the rule-sync task
* `sync-ips-rules.ps1` — manager → engine rule propagation (validated, auto-rollback, restart only on content change)
* `install-ips-sync-task.ps1` — registers sync as a SYSTEM scheduled task (every 5 min)
* `refresh-suricata-ips-rules.ps1` — ET Open refresh (every 3 h)
* `rules/` — AGB whitelist / blacklist / heuristics (sid 1000010+, 1000100+)
* `README.txt` — full build doc, operating notes, log paths

### Offline Install Method

The whole module is designed to run from the Wazuh shared folder on the agent — **no internet needed on the agent after the manager stage**.

**Manager side (once):**

```bash
# Convert to LF — Windows agent text-mode writes add CR CR LF otherwise
sed -i 's/\r$//' /var/ossec/etc/shared/<group>/suricata-win-offline/scripts/*.ps1 \
                   /var/ossec/etc/shared/<group>/suricata-win-offline/rules/*.rules

# Fix ownership
install -o wazuh -g wazuh -m 644 \
  /var/ossec/etc/shared/<group>/suricata-win-offline/{scripts/*.ps1,rules/*.rules,README.txt}
```

**Agent side (elevated PowerShell):**

```powershell
cd "C:\Program Files (x86)\ossec-agent\shared\suricata-win-offline\scripts"
.\build-suricata-ips.ps1
.\install-ips-sync-task.ps1
```

Run `build-suricata-ips.ps1` **from that exact folder** — it enables the `-LocalRulesRepo` auto-detect so rules come from your manager rather than GitHub. Confirm this line in the output:

```
[ips-build] LocalRulesRepo auto-detected from script location: ...
```

> **Tamper Protection:** with Defender Tamper Protection ON, add `C:\msys64` and `C:\SuricataIPS` as Defender folder exclusions by hand before the build — otherwise `cargo.exe` gets quarantined mid-build.

See `suricata-win-offline/README.txt` for the full architecture, log paths, troubleshooting, and the inline-blocking design notes.

---

## `sysmon`

Automation and deployment resources for **Microsoft Sysmon**.

Sysmon extends Windows logging and is commonly used with Wazuh to improve endpoint visibility. This module is intended for installing, configuring, and validating Sysmon on Windows endpoints.

Typical telemetry collected with Sysmon includes:

* process creation
* network connections
* image loads
* registry modifications
* file creation events
* persistence-related activity

This module is useful for **Windows detection engineering**, **threat hunting**, and **Wazuh endpoint telemetry enrichment**.

---

## `wz-agent-linux`

Linux Wazuh agent deployment resources.

This module is intended to simplify:

* Wazuh agent installation on Linux hosts
* agent registration / manager connectivity
* Linux endpoint onboarding into a Wazuh lab
* log collection and monitoring validation

---

## `wz-agent-windows`

Windows Wazuh agent deployment resources.

This module helps standardize:

* Wazuh agent installation on Windows hosts
* endpoint registration to the Wazuh manager
* Windows event collection preparation
* onboarding endpoints before adding Sysmon or active response workflows

---

# Example Monitoring Workflows

## Windows Endpoint Workflow

A typical Windows deployment with this repository might look like:

1. Install the **Wazuh Windows agent** from `wz-agent-windows`
2. Install **Sysmon** from `sysmon`
3. Configure Windows event collection for Sysmon logs
4. Add **Active Response** scripts from `active-response/pstools`
5. Tune Wazuh rules and alerts for Windows telemetry

This gives you:

* Windows endpoint visibility
* Sysmon process and network telemetry
* centralized alerting in Wazuh
* automated response actions for suspicious activity

---

## Linux Endpoint Workflow

A typical Linux deployment might look like:

1. Install the **Wazuh Linux agent** from `wz-agent-linux`
2. Deploy **Suricata** from `suricata-linux`
3. Forward Suricata alerts into Wazuh
4. Tune rules for host and network detections

This gives you:

* Linux host monitoring
* network IDS visibility
* centralized event correlation in Wazuh

---

## Full Lab Workflow

If you want to build a complete Wazuh lab:

1. Deploy the Wazuh stack using `docker`
2. Add Linux endpoints with `wz-agent-linux`
3. Add Windows endpoints with `wz-agent-windows`
4. Enable Sysmon with `sysmon`
5. Add Suricata from `suricata-linux` or `suricata-win`
6. Configure automated response scripts from `active-response/pstools`

This creates a practical environment for:

* SOC testing
* detection engineering
* incident response automation
* alert tuning
* endpoint + network monitoring experiments

---

# Suggested Start Order

## If you are building a Windows monitoring lab

Start with:

1. `wz-agent-windows`
2. `sysmon`
3. `active-response/pstools`

## If you are building a Linux monitoring lab

Start with:

1. `wz-agent-linux`
2. `suricata-linux`

## If you are building a full Wazuh lab

Start with:

1. `docker`
2. `wz-agent-linux`
3. `wz-agent-windows`
4. `sysmon`
5. `suricata-linux` / `suricata-win`
6. `active-response/pstools`

---

# Recommended Repository Improvements

To make this repository easier to use and maintain, consider adding a dedicated `README.md` inside each module:

* `active-response/pstools/README.md`
* `docker/README.md`
* `suricata-linux/README.md`
* `suricata-win/README.md`
* `suricata-win-offline/README.md`
* `sysmon/README.md`
* `wz-agent-linux/README.md`
* `wz-agent-windows/README.md`

Recommended additions for each module:

* prerequisites
* install steps
* usage examples
* screenshots
* troubleshooting notes
* Wazuh configuration examples
* sample alerts / expected outputs

---

# Who This Repository Is For

This repository is useful for:

* SOC analysts
* blue team engineers
* Wazuh administrators
* detection engineers
* security lab builders
* students learning SIEM / EDR / SOAR workflows

---

# Notes

This project is structured as a **modular Wazuh lab toolkit** rather than a single-purpose script repository. Each folder focuses on one area of the monitoring stack, and together they support a practical workflow for:

* Windows endpoint monitoring
* Linux endpoint monitoring
* Sysmon telemetry collection
* Suricata network visibility
* Wazuh Active Response automation

---

# Author

Maintained by **yekyawhan**.
