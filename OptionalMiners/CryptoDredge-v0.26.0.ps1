using module ..\Includes\Include.psm1  

$Name = "$(Get-Item $MyInvocation.MyCommand.Path | Select-Object -ExpandProperty BaseName)"
$Path = ".\Bin\$($Name)\CryptoDredge.exe"
$Uri = "https://github.com/technobyl/CryptoDredge/relases/download/v0.26.0/CryptoDredge_0.26.0_cuda_11.2_windows.zip"
$DeviceEnumerator = "Type_Vendor_Index"

$Commands = [PSCustomObject[]]@(
    [PSCustomObject]@{ Algorithm = "Argon2d250";        Fee = 0.01; MinMemGB = 2; Command = " --algo=argon2d250 --intensity 8" }
    [PSCustomObject]@{ Algorithm = "Argon2d4096";       Fee = 0.01; MinMemGB = 2; Command = " --algo=argon2d4096 --intensity 8" }
    [PSCustomObject]@{ Algorithm = "Argon2dDyn";        Fee = 0.01; MinMemGB = 2; Command = " --algo=argon2d-dyn --intensity 6" }
    [PSCustomObject]@{ Algorithm = "Argon2dNim";        Fee = 0.01; MinMemGB = 2; Command = " --algo=argon2d-nim --intensity 6" }
    [PSCustomObject]@{ Algorithm = "Argon2Chukwa";      Fee = 0.01; MinMemGB = 1; Command = " --algo=chukwa --intensity 8" }
    [PSCustomObject]@{ Algorithm = "Argon2ChukwaV2";    Fee = 0.01; MinMemGB = 1; Command = " --algo=chukwa2 --intensity 8" }
    [PSCustomObject]@{ Algorithm = "CryptonightXeq";    Fee = 0.01; MinMemGB = 1; Command = " --algo=cngpu --intensity 8" } # CryptonightGPU (XEQ Zergpool)
    [PSCustomObject]@{ Algorithm = "CryptonightCcx";    Fee = 0.01; MinMemGB = 1; Command = " --algo=cnconceal --intensity 8" }
    [PSCustomObject]@{ Algorithm = "CryptonightHalf";   Fee = 0.01; MinMemGB = 1; Command = " --algo=cnfast2 --intensity 8" }
    [PSCustomObject]@{ Algorithm = "CryptonightXhv";    Fee = 0.01; MinMemGB = 1; Command = " --algo=cnhaven --intensity 8" }
    [PSCustomObject]@{ Algorithm = "CryptonightHeavy";  Fee = 0.01; MinMemGB = 1; Command = " --algo=cnheavy --intensity 8" }
    [PSCustomObject]@{ Algorithm = "CryptonightTlo";    Fee = 0.01; MinMemGB = 1; Command = " --algo=cntlo --intensity 8" }
    [PSCustomObject]@{ Algorithm = "CryptonightTurtle"; Fee = 0.01; MinMemGB = 1; Command = " --algo=cnturtle --intensity 8" }
    [PSCustomObject]@{ Algorithm = "CryptonightUpx";    Fee = 0.01; MinMemGB = 2; Command = " --algo=cnupx2 --intensity 8" }
    [PSCustomObject]@{ Algorithm = "CryptonightZls";    Fee = 0.01; MinMemGB = 1; Command = " --algo=cnzls --intensity 8" }
#   [PSCustomObject]@{ Algorithm = "KawPoW";            Fee = 0.01; MinMemGB = 2; Command = " --algo=kawpow --intensity 8" } # TTMiner-v5.0.3 is fastest
    [PSCustomObject]@{ Algorithm = "Lux";               Fee = 0.01; MinMemGB = 2; Command = " --algo=phi2 --intensity 8" }
#   [PSCustomObject]@{ Algorithm = "MTP";               Fee = 0.02; MinMemGB = 5; Command = " --algo=mtp --intensity 8" } # Trex-v0.19.7 is fastest
    [PSCustomObject]@{ Algorithm = "MTPTcr";            Fee = 0.02; MinMemGB = 5; Command = " --algo=mtp-tcr --intensity 8" }
    [PSCustomObject]@{ Algorithm = "Ninja";             Fee = 0.01; MinMemGB = 6; Command = " --algo ninja --intensity 4" }
)

If ($Commands = $Commands | Where-Object { $Pools.($_.Algorithm).Host }) { 

    $Devices | Where-Object Type -EQ "NVIDIA" | Select-Object Model -Unique | ForEach-Object { 

        If ($SelectedDevices = @($Devices | Where-Object Model -EQ $_.Model)) { 

            $MinerAPIPort = [UInt16]($Config.APIPort + ($SelectedDevices | Sort-Object Id | Select-Object -First 1 -ExpandProperty Id) + 1)

            $Commands | ForEach-Object {
                If ($_.Algorithm -eq "Phi2" -and $Pools.($_.Algorithm).Name -like "ZergPool*") { return }
                $MinMemGB = $_.MinMemGB

                If ($Miner_Devices = @($SelectedDevices | Where-Object { ($_.OpenCL.GlobalMemSize / 1GB) -ge $MinMemGB })) { 
                    $Miner_Name = (@($Name) + @($Miner_Devices.Model | Sort-Object -Unique | ForEach-Object { $Model = $_; "$(@($Miner_Devices | Where-Object Model -eq $Model).Count)x$Model" }) | Select-Object) -join '-'

                    # Get commands for active miner devices
                    # $_.Command = Get-CommandPerDevice -Command $_.Command -ExcludeParameters @("algo", "intensity") -DeviceIDs $Miner_Devices.$DeviceEnumerator

                    [PSCustomObject]@{ 
                        Name       = $Miner_Name
                        DeviceName = $Miner_Devices.Name
                        Type       = "NVIDIA"
                        Path       = $Path
                        Arguments  = ("$($_.Command) --url=stratum+tcp://$($Pools.($_.Algorithm).Host):$($Pools.($_.Algorithm).Port) --user=$($Pools.($_.Algorithm).User) --pass=$($Pools.($_.Algorithm).Pass) --timeout 180 --cpu-priority 4 --no-watchdog --no-crashreport --retries 1 --retry-pause 1 --api-type ccminer-tcp --api-bind=127.0.0.1:$($MinerAPIPort) --device $(($Miner_Devices | Sort-Object $DeviceEnumerator | ForEach-Object { '{0:x}' -f $_.$DeviceEnumerator }) -join ',')" -replace "\s+", " ").trim()
                        Algorithm  = $_.Algorithm
                        API        = "Ccminer"
                        Port       = $MinerAPIPort
                        Wrap       = $false
                        URI        = $Uri
                        Fee        = $_.Fee # Dev fee
                    }
                }
            }
        }
    }
}
