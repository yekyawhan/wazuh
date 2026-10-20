# enable-tamper-protection.ps1
# Layer-0 helper: turn Microsoft Defender Tamper Protection ON locally.
#
# Shared by:
#   reenable-defender.ps1        (Wazuh AR + event/service watchers)
#   enforce-tamper-protection.ps1 (manual audit script)
#
# State value: HKLM\SOFTWARE\Microsoft\Windows Defender\Features\TamperProtection
#   DWORD 5 = ON   (4 / 0 = OFF)
#
# Why the ACL dance is needed: while TP is OFF the Features key is owned by
# SYSTEM with an ACL that denies even elevated admins. Writing 5 therefore
# requires taking ownership first, then granting Administrators FullControl.
# Each step reopens the key: taking ownership does NOT grant WRITE_DAC, so a
# fresh handle is required before SetAccessControl works.
#
# Self-limiting by design: once TP is ON, Defender re-protects the key itself
# and later writes are blocked by the WdFilter minifilter (Event 5013).
#
# Fails cleanly (logged, no side effect) when TP is centrally managed by
# Intune / MDM / GPO policy. When the write succeeds but IsTamperProtected is
# still False, the change is pending a Defender platform refresh or a reboot.
#
# Run elevated. Dot-source to reuse:
#   . (Join-Path $PSScriptRoot 'enable-tamper-protection.ps1')
#   Enable-TamperProtectionBestEffort

function Enable-TamperProtectionBestEffort {
    $tpKey  = 'SOFTWARE\Microsoft\Windows Defender\Features'
    $admins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $system = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $LM     = [Microsoft.Win32.Registry]::LocalMachine

    # 1. Take ownership. Needs SeTakeOwnershipPrivilege (LocalSystem/admin hold it).
    try {
        $k = $LM.OpenSubKey($tpKey,
                [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        $acl = $k.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Owner)
        $acl.SetOwner($admins)
        $k.SetAccessControl($acl)
        $k.Close()
        Write-Log 'TAMPER: took ownership of the Features key.'
    } catch {
        Write-Log "TAMPER: ownership step failed: $($_.Exception.Message)"
        return $false
    }

    # 2. Grant Administrators FullControl (reopen - see note above).
    try {
        $k = $LM.OpenSubKey($tpKey,
                [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                [System.Security.AccessControl.RegistryRights]::ChangePermissions)
        $acl  = $k.GetAccessControl()
        $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
                    $admins,
                    [System.Security.AccessControl.RegistryRights]::FullControl,
                    [System.Security.AccessControl.InheritanceFlags]::ContainerInherit,
                    [System.Security.AccessControl.PropagationFlags]::None,
                    [System.Security.AccessControl.AccessControlType]::Allow)
        $acl.SetAccessRule($rule)
        $k.SetAccessControl($acl)
        $k.Close()
        Write-Log 'TAMPER: granted Administrators FullControl on the Features key.'
    } catch {
        Write-Log "TAMPER: ACL grant failed: $($_.Exception.Message)"
        return $false
    }

    # 3. Write the enable value.
    try {
        $k = $LM.OpenSubKey($tpKey, $true)
        $k.SetValue('TamperProtection', 5, [Microsoft.Win32.RegistryValueKind]::DWord)
        $k.Close()
        Write-Log 'TAMPER: wrote TamperProtection=5 (enable requested).'
    } catch {
        Write-Log "TAMPER: value write failed (policy-managed?): $($_.Exception.Message)"
        return $false
    }

    # 4. Hand ownership back to SYSTEM. TP re-protects the key once it is on.
    try {
        $k = $LM.OpenSubKey($tpKey,
                [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
                [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        $acl = $k.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Owner)
        $acl.SetOwner($system)
        $k.SetAccessControl($acl)
        $k.Close()
        Write-Log 'TAMPER: ownership returned to SYSTEM.'
    } catch {
        Write-Log 'TAMPER: could not restore SYSTEM ownership (non-fatal).'
    }

    return $true
}
