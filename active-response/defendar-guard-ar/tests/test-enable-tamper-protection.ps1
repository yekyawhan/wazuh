#!/usr/bin/env pwsh
# Stub-harness for enable-tamper-protection.ps1.
# Substitutes the Windows-only types (registry, SID, access rule) with stubs,
# then exercises the real control flow: happy path, ownership-blocked path,
# and write-blocked path.
$ErrorActionPreference = 'Stop'

$script:state     = @{ TamperProtection = 4 }
$script:owner     = 'NT AUTHORITY\SYSTEM'
$script:failStep  = $null
$script:granted   = $false
$script:opens     = New-Object System.Collections.Generic.List[string]

class FakeSid { [string]$Value = ''; FakeSid([string]$v) { $this.Value = $v } }
class FakeRule { [string]$Who = '' }

class FakeAcl {
    [string]$owner = ''
    [string]$pendingOwner = ''
    [bool]$ruleAdded = $false
    SetOwner([object]$sid) { $this.pendingOwner = $sid.Value }
    SetAccessRule([object]$rule) { $this.ruleAdded = $true }
}

class FakeKey {
    [FakeAcl] GetAccessControl() {
        $a = [FakeAcl]::new(); $a.owner = $script:owner; return $a
    }
    [FakeAcl] GetAccessControl([object]$section) {
        $a = [FakeAcl]::new(); $a.owner = $script:owner; return $a
    }
    SetAccessControl([FakeAcl]$acl) {
        if ($script:failStep -eq 'acl') { throw [System.UnauthorizedAccessException]::new('Access denied (stub)') }
        if ($acl.pendingOwner) { $script:owner = $acl.pendingOwner }
        $script:granted = $true
    }
    SetValue([string]$n, [object]$v, [object]$kind) {
        if ($script:failStep -eq 'write') { throw [System.UnauthorizedAccessException]::new('Access denied (stub)') }
        $script:state[$n] = $v
    }
    Close() { }
}

class FakeLM {
    [FakeKey] OpenSubKey([string]$path, [object]$check, [object]$rights) {
        if ($script:failStep -eq 'owner' -and $rights -eq 1) {
            throw [System.UnauthorizedAccessException]::new('Access denied (stub: no ownership)')
        }
        $script:opens.Add([string]$rights)
        return [FakeKey]::new()
    }
    [FakeKey] OpenSubKey([string]$path, [bool]$writable) {
        if ($writable -and -not $script:granted) {
            throw [System.UnauthorizedAccessException]::new('Access denied (stub: ACL not granted)')
        }
        $script:opens.Add('W')
        return [FakeKey]::new()
    }
}

# ---- build the stubbed source from the REAL file -------------------------
$src = Get-Content -Raw './enable-tamper-protection.ps1'
$q   = [char]39

$src = $src.Replace('[Microsoft.Win32.Registry]::LocalMachine',                    '[FakeLM]::new()')
$src = $src.Replace('[Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree', '0')
$src = $src.Replace('[Microsoft.Win32.RegistryValueKind]::DWord',                   '4')
$src = $src.Replace('[System.Security.AccessControl.RegistryRights]::TakeOwnership',  '1')
$src = $src.Replace('[System.Security.AccessControl.RegistryRights]::ChangePermissions','2')
$src = $src.Replace("New-Object System.Security.Principal.SecurityIdentifier($q" + "S-1-5-32-544$q)", '[FakeSid]::new(' + "'S-1-5-32-544')")
$src = $src.Replace("New-Object System.Security.Principal.SecurityIdentifier($q" + "S-1-5-18$q)",   '[FakeSid]::new(' + "'S-1-5-18')")
$src = [regex]::Replace($src, '(?s)New-Object System\.Security\.AccessControl\.RegistryAccessRule\(.*?\)', '[FakeRule]::new()')
$src = $src.Replace('[System.Security.AccessControl.AccessControlSections]::Owner', '0')

function Write-Log { param($Message) }

. ([System.Management.Automation.ScriptBlock]::Create($src))

# ---- assertions ----------------------------------------------------------
$failures = @()
function Check { param($name,$cond) if ($cond) { "PASS: $name" } else { "FAIL: $name"; $script:failures += $name } }

# Test 1: happy path -- TP OFF, key writable after ACL grant
$script:state.TamperProtection = 4; $script:owner = 'NT AUTHORITY\SYSTEM'; $script:granted = $false; $script:opens.Clear()
$r = Enable-TamperProtectionBestEffort
Check 'happy: returns $true'       ( $r -eq $true )
Check 'happy: value written'       ( $script:state.TamperProtection -eq 5 )
Check 'happy: ownership restored'  ( $script:owner -eq 'S-1-5-18' )
Check 'happy: 4 registry opens'    ( $script:opens.Count -eq 4 )
Check 'happy: rights order'        ( ($script:opens[0] -eq '1') -and ($script:opens[1] -eq '2') -and ($script:opens[2] -eq 'W') -and ($script:opens[3] -eq '1') )

# Test 2: ownership blocked (key ACL denies admin) -- must NOT write, must not continue
$script:state.TamperProtection = 4; $script:owner = 'NT AUTHORITY\SYSTEM'; $script:granted = $false
$script:failStep = 'owner'
$r = Enable-TamperProtectionBestEffort
$script:failStep = $null
Check 'owner-fail: returns $false'  ( $r -eq $false )
Check 'owner-fail: value NOT written' ( $script:state.TamperProtection -eq 4 )

# Test 3: write blocked (policy-managed) -- no crash, clean false
$script:state.TamperProtection = 4; $script:granted = $false
$script:failStep = 'write'
$r = Enable-TamperProtectionBestEffort
$script:failStep = $null
Check 'write-fail: returns $false'  ( $r -eq $false )
Check 'write-fail: value stays OFF' ( $script:state.TamperProtection -eq 4 )

if ($failures.Count) { "FAILED: $($failures.Count) checks"; exit 1 }
'ALL_PASS'
