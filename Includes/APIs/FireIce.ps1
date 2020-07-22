﻿using module ..\Include.psm1

class Fireice : Miner { 
    [String]GetCommandLineParameters() { 
        If ($this.Arguments -match "^{.+}$") { 
            Return ($this.Arguments | ConvertFrom-Json -ErrorAction SilentlyContinue).Commands
        }
        Else { 
            Return $this.Arguments
        }
    }

    CreateConfigFiles() { 
        Try { 
            $Parameters = $this.Arguments | ConvertFrom-Json -ErrorAction SilentlyContinue
            $ConfigFile = "$(Split-Path $this.Path)\$($Parameters.ConfigFile.FileName)"
            $PoolFile = "$(Split-Path $this.Path)\$($Parameters.PoolFile.FileName)"
            $PlatformThreadsConfigFile = "$(Split-Path $this.Path)\$($Parameters.PlatformThreadsConfigFileName)"
            $MinerThreadsConfigFile = "$(Split-Path $this.Path)\$($Parameters.MinerThreadsConfigFileName)"
            $ThreadsConfig = ""

            #Write pool config file, overwrite every time
            ($Parameters.PoolFile.Content | ConvertTo-Json -Depth 10) -replace '^{' -replace '}$', ',' | Set-Content -Path $PoolFile -Force
            #Write config file, keep existing file to preserve user custom config
            If (-not (Test-Path -Path $ConfigFile -PathType Leaf)) { ($Parameters.ConfigFile.Content | ConvertTo-Json -Depth 10) -replace '^{' -replace '}$' | Set-Content -Path $ConfigFile }

            #Check If we have a valid hw file for all installed hardware. If hardware / device order has changed we need to re-create the config files. 
            If (-not (Test-Path -Path $PlatformThreadsConfigFile -PathType Leaf)) { 
                If (Test-Path -Path "$(Split-Path $this.Path)\ThreadsConfig-$($this.Type)-$($this.Algorithm -join "_")-*.txt" -PathType Leaf) { 
                    #Remove old config files, thread info is no longer valid
                    Write-Message -Level Warn "Hardware change detected. Deleting existing configuration files for miner $($this.Info)'."
                    Remove-Item -Path "$(Split-Path $this.Path)\ThreadsConfig-$($this.Type)-$($this.Algorithm -join "_")-*.txt" -Force -ErrorAction SilentlyContinue
                }

                #Temporarily start miner with empty thread conf file. The miner will then create a hw config file with default threads info for all platform hardware
                If ((Test-Path ".\CreateProcess.cs" -PathType Leaf) -and ($this.API -ne "Wrapper")) { 
                    $this.Process = Start-SubProcessWithoutStealingFocus -FilePath $this.Path -ArgumentList $Parameters.HwDetectCommands -WorkingDirectory (Split-Path $this.Path) -Priority ($this.DeviceName | ForEach-Object { If ($_ -like "CPU#*") { -2 } Else { -1 } } | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum) -EnvBlock $this.Environment
                }
                Else { 
                    $EnvCmd = ($this.Environment | ForEach-Object { "```$env:$($_)" }) -join "; "
                    $this.Process = Start-Job ([ScriptBlock]::Create("Start-Process $(@{ desktop = "powershell"; core = "pwsh" }.$Global:PSEdition) `"-command $EnvCmd```$Process = (Start-Process '$($this.Path)' '$($Parameters.HwDetectCommands)' -WorkingDirectory '$(Split-Path $this.Path)' -WindowStyle Minimized -PassThru).Id; Wait-Process -Id `$PID; Stop-Process -Id ```$Process`" -WindowStyle Hidden -Wait"))
                }

                If ($this.Process | Get-Job -ErrorAction SilentlyContinue) { 
                    For ($WaitForPID = 0; $WaitForPID -le 20; $WaitForPID++) { 
                        If ($this.ProcessId = (Get-CIMInstance CIM_Process | Where-Object { $_.ExecutablePath -eq $this.Path } | Where-Object { $_.CommandLine -like "*$($this.Path)*$($Parameters.HwDetectCommands)*" }).ProcessId) { 
                            Break
                        }
                        Start-Sleep -Milliseconds 100
                    }
                    For ($WaitForThreadsConfig = 0; $WaitForThreadsConfig -le 60; $WaitForThreadsConfig++) { 
                        If (Test-Path -Path $PlatformThreadsConfigFile -PathType Leaf) { 
                            #Read hw config created by miner
                            $ThreadsConfig = (Get-Content -Path $PlatformThreadsConfigFile) -replace '^\s*//.*' | Out-String
                            #Set bfactor to 11 (default is 6 which makes PC unusable)
                            $ThreadsConfig = $ThreadsConfig -replace '"bfactor"\s*:\s*\d,', '"bfactor" : 11,'
                            #Reformat to proper json
                            $ThreadsConfigJson = "{$($ThreadsConfig -replace '\/\*.*' -replace '\*\/' -replace '\*.+' -replace '\s' -replace ',\},]', '}]' -replace ',\},\{', '},{' -replace '},]', '}]' -replace ',$', '')}" | ConvertFrom-Json
                            #Keep one instance per gpu config
                            $ThreadsConfigJson | Add-Member gpu_threads_conf ($ThreadsConfigJson.gpu_threads_conf | Sort-Object -Property Index -Unique) -Force
                            #Write json file
                            $ThreadsConfigJson | ConvertTo-Json -Depth 10 | Set-Content -Path $PlatformThreadsConfigFile -Force
                            Break
                        }
                        Start-Sleep -Milliseconds 500
                    }
                    $this.StopMining()
                }
                Else { 
                    Write-Message -Level Error "Running temporary miner failed - cannot create threads config file '$($this.Info)' [Error: '$($Error | Select-Object -Index 0)']."
                    Return
                }
            }
            If (-not (Test-Path $MinerThreadsConfigFile -PathType Leaf)) { 
                #Retrieve hw config from platform config file
                $ThreadsConfigJson = Get-Content -Path $PlatformThreadsConfigFile | ConvertFrom-Json -ErrorAction SilentlyContinue
                #Filter index for current cards and apply threads
                $ThreadsConfigJson | Add-Member gpu_threads_conf ([Array]($ThreadsConfigJson.gpu_threads_conf | Where-Object { $Parameters.Devices -contains $_.Index }) * $Parameters.Threads) -Force
                #Create correct numer of CPU threads
                $ThreadsConfigJson | Add-Member cpu_threads_conf ([Array]$ThreadsConfigJson.cpu_threads_conf * $Parameters.Threads) -Force
                #Write config file
                ($ThreadsConfigJson | ConvertTo-Json -Depth 10) -replace '^{' -replace '}$' | Set-Content -Path $MinerThreadsConfigFile -Force
            }
        }
        catch { 
            Write-Message -Level Error "Creating miner config files for '$($this.Info)' failed [Error: '$($Error | Select-Object -Index 0)']."
            Return
        }
    }

