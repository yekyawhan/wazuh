# ===============================================
# Wazuh Share Sync
# One Shot Sync
# Task Scheduler runs every 1 minute
# ===============================================


$Source = "C:\Program Files (x86)\ossec-agent\shared"

$Destination = `
"C:\Program Files (x86)\ossec-agent\active-response\bin"


$LogFile = `
"C:\Program Files (x86)\ossec-agent\active-response\share-sync.log"



$Extensions = @(
    "*.ps1",
    "*.cmd",
    "*.exe"
)



function Write-Log {

    param($msg)

    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    Add-Content `
    -Path $LogFile `
    -Value "$time $msg"

}



Write-Log "===== Sync Start ====="



foreach($ext in $Extensions){


    Get-ChildItem `
    $Source `
    -Filter $ext `
    -File `
    -ErrorAction SilentlyContinue | ForEach-Object {



        $src = $_.FullName


        $dst = Join-Path `
        $Destination `
        $_.Name



        $copy=$false



        if(!(Test-Path $dst)){

            $copy=$true

        }

        else{


            $srcHash =
            (Get-FileHash `
            $src `
            -Algorithm SHA256).Hash



            $dstHash =
            (Get-FileHash `
            $dst `
            -Algorithm SHA256).Hash



            if($srcHash -ne $dstHash){

                $copy=$true

            }

        }



        if($copy){


            Copy-Item `
            $src `
            $dst `
            -Force



            Write-Log `
            "SYNC : $($_.Name)"

        }


    }


}



Write-Log "===== Sync Complete ====="


