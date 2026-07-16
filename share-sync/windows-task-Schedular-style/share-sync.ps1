# ===============================================
# Wazuh Share Sync
# One Shot Sync
# Task Scheduler runs every 1 minute
# ===============================================


$Source = "C:\Program Files (x86)\ossec-agent\shared"

$Destination = "C:\Program Files (x86)\ossec-agent\active-response\bin"

$LogFile = "C:\Program Files (x86)\ossec-agent\active-response\share-sync.log"


$Extensions = @(
    "*.ps1",
    "*.cmd",
    "*.exe"
)



function Write-Log {

    param(
        [string]$Message
    )

    $Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    Add-Content `
        -Path $LogFile `
        -Value "$Time $Message"
}



foreach($Ext in $Extensions)
{

    Get-ChildItem `
        -Path $Source `
        -Filter $Ext `
        -File `
        -ErrorAction SilentlyContinue | ForEach-Object {


        $SourceFile = $_.FullName

        $DestinationFile = Join-Path `
            $Destination `
            $_.Name



        $NeedCopy = $false



        if(!(Test-Path $DestinationFile))
        {

            $NeedCopy = $true

        }
        else
        {

            try {

                $SourceHash = (
                    Get-FileHash `
                    -Path $SourceFile `
                    -Algorithm SHA256
                ).Hash


                $DestinationHash = (
                    Get-FileHash `
                    -Path $DestinationFile `
                    -Algorithm SHA256
                ).Hash


                if($SourceHash -ne $DestinationHash)
                {
                    $NeedCopy = $true
                }

            }
            catch {

                Write-Log `
                "HASH ERROR : $($_.Name) - $($_.Exception.Message)"

            }

        }



        if($NeedCopy)
        {

            try
            {

                Copy-Item `
                    -Path $SourceFile `
                    -Destination $DestinationFile `
                    -Force `
                    -ErrorAction Stop


                Write-Log `
                "SYNC : $($_.Name)"


            }
            catch
            {

                Write-Log `
                "ERROR : $($_.Name) - $($_.Exception.Message)"

            }

        }


    }

}