    [Object]UpdateMinerData () { 
        $Timeout = 5 #seconds
        $Data = [PSCustomObject]@{ }
        $PowerUsage = [Double]0
        $Sample = [PSCustomObject]@{ }

        $Request = "http://localhost:$($this.Port)/api.json"
        $Response = ""

        Try { 
            If ($Global:PSVersionTable.PSVersion -ge [System.Version]("6.2.0")) { 
                $Response = Invoke-WebRequest $Request -TimeoutSec $Timeout -DisableKeepAlive -MaximumRetryCount 3 -RetryIntervalSec 1 -ErrorAction Stop
            }
            Else { 
                $Response = Invoke-WebRequest $Request -UseBasicParsing -TimeoutSec $Timeout -DisableKeepAlive -ErrorAction Stop
            }
            $Data = $Response | ConvertFrom-Json -ErrorAction Stop
        }
        Catch { 
            Return $null
        }

        $HashRate = [PSCustomObject]@{ }
        $Shares = [PSCustomObject]@{ }

        $HashRate_Name = [String]$this.Algorithm[0]
        $HashRate_Value = [Double]$Data.hashrate.total[0]
        If (-not $HashRate_Value) { $HashRate_Value = [Double]$Data.hashrate.total[1] } #fix
        If (-not $HashRate_Value) { $HashRate_Value = [Double]$Data.hashrate.total[2] } #fix

        $Shares_Accepted = [Int64]0
        $Shares_Rejected = [Int64]0

        If ($this.AllowedBadShareRatio) { 
            $Shares_Accepted = [Int64]$Data.results.shares_good
            $Shares_Rejected = [Int64]($Data.results.shares_total - $Data.results.shares_good)
            If ((-not $Shares_Accepted -and $Shares_Rejected -ge 3) -or ($Shares_Accepted -and ($Shares_Rejected * $this.AllowedBadShareRatio -gt $Shares_Accepted))) { 
                $this.SetStatus([MinerStatus]::Failed)
            }
            $Shares | Add-Member @{ $HashRate_Name = @($Shares_Accepted, $Shares_Rejected, $($Shares_Accepted + $Shares_Rejected)) }
        }

        If ($HashRate_Name) { 
            $HashRate | Add-Member @{ $HashRate_Name = [Double]$HashRate_Value }
        }

        If ($this.ReadPowerusage) { 
            $PowerUsage = $this.GetPowerUsage()
        }

        If ($HashRate.PSObject.Properties.Value -gt 0) { 
            $Sample = [PSCustomObject]@{ 
                Date       = (Get-Date).ToUniversalTime()
                HashRate   = $HashRate
                PowerUsage = $PowerUsage
                Shares     = $Shares
            }
            Return $Sample
        }
        Return $null
    }
}