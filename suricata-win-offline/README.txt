SURICATA IPS (WinDivert) - PROJECT PACKAGE
==========================================
Packaged 17/Jul/2026   Cybersecurity Department   CSD_GL_03612_01

Inline-blocking Suricata built from source with WinDivert, plus the rule
distribution chain that keeps it fed from the Wazuh manager.

The official Suricata Windows MSI is IDS-only: Npcap is a passive capture
driver and can never block. Real inline blocking requires compiling Suricata
from source with WinDivert enabled - that is what build-suricata-ips.ps1 does.


CONTENTS
--------
docs/
  20260717_CSD_SuricataIPSBuildAndRuleDistributionV01.docx
      Full step-by-step document: architecture, build, rule sync,
      ET Open updates, verification, troubleshooting.

scripts/
  build-suricata-ips.ps1          Compiles Suricata + WinDivert from source and
                                  deploys to C:\SuricataIPS. Also generates the
                                  ET refresh script and registers its task.
  sync-ips-rules.ps1              Propagates manager rule edits into
                                  C:\SuricataIPS\rules. Validated, auto-rollback,
                                  restarts only when content changed.
  install-ips-sync-task.ps1       Registers sync-ips-rules.ps1 as a SYSTEM
                                  scheduled task (every 5 minutes).
  refresh-suricata-ips-rules.ps1  ET Open refresh (every 3 h). NOTE: this is a
                                  GENERATED artifact - build-suricata-ips.ps1
                                  writes it from an embedded template. Edit the
                                  template in the build script, not this file,
                                  or a rebuild will overwrite your changes.
  uninstall-all-suricata.ps1      Removes the IDS and IPS deployments.
  agb-full-uninstall.ps1          IDS-only cleanup (called by the above).
  agb-full-setup.ps1              Standard IDS-mode deployment (MSI, alert-only).
  deploy-agb-rules.ps1            IDS rule deploy. NOT for the IPS build - it
                                  targets C:\ProgramData\Suricata\rules and the
                                  "Suricata" service, pulling from GitHub.
  install-suricata-ips-service.ps1  Service install/remove helper.
  Test-SuricataIPS-Rules.ps1      Rule test harness.
  Test-SuricataAlerts.ps1         Alert test harness.
  fix-eve-stats-overflow.ps1      eve.json stats overflow fix.

rules/
  agb-white.rules        pass  - suppress known-good (sid 1000010+)
  agb-black.rules        alert on the manager; converted to drop on the engine
                               (sid 1000100+)
  agb-heuristics.rules   alert - DGA / exfil / JA3 heuristics


QUICK START
-----------
1. Copy scripts/ and rules/ to the Wazuh manager:
     /var/ossec/etc/shared/<group>/suricata-win-offline/

   IMPORTANT: convert to LF first. The Wazuh Windows agent writes shared files
   in text mode (LF -> CRLF), so a Windows-edited CRLF file comes back as
   CR CR LF and grows by one byte per line on every push:
     sed -i 's/\r$//' *.ps1 rules/*.rules

   Keep them wazuh-owned:
     install -o wazuh -g wazuh -m 644 <file> /var/ossec/etc/shared/<group>/...

2. On the agent, from an ELEVATED PowerShell:
     cd "C:\Program Files (x86)\ossec-agent\shared\suricata-win-offline"
     .\build-suricata-ips.ps1

   Run it from THAT folder: it is what enables the -LocalRulesRepo auto-detect,
   so rules come from your manager rather than GitHub. Confirm this line:
     [ips-build] LocalRulesRepo auto-detected from script location: ...

   With Tamper Protection ON the build will pause and ask you to add
   C:\msys64 and C:\SuricataIPS as Defender folder exclusions by hand.
   Add them - without them cargo.exe is quarantined mid-build.

3. Register the sync task (elevated):
     .\install-ips-sync-task.ps1


OPERATING NOTES
---------------
* Edit rules ON THE MANAGER only. The agent shared folder is manager-controlled;
  local edits there are overwritten on the next merged.mg push.
* Propagation: manager -> agent shared ~60 s, -> live engine <=5 min.
* suricata -T on Windows ALWAYS exits 1: ET Open ships 9 signatures using the
  file.magic keyword and this build has no libmagic. Those rules are skipped at
  runtime while all others load. Never gate automation on the exit code alone -
  filter for E: lines that are neither file.magic nor "Loading signatures failed".
* "Loading signatures failed" is misleading: Suricata prints it whenever ANY rule
  fails to parse, while still loading every other rule. Check
  "rules successfully loaded" instead.
* Only agb-black-drop.rules and agb-tor-drop.rules block. ET Open is alert-only
  by design.
* The ET refresh currently has no change detection: it re-downloads and restarts
  the engine every 3 h even when nothing changed (8 restarts/day, each a brief
  fail-open gap). Adding a hash comparison, as sync-ips-rules.ps1 already does,
  is recommended.


LOGS
----
  C:\SuricataIPS\log\suricata.log                    engine
  C:\SuricataIPS\log\eve.json                        alerts (bound into Wazuh)
  C:\SuricataIPS\log\sync-ips-rules.log              sync task
  C:\msys64\suricata-ips-build\ips-scripts\refresh.log   ET refresh
  C:\msys64\suricata-ips-build\rules-backup\            pre-swap backups
