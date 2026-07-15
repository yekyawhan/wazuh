# ==========================================================
# Wazuh Share Sync Service
# Version: 2.0 (real-time)
#
# Function:
#   Sync Manager shared files to Active Response bin
#
# Files:
#   *.ps1
#   *.cmd
#   *.exe
#
# Features:
#   - REAL-TIME via FileSystemWatcher (no fixed poll interval)
#   - SHA256 integrity check
#   - Auto overwrite local modification
#   - Remote command enable
#   - Wazuh service restart only when required
#   - Safety-net resync catches missed events
#   - Logging
#
# ==========================================================

# Safety-net resync interval (seconds). Watcher drives sync; this only
# catches events lost to buffer overflow or while the script was down.
$SafetyInterval = 300


$Source = "C:\Program Files (x86)\ossec-agent\shared"

$Destination = `
"C:\Program Files (x86)\ossec-agent\active-response\bin"


$AgentDir = `
"C:\Program Files (x86)\ossec-agent"


$InternalOption = `
"$AgentDir\local_internal_options.conf"


$LogFile = `
"C:\Program Files (x86)\ossec-agent\active-response\share-sync.log"



$Extensions = @(
    "*.ps1",
    "*.cmd",
    "*.exe"
)

# FileSystemWatcher on the shared directory
$global:Watcher = New-Object System.IO.FileSystemWatcher
$global:Watcher.Path = $Source
$global:Watcher.IncludeSubdirectories = $false
$global:Watcher.EnableRaisingEvents = $true
# Filter for our extensions — watcher only supports one pattern; use broad filter then gate in handler
$global:Watcher.Filter = "*.*"

$global:SyncLock = [System.Object]::new()

function global:Invoke-Sync {
    param()
    [System.Threading.Monitor]::Enter($global:SyncLock)
    try {
        Write-Log "===== Sync Start (event) ====="
        Sync-Files
        Enable-RemoteCommands
        Write-Log "===== Sync Complete (event) ====="
    }
    finally {
        [System.Threading.Monitor]::Exit($global:SyncLock)
    }
}

# Debounce: collapse rapid bursts (e.g., multiple files dropped at once) into one sync
$global:DebounceTimer = $null
function global:Request-Sync {
    if ($global:DebounceTimer) { $global:DebounceTimer.Dispose() }
    $global:DebounceTimer = New-Object System.Timers.Timer(2000)
    $global:DebounceTimer.AutoReset = $false
    $global:DebounceTimer.Elapsed.Add({ Invoke-Sync })
    $global:DebounceTimer.Start()
}

Register-ObjectEvent -InputObject $global:Watcher -EventName Changed -Action { Request-Sync } | Out-Null
Register-ObjectEvent -InputObject $global:Watcher -EventName Created -Action { Request-Sync } | Out-Null
Register-ObjectEvent -InputObject $global:Watcher -EventName Renamed -Action { Request-Sync } | Out-Null
Register-ObjectEvent -InputObject $global:Watcher -EventName Deleted -Action { Request-Sync } | Out-Null

# Initial full sync at startup
Invoke-Sync



function Write-Log {

    param(
        [string]$Message
    )

    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    Add-Content `
        -Path $LogFile `
        -Value "$time  $Message"
}



function Enable-RemoteCommands {


    if (!(Test-Path $InternalOption)) {

        New-Item `
        -ItemType File `
        -Path $InternalOption `
        -Force | Out-Null
    }


    $changed = $false


    $Settings = @(

        @{
            Name="wazuh_command.remote_commands"
            Pattern="^\s*wazuh_command\.remote_commands\s*=\s*1"
        },


        @{
            Name="logcollector.remote_commands"
            Pattern="^\s*logcollector\.remote_commands\s*=\s*1"
        }

    )



    foreach($item in $Settings){


        if(
        !(Select-String `
        -Path $InternalOption `
        -Pattern $item.Pattern `
        -Quiet)
        ){


            Add-Content `
            -Path $InternalOption `
            -Value "$($item.Name)=1" `
            -Encoding ascii


            Write-Log `
            "Enabled $($item.Name)=1"


            $changed=$true
        }

    }



    if($changed){


        try{


            Restart-Service `
            WazuhSvc `
            -Force


            Write-Log `
            "WazuhSvc restarted"



        }
        catch{


            Write-Log `
            "ERROR restarting WazuhSvc : $_"

        }

    }

}



function Sync-Files {


    if(!(Test-Path $Destination)){


        New-Item `
        -ItemType Directory `
        -Path $Destination `
        -Force | Out-Null

    }



    foreach($ext in $Extensions){


        Get-ChildItem `
        $Source `
        -Filter $ext `
        -File `
        -ErrorAction SilentlyContinue | ForEach-Object {



            $sourceFile=$_.FullName


            $destFile=
            Join-Path `
            $Destination `
            $_.Name



            $copy=$false



            if(!(Test-Path $destFile)){


                $copy=$true

            }

            else{


                $sourceHash =
                (Get-FileHash `
                $sourceFile `
                -Algorithm SHA256).Hash



                $destHash =
                (Get-FileHash `
                $destFile `
                -Algorithm SHA256).Hash



                if($sourceHash -ne $destHash){


                    $copy=$true

                }

            }



            if($copy){


                Copy-Item `
                $sourceFile `
                $destFile `
                -Force



                Write-Log `
                "SYNCED : $($_.Name)"

            }


        }


    }


}



# ==========================
# MAIN LOOP (safety-net resync only)
# ==========================
# FileSystemWatcher drives real-time sync above; this loop is a
# fallback for events the watcher missed (buffer overflow, downtime).
while ($true) {
    Start-Sleep -Seconds $SafetyInterval
    Invoke-Sync
}
