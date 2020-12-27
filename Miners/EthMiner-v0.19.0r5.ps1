using module ..\Includes\Include.psm1

$Name = "$(Get-Item $MyInvocation.MyCommand.Path | Select-Object -ExpandProperty BaseName)"
$Path = ".\Bin\$($Name)\ethminer.exe"
$Uri = "https://github.com/Minerx117/ethminer/releases/download/v0.19.0-r5/ethminer0190r5.7z"
$DeviceEnumerator = "Type_Vendor_Slot"
$DAGmemReserve = [Math]::Pow(2, 23) * 17 # Number of epochs 

$Commands = [PSCustomObject[]]@(
    [PSCustomObject]@{ Algorithm = "Ethash"; Type = "AMD";    Command = " --opencl --cl-devices" } # May need https://github.com/ethereum-mining/ethminer/issues/2001
    [PSCustomObject]@{ Algorithm = "Ethash"; Type = "NVIDIA"; Command = " --cuda --cu-devices" } # PhoenixMiner-v5.4c is fastest but has dev fee
)

$Devices | Where-Object Type -in @("AMD", "NVIDIA") | Select-Object Type, Model -Unique | ForEach-Object { 
    If ($SelectedDevices = @($Devices | Where-Object Type -EQ $_.Type | Where-Object Model -EQ $_.Model)) { 

        $MinerAPIPort = [UInt16]($Config.APIPort + ($SelectedDevices | Sort-Object Id | Select-Object -First 1 -ExpandProperty Id) + 1)
        $Miner_Name = (@($Name) + @($SelectedDevices.Model | Sort-Object -Unique | ForEach-Object { $Model = $_; "$(@($Miner_Devices | Where-Object Model -eq $Model).Count)x$Model" }) | Select-Object) -join '-'

        $Commands | Where-Object Type -eq $_.Type | Where-Object { $Pools.($_.Algorithm).Host } | ForEach-Object { 

            $MinMem = $Pools.($_.Algorithm).DAGSize + $DAGmemReserve

            If ($Miner_Devices = @($SelectedDevices | Where-Object { $_.OpenCL.GlobalMemSize -ge $MinMem })) {

                # Get commands for active miner devices
                # $_.Command = Get-CommandPerDevice -Command $_.Command -ExcludeParameters @() -DeviceIDs $Miner_Devices.$DeviceEnumerator

                If ($Pools.($_.Algorithm).SSL) { $Protocol = "stratums://" }
                Else { $Protocol = "stratum://" }

                [PSCustomObject]@{ 
                    Name       = $Miner_Name
                    DeviceName = $Miner_Devices.Name
                    Type       = $_.Type
                    Path       = $Path
                    Arguments  = ("-P $Protocol$(If ($Pools.($_.Algorithm).Name -like "MPH*") { $($Pools.($_.Algorithm).User -replace "\.", "%2e") } Else { $($Pools.($_.Algorithm).User) }):$($Pools.($_.Algorithm).Pass)@$($Pools.($_.Algorithm).Host):$($Pools.($_.Algorithm).Port) --api-port -$MinerAPIPort $($_.Command) $(($Miner_Devices | Sort-Object $DeviceEnumerator | ForEach-Object { '{0:x}' -f $_.$DeviceEnumerator }) -join ' ')" -replace "\s+", " ").trim()
                    Algorithm  = $_.Algorithm
                    API        = "EthMiner"
                    Port       = $MinerAPIPort
                    Wrap       = $false
                    URI        = $Uri
                    MinerUri   = "http://localhost:$($MinerAPIPort)"
                }
            }
        }
    }
}