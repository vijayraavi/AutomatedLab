﻿#region Install-LabSqlServers
function Install-LabSqlServers
{
    
    [cmdletBinding()]
    param (
        [int]$InstallationTimeout = (Get-LabConfigurationItem -Name Timeout_Sql2012Installation),
        
        [switch]$CreateCheckPoints,

        [ValidateRange(0, 300)]
        [int]$ProgressIndicator = (Get-LabConfigurationItem -Name DefaultProgressIndicator)
    )

    Write-LogFunctionEntry

    if (-not $PSBoundParameters.ContainsKey('ProgressIndicator')) { $PSBoundParameters.Add('ProgressIndicator', $ProgressIndicator) } #enables progress indicator

    function Write-ArgumentVerbose
    {
        param
        (
            $Argument
        )

        Write-ScreenInfo -Type Verbose -Message "Argument '$Argument'"
        $Argument
    }

    Write-LogFunctionEntry

    $lab = Get-Lab -ErrorAction SilentlyContinue

    if (-not $lab)
    {
        Write-LogFunctionExitWithError -Message 'No lab definition imported, so there is nothing to do. Please use the Import-Lab cmdlet first'
        return
    }

    $machines = Get-LabVM -Role SQLServer2008, SQLServer2008R2, SQLServer2012, SQLServer2014, SQLServer2016, SQLServer2017

    #The default SQL installation in Azure does not give the standard buildin administrators group access.
    #This section adds the rights. As only the renamed Builtin Admin account has permissions, Invoke-LabCommand cannot be used.
    $azureMachines = $machines | Where-Object {
        $_.HostType -eq 'Azure' -and -not (($_.Roles |
            Where-Object Name -like 'SQL*').Properties.Keys |
    Where-Object {$_ -ne 'InstallSampleDatabase'})}

    if ($azureMachines)
    {
        Write-ScreenInfo -Message 'Waiting for machines to start up' -NoNewLine
        Start-LabVM -ComputerName $azureMachines -Wait -ProgressIndicator 2
        Enable-LabVMRemoting -ComputerName $azureMachines

        Write-ScreenInfo -Message "Configuring Azure SQL Servers '$($azureMachines -join ', ')'"

        foreach ($machine in $azureMachines)
        {
            Write-ScreenInfo -Type Verbose -Message "Configuring Azure SQL Server '$machine'"
            Write-ScreenInfo -Message (Get-Date)
            $sqlCmd = {
                $query = @"
USE [master]
GO

CREATE LOGIN [BUILTIN\Administrators] FROM WINDOWS WITH DEFAULT_DATABASE=[master], DEFAULT_LANGUAGE=[us_english]
GO

-- ALTER SERVER ROLE [sysadmin] ADD MEMBER [BUILTIN\Administrators]
-- The folloing statement works in SQL 2008 to 2016
EXEC master..sp_addsrvrolemember @loginame = N'BUILTIN\Administrators', @rolename = N'sysadmin'
GO
"@
                if ((Get-PSSnapin -Registered -Name SqlServerCmdletSnapin100 -ErrorAction SilentlyContinue) -and -not (Get-PSSnapin -Name SqlServerCmdletSnapin100 -ErrorAction SilentlyContinue))
                {
                    Add-PSSnapin -Name SqlServerCmdletSnapin100
                }
                Invoke-Sqlcmd -Query $query
            }

            Invoke-LabCommand -ComputerName $machine -ActivityName SetupSqlPermissions -ScriptBlock $sqlCmd -UseLocalCredential
        }
        Write-ScreenInfo -Type Verbose -Message "Finished configuring Azure SQL Servers '$($azureMachines -join ', ')'"
    }

    $onPremisesMachines = @($machines | Where-Object HostType -eq HyperV)
    $onPremisesMachines += $machines | Where-Object {$_.HostType -eq 'Azure' -and (($_.Roles |
            Where-Object Name -like 'SQL*').Properties.Keys |
    Where-Object {$_ -ne 'InstallSampleDatabase'})}

    if ($onPremisesMachines)
    {
        $parallelInstalls = 4
        Write-ScreenInfo -Type Verbose -Message "Parallel installs: $parallelInstalls"
        $machineIndex = 0
        $installBatch = 0
        $totalBatches = [System.Math]::Ceiling($onPremisesMachines.count / $parallelInstalls)
        do
        {
            $jobs = @()

            $installBatch++

            $machinesBatch = $($onPremisesMachines[$machineIndex..($machineIndex + $parallelInstalls - 1)])

            Write-ScreenInfo -Message "Starting machines '$($machinesBatch -join ', ')'" -NoNewLine
            Start-LabVM -ComputerName $machinesBatch -Wait

            Write-ScreenInfo -Message "Starting installation of pre-requisite .Net 3.5 Framework on machine '$($machinesBatch -join ', ')'" -Type Verbose
            $installFrameworkJobs = Install-LabWindowsFeature -ComputerName $machinesBatch -FeatureName Net-Framework-Core -NoDisplay -AsJob -PassThru

            Write-ScreenInfo -Message "Waiting for pre-requisite .Net 3.5 Framework to finish installation on machines '$($machinesBatch -join ', ')'" -NoNewLine
            Wait-LWLabJob -Job $installFrameworkJobs -Timeout 10 -NoDisplay -ProgressIndicator 15 -NoNewLine

            Write-ScreenInfo -Message "Starting installation of pre-requisite C++ redist on machine '$($machinesBatch -join ', ')'" -Type Verbose
            $cppRedist64_2017 = Get-LabInternetFile -Uri $(Get-LabConfigurationItem -Name cppredist64_2017) -Path $labsources\SoftwarePackages -FileName vcredist_x64_2017.exe -PassThru
            $cppredist32_2017 = Get-LabInternetFile -Uri $(Get-LabConfigurationItem -Name cppredist32_2017) -Path $labsources\SoftwarePackages -FileName vcredist_x86_2017.exe -PassThru
            $cppJobs = @()
            $cppJobs += Install-LabSoftwarePackage -Path $cppredist32_2017.FullName -CommandLine ' /quiet /norestart /log C:\DeployDebug\cpp32_2017.log' -ComputerName $machinesBatch -AsJob -ExpectedReturnCodes 0,3010 -PassThru
            $cppJobs += Install-LabSoftwarePackage -Path $cppRedist64_2017.FullName -CommandLine ' /quiet /norestart /log C:\DeployDebug\cpp64_2017.log' -ComputerName $machinesBatch -AsJob -ExpectedReturnCodes 0,3010 -PassThru

            Write-ScreenInfo -Message "Waiting for pre-requisite Visual C++ redistributable to finish installation on machines '$($machinesBatch -join ', ')'" -NoNewLine
            Wait-LWLabJob -Job $cppJobs -Timeout 10 -NoNewLine -ProgressIndicator 5 -NoDisplay

            foreach ($machine in $machinesBatch)
            {
                $role = $machine.Roles | Where-Object Name -like SQLServer*

                #Dismounting ISO images to have just one drive later
                Dismount-LabIsoImage -ComputerName $machine -SupressOutput

                $retryCount = 3
                $autoLogon = (Test-LabAutoLogon -ComputerName $machine)[$machine.Name]
                while (-not $autoLogon -and $retryCount -gt 0)
                {
                    Enable-LabAutoLogon -ComputerName $machine
                    Restart-LabVM -ComputerName $machine -Wait -NoDisplay -NoNewLine

                    $autoLogon = (Test-LabAutoLogon -ComputerName $machine)[$machine.Name]
                    $retryCount--
                }

                if (-not $autoLogon)
                {
                    throw "No logon session available for $($machine.InstallationUser.UserName). Cannot continue with SQL Server setup for $machine"
                }
                Write-ScreenInfo 'Done'

                Mount-LabIsoImage -ComputerName $machine -IsoPath ($lab.Sources.ISOs | Where-Object Name -eq $role.Name).Path -SupressOutput

                $global:setupArguments = ' /Q /Action=Install /IndicateProgress'

                ?? { $role.Properties.ContainsKey('Features') } `
                { $global:setupArguments += Write-ArgumentVerbose -Argument " /Features=$($role.Properties.Features.Replace(' ', ''))" } `
                { $global:setupArguments += Write-ArgumentVerbose -Argument ' /Features=SQL,AS,RS,IS,Tools' }

                if ( $global:setupArguments -match '/Features=.*RS' -and $role.Name -eq 'SQLServer2017')
                {
                    $global:setupArguments = $global:setupArguments -replace ',?RS'

                    if (-not $script:externalSsrs) { $script:externalSsrs = @() }
                    $script:externalSsrs += $machine
                }

                ?? { $role.Properties.ContainsKey('InstanceName') } `
                {
                    $global:setupArguments += Write-ArgumentVerbose -Argument " /InstanceName=$($role.Properties.InstanceName)"
                    $script:instanceName = $role.Properties.InstanceName
                } `
                {
                    $global:setupArguments += Write-ArgumentVerbose -Argument ' /InstanceName=MSSQLSERVER'
                    $script:instanceName = 'MSSQLSERVER'
                }

                $result = Invoke-LabCommand -ComputerName $machine -ScriptBlock {
                    Get-Service -DisplayName "SQL Server ($instanceName)" -ErrorAction SilentlyContinue
                } -Variable (Get-Variable -Name instanceName) -PassThru -NoDisplay

                if ($result)
                {
                    Write-ScreenInfo -Message "Machine '$machine' already has SQL Server installed with requested instance name '$instanceName'" -Type Warning
                    $machine | Add-Member -Name SqlAlreadyInstalled -Value $true -MemberType NoteProperty
                    $machineIndex++
                    continue
                }

                Invoke-Ternary -Decider {$role.Properties.ContainsKey('Collation')} { $global:setupArguments += Write-ArgumentVerbose -Argument (" /SQLCollation=" + "$($role.Properties.Collation)") } { $global:setupArguments += Write-ArgumentVerbose -Argument ' /SQLCollation=Latin1_General_CI_AS' }
                Invoke-Ternary -Decider {$role.Properties.ContainsKey('SQLSvcAccount')} { $global:setupArguments += Write-ArgumentVerbose -Argument (" /SQLSvcAccount=" + """$($role.Properties.SQLSvcAccount)""") } { $global:setupArguments += Write-ArgumentVerbose -Argument ' /SQLSvcAccount="NT Authority\Network Service"' }
                Invoke-Ternary -Decider {$role.Properties.ContainsKey('SQLSvcPassword')} { $global:setupArguments += Write-ArgumentVerbose -Argument (" /SQLSvcPassword=" + """$($role.Properties.SQLSvcPassword)""") } { }
                Invoke-Ternary -Decider {$role.Properties.ContainsKey('AgtSvcAccount')} { $global:setupArguments += Write-ArgumentVerbose -Argument (" /AgtSvcAccount=" + """$($role.Properties.AgtSvcAccount)""") } { $global:setupArguments += Write-ArgumentVerbose -Argument ' /AgtSvcAccount="NT Authority\System"' }
                Invoke-Ternary -Decider {$role.Properties.ContainsKey('AgtSvcPassword')} { $global:setupArguments += Write-ArgumentVerbose -Argument (" /AgtSvcPassword=" + """$($role.Properties.AgtSvcPassword)""") } { }
                Invoke-Ternary -Decider {$role.Properties.ContainsKey('RsSvcAccount')} { $global:setupArguments += Write-ArgumentVerbose -Argument (" /RsSvcAccount=" + """$($role.Properties.RsSvcAccount)""") } { $global:setupArguments += Write-ArgumentVerbose -Argument ' /RsSvcAccount="NT Authority\Network Service"' }
                Invoke-Ternary -Decider {$role.Properties.ContainsKey('RsSvcPassword')} { $global:setupArguments += Write-ArgumentVerbose -Argument (" /RsSvcPassword=" + """$($role.Properties.RsSvcPassword)""") } { }
                Invoke-Ternary -Decider {$role.Properties.ContainsKey('AgtSvcStartupType')} { $global:setupArguments += Write-ArgumentVerbose -Argument (" /AgtSvcStartupType=" + "$($role.Properties.AgtSvcStartupType)") } { $global:setupArguments += Write-ArgumentVerbose -Argument ' /AgtSvcStartupType=Disabled' }
                Invoke-Ternary -Decider {$role.Properties.ContainsKey('BrowserSvcStartupType')} { $global:setupArguments += Write-ArgumentVerbose -Argument (" /BrowserSvcStartupType=" + "$($role.Properties.BrowserSvcStartupType)") } { $global:setupArguments += Write-ArgumentVerbose -Argument ' /BrowserSvcStartupType=Disabled' }
                Invoke-Ternary -Decider {$role.Properties.ContainsKey('RsSvcStartupType')} { $global:setupArguments += Write-ArgumentVerbose -Argument (" /RsSvcStartupType=" + "$($role.Properties.RsSvcStartupType)") } { $global:setupArguments += Write-ArgumentVerbose -Argument ' /RsSvcStartupType=Automatic' }
                Invoke-Ternary -Decider {$role.Properties.ContainsKey('AsSysAdminAccounts')} { $global:setupArguments += Write-ArgumentVerbose -Argument (" /AsSysAdminAccounts=" + "$($role.Properties.AsSysAdminAccounts)") } { $global:setupArguments += Write-ArgumentVerbose -Argument ' /AsSysAdminAccounts="BUILTIN\Administrators"' }
                Invoke-Ternary -Decider {$role.Properties.ContainsKey('AsSvcAccount')} { $global:setupArguments += Write-ArgumentVerbose -Argument (" /AsSvcAccount=" + "$($role.Properties.AsSvcAccount)") } { $global:setupArguments += Write-ArgumentVerbose -Argument ' /AsSvcAccount="NT Authority\System"' }
                Invoke-Ternary -Decider {$role.Properties.ContainsKey('AsSvcPassword')} { $global:setupArguments += Write-ArgumentVerbose -Argument (" /AsSvcPassword=" + "$($role.Properties.AsSvcPassword)") } { }
                Invoke-Ternary -Decider {$role.Properties.ContainsKey('IsSvcAccount')} { $global:setupArguments += Write-ArgumentVerbose -Argument (" /IsSvcAccount=" + "$($role.Properties.IsSvcAccount)") } { $global:setupArguments += Write-ArgumentVerbose -Argument ' /IsSvcAccount="NT Authority\System"' }
                Invoke-Ternary -Decider {$role.Properties.ContainsKey('IsSvcPassword')} { $global:setupArguments += Write-ArgumentVerbose -Argument (" /IsSvcPassword=" + "$($role.Properties.IsSvcPassword)") } { }
                Invoke-Ternary -Decider {$role.Properties.ContainsKey('SQLSysAdminAccounts')} { $global:setupArguments += Write-ArgumentVerbose -Argument (" /SQLSysAdminAccounts=" + "$($role.Properties.SQLSysAdminAccounts)") } { $global:setupArguments += Write-ArgumentVerbose -Argument ' /SQLSysAdminAccounts="BUILTIN\Administrators"' }

                if ($role.Properties.ContainsKey('UseOnlyConfigurationFile'))
                {
                    $global:setupArguments = ''
                }

                if ($role.Properties.ContainsKey('ConfigurationFile'))
                {
                    $global:setupArguments = ''
                }

                if ($role.Properties.ContainsKey('ConfigurationFile'))
                {
                    $fileName = Join-Path -Path 'C:\' -ChildPath (Split-Path -Path $role.Properties.ConfigurationFile -Leaf)

                    try
                    {
                        Copy-LabFileItem -Path $role.Properties.ConfigurationFile -ComputerName $machine -ErrorAction Stop
                        $global:setupArguments += Write-ArgumentVerbose -Argument (" /ConfigurationFile=`"$fileName`"")
                    }
                    catch
                    {
                        Write-PSFMessage -Message ('Could not copy "{0}" to {1}. Skipping configuration file' -f $role.Properties.ConfigurationFile, $machine)
                    }
                }

                Invoke-Ternary -Decider {$machine.Roles.Name -notcontains 'SQLServer2008'} { $global:setupArguments += Write-ArgumentVerbose -Argument (' /IAcceptSQLServerLicenseTerms') } { }

                if ($role.Name -notin 'SQLServer2008R2', 'SQLServer2008')
                {
                    $global:setupArguments += " /UpdateEnabled=`"False`"" # Otherwise we get AccessDenied
                }

                New-LabSqlAccount -Machine $machine -RoleProperties $role.Properties

                $scriptBlock = {
                    Write-Verbose 'Installing SQL Server...'

                    $dvdDrive = ''
                    $startTime = (Get-Date)
                    while (-not $dvdDrive -and (($startTime).AddSeconds(120) -gt (Get-Date)))
                    {
                        Start-Sleep -Seconds 2
                        $dvdDrive = (Get-WmiObject -Class Win32_CDRomDrive | Where-Object MediaLoaded).Drive
                    }

                    if ($dvdDrive)
                    {
                        #Configure App Compatibility for SQL Server 2008. Otherwise a warning pop-up will stop the installation
                        New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags' -Name '{f2d3ae3a-bfcc-45e2-bf63-178d1db34294}' -Value 4 -PropertyType 'DWORD' -ErrorAction SilentlyContinue
                        New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\AppCompatFlags' -Name '{45da5a8b-67b5-4896-86b7-a2e838aee035}' -Value 4 -PropertyType 'DWORD' -ErrorAction SilentlyContinue

                        $installation = Start-Process -FilePath "$dvdDrive\Setup.exe" -ArgumentList $setupArguments -Wait -LoadUserProfile -PassThru

                        if ($installation.ExitCode -notin 0,3010)
                        {
                            throw "SQL Setup failed with exit code $($installation.ExitCode)"
                        }

                        Write-Verbose 'SQL Installation finished. Restarting machine.'

                        Restart-Computer -Force
                    }
                    else
                    {
                        Write-Error -Message 'Setup.exe in ISO file could not be found (or ISO was not successfully mounted)'
                    }
                }

                $param = @{}
                $param.Add('ComputerName', $machine)
                $param.Add('ActivityName', 'Install SQL Server')
                $param.Add('AsJob', $true)
                $param.Add('PassThru', $true)
                $param.Add('NoDisplay', $true)
                $param.Add('Scriptblock', $scriptBlock)
                $param.Add('Variable', (Get-Variable -Name setupArguments))

                $jobs += Invoke-LabCommand @param

                $machineIndex++
            }

            if ($jobs)
            {
                Write-ScreenInfo -Message "Waiting $InstallationTimeout minutes until the installation is finished" -Type Verbose
                Write-ScreenInfo -Message "Waiting for installation of SQL server to complete on machines '$($machinesBatch -join ', ')'" -NoNewLine

                #Start other machines while waiting for SQL server to install
                $startTime = Get-Date
                $additionalMachinesToInstall = Get-LabVM -Role SQLServer2008, SQLServer2008R2, SQLServer2012, SQLServer2014, SQLServer2016, SQLServer2017 |
                Where-Object { (Get-LabVMStatus -ComputerName $_.Name) -eq 'Stopped' }

                if ($additionalMachinesToInstall)
                {
                    Write-PSFMessage -Message 'Preparing more machines while waiting for installation to finish'

                    $machinesToPrepare = Get-LabVM -Role SQLServer2008, SQLServer2008R2, SQLServer2012, SQLServer2014, SQLServer2016, SQLServer2017 |
                    Where-Object { (Get-LabVMStatus -ComputerName $_) -eq 'Stopped' } |
                    Select-Object -First 2

                    while ($startTime.AddMinutes(5) -gt (Get-Date) -and $machinesToPrepare)
                    {
                        Write-PSFMessage -Message "Starting machines '$($machinesToPrepare -join ', ')'"
                        Start-LabVM -ComputerName $machinesToPrepare -Wait -NoNewline

                        Write-PSFMessage -Message "Starting installation of pre-requisite .Net 3.5 Framework on machine '$($machinesToPrepare -join ', ')'"
                        $installFrameworkJobs = Install-LabWindowsFeature -ComputerName $m -FeatureName Net-Framework-Core -NoDisplay -AsJob -PassThru
                        Write-PSFMessage -Message "Waiting for machines '$($machinesToPrepare -join ', ')' to be finish installation of pre-requisite .Net 3.5 Framework"
                        Wait-LWLabJob -Job $installFrameworkJobs -Timeout 10 -NoDisplay -ProgressIndicator 120 -NoNewLine

                        $machinesToPrepare = Get-LabVM -Role SQLServer2008, SQLServer2008R2, SQLServer2012, SQLServer2014, SQLServer2016, SQLServer2017 | Where-Object { (Get-LabVMStatus -ComputerName $_.Name) -eq 'Stopped' } | Select-Object -First 2
                    }
                    Write-PSFMessage -Message "Resuming waiting for SQL Servers batch ($($machinesBatch -join ', ')) to complete installation and restart"
                }

                $installMachines = $machinesBatch | Where-Object { -not $_.SqlAlreadyInstalled }
                Wait-LabVMRestart -ComputerName $installMachines -TimeoutInMinutes $InstallationTimeout -ProgressIndicator 30 -NoNewLine

                Wait-LabVM -ComputerName $installMachines -PostDelaySeconds 30 -NoNewLine

                Dismount-LabIsoImage -ComputerName $machinesBatch -SupressOutput

                if ($installBatch -lt $totalBatches -and ($machinesBatch | Where-Object HostType -eq 'HyperV'))
                {
                    Write-ScreenInfo -Message "Saving machines '$($machinesBatch -join ', ')' as these are not needed right now" -Type Warning
                    Save-VM -Name $machinesBatch
                }
            }

        }
        until ($machineIndex -ge $onPremisesMachines.Count)

        $machinesToPrepare = Get-LabVM -Role SQLServer2008, SQLServer2008R2, SQLServer2012, SQLServer2014, SQLServer2016, SQLServer2017
        $machinesToPrepare = $machinesToPrepare | Where-Object { (Get-LabVMStatus -ComputerName $_) -ne 'Started' }
        if ($machinesToPrepare)
        {
            Start-LabVM -ComputerName $machinesToPrepare -Wait -NoNewline
        }
        else
        {
            Write-ProgressIndicatorEnd
        }

        Write-ScreenInfo -Message "All SQL Servers '$($onPremisesMachines -join ', ')' have now been installed and restarted. Waiting for these to be ready." -NoNewline

        Wait-LabVM -ComputerName $onPremisesMachines -TimeoutInMinutes 30 -ProgressIndicator 10

        if ($script:externalSsrs)
        {
            Write-ScreenInfo -Message "Installing SSRS on $($script:externalSsrs.Count) machines"
            Get-LabInternetFile -Uri (Get-LabConfigurationItem -Name SqlServerReportBuilder) -Path $labSources\SoftwarePackages\ReportBuilder3.msi
            Get-LabInternetFile -Uri (Get-LabConfigurationItem -Name Ssrs2017) -Path $labSources\SoftwarePackages\SQLServerReportingServices.exe
            Install-LabSoftwarePackage -Path $labsources\SoftwarePackages\ReportBuilder3.msi -ComputerName $script:externalSsrs
            Install-LabSoftwarePackage -Path $labsources\SoftwarePackages\SQLServerReportingServices.exe -CommandLine '/Quiet /IAcceptLicenseTerms' -ComputerName $script:externalSsrs
            Invoke-LabCommand -ActivityName 'Configuring SSRS' -ComputerName $script:externalSsrs -FilePath $labSources\PostInstallationActivities\SetupDscPullServer\SetupSqlServerReportingServices.ps1            
        }

        $servers = Get-LabVm |
        Where-Object {$_.Roles.Name -like "SQL*" -and $_.Roles.Name -ge 'SQLServer2016'} |
        Add-Member -Name SqlVersion -MemberType ScriptProperty -Value {
            $roleName = ($this.Roles | Where-Object Name -like "SQL*")[0].Name.ToString()
        $roleName.Substring($roleName.Length - 4, 4)} -PassThru -Force |
        Add-Member -Name 'SsmsUri' -Value {
            Get-LabConfigurationItem -Name "Sql$($this.SQLVersion)ManagementStudio"
        } -MemberType ScriptProperty -PassThru -Force

        if ($servers)
        {
            Write-ScreenInfo -Message "Installing SQL Server Management Studio on '$($servers.Name -join ',')' in the background."
        }

        $jobs = @()

        foreach ($server in $servers)
        {
            if (-not $server.SsmsUri)
            {
                Write-ScreenInfo -Message "No SSMS URI available for $server. Please provide a valid URI in AutomatedLab.psd1 and try again. Skipping..." -Type Warning
                continue
            }

            $downloadFolder = Join-Path -Path $global:labSources\SoftwarePackages -ChildPath $server.SqlVersion
            $downloadPath = Join-Path -Path $downloadFolder -ChildPath 'SSMS-Setup-ENU.exe'

            if (-not (Test-Path $downloadFolder))
            {
                [void] (New-Item -ItemType Directory -Path $downloadFolder)
            }

            Get-LabInternetFile -Uri $server.SsmsUri -Path $downloadPath -NoDisplay

            $jobs += Install-LabSoftwarePackage -Path $downloadPath -CommandLine '/install /quiet' -ComputerName $server -NoDisplay -AsJob -PassThru
        }

        if ($jobs)
        {
            Write-ScreenInfo 'Waiting for SQL Server Management Studio installation jobs to finish' -NoNewLine
            Wait-LWLabJob -Job $jobs -Timeout 10 -NoDisplay -ProgressIndicator 30
        }

        if ($CreateCheckPoints)
        {
            Checkpoint-LabVM -ComputerName ($machines | Where-Object HostType -eq 'HyperV') -SnapshotName 'Post SQL Server Installation'
        }
    }

    foreach ($machine in $machines)
    {
        $role = $machine.Roles | Where-Object Name -like SQLServer*

        if ([System.Convert]::ToBoolean($role.Properties['InstallSampleDatabase']))
        {
            Install-LabSqlSampleDatabases -Machine $machine
        }
    }

    Write-LogFunctionExit
}
#endregion Install-LabSqlServers

#region Install-LabSqlSampleDatabases
function Install-LabSqlSampleDatabases
{
    param
    (
        [Parameter(Mandatory)]
        [AutomatedLab.Machine]
        $Machine
    )

    Write-LogFunctionEntry

    $role = $Machine.Roles | Where-Object Name -like SQLServer* | Sort-Object Name -Descending | Select-Object -First 1
    $roleName = ($role).Name
    $roleInstance = if ($role.Properties['InstanceName'])
    {
        $role.Properties['InstanceName']
    }
    else
    {
        'MSSQLSERVER'
    }

    $sqlLink = Get-LabConfigurationItem -Name $roleName.ToString()
    if (-not $sqlLink)
    {
        throw "No SQL link found to download $roleName sample database"
    }

    $targetFolder = Join-Path -Path (Get-LabSourcesLocationInternal -Local) -ChildPath SoftwarePackages\SqlSampleDbs

    if (-not (Test-Path $targetFolder))
    {
        [void] (New-Item -ItemType Directory -Path $targetFolder)
    }

    if ($roleName -like 'SQLServer2008*')
    {
        $targetFile = Join-Path -Path $targetFolder -ChildPath "$roleName.zip"
    }
    else
    {
        [void] (New-Item -ItemType Directory -Path (Join-Path -Path $targetFolder -ChildPath $rolename) -ErrorAction SilentlyContinue)
        $targetFile = Join-Path -Path $targetFolder -ChildPath "$rolename\$roleName.bak"
    }

    Get-LabInternetFile -Uri $sqlLink -Path $targetFile

    $dependencyFolder = Join-Path -Path $targetFolder -ChildPath $roleName

    switch ($roleName)
    {
        'SQLServer2008'
        {
            Microsoft.PowerShell.Archive\Expand-Archive $targetFile -DestinationPath $dependencyFolder -Force

            Invoke-LabCommand -ActivityName "$roleName Sample DBs" -ComputerName $Machine -ScriptBlock {
                $mdf = Get-Item -Path 'C:\SQLServer2008\AdventureWorksLT2008_Data.mdf' -ErrorAction SilentlyContinue
                $ldf = Get-Item -Path 'C:\SQLServer2008\AdventureWorksLT2008_Log.ldf' -ErrorAction SilentlyContinue
                $connectionInstance = if ($roleInstance -ne 'MSSQLSERVER') { "localhost\$roleInstance" } else { "localhost" }
                $query = 'CREATE DATABASE AdventureWorks2008 ON (FILENAME = "{0}"), (FILENAME = "{1}") FOR ATTACH;' -f $mdf.FullName, $ldf.FullName
                Invoke-Sqlcmd -ServerInstance $connectionInstance -Query $query
            } -DependencyFolderPath $dependencyFolder -Variable (Get-Variable roleInstance)
        }
        'SQLServer2008R2'
        {
            Microsoft.PowerShell.Archive\Expand-Archive $targetFile -DestinationPath $dependencyFolder -Force

            Invoke-LabCommand -ActivityName "$roleName Sample DBs" -ComputerName $Machine -ScriptBlock {
                $mdf = Get-Item -Path 'C:\SQLServer2008R2\AdventureWorksLT2008R2_Data.mdf' -ErrorAction SilentlyContinue
                $ldf = Get-Item -Path 'C:\SQLServer2008R2\AdventureWorksLT2008R2_Log.ldf' -ErrorAction SilentlyContinue
                $connectionInstance = if ($roleInstance -ne 'MSSQLSERVER') { "localhost\$roleInstance" } else { "localhost" }
                $query = 'CREATE DATABASE AdventureWorks2008R2 ON (FILENAME = "{0}"), (FILENAME = "{1}") FOR ATTACH;' -f $mdf.FullName, $ldf.FullName
                Invoke-Sqlcmd -ServerInstance $connectionInstance -Query $query
            } -DependencyFolderPath $dependencyFolder -Variable (Get-Variable roleInstance)
        }
        'SQLServer2012'
        {
            Invoke-LabCommand -ActivityName "$roleName Sample DBs" -ComputerName $Machine -ScriptBlock {
                $backupFile = Get-ChildItem -Filter *.bak -Path C:\SQLServer2012
                $connectionInstance = if ($roleInstance -ne 'MSSQLSERVER') { "localhost\$roleInstance" } else { "localhost" }
                $query = @"
                USE [master]

                RESTORE DATABASE AdventureWorks2012
                FROM disk= '$($backupFile.FullName)'
                WITH MOVE 'AdventureWorks2012_data' TO 'C:\Program Files\Microsoft SQL Server\MSSQL11.$roleInstance\MSSQL\DATA\AdventureWorks2012.mdf',
                MOVE 'AdventureWorks2012_Log' TO 'C:\Program Files\Microsoft SQL Server\MSSQL11.$roleInstance\MSSQL\DATA\AdventureWorks2012.ldf'
                ,REPLACE
"@
                Invoke-Sqlcmd -ServerInstance $connectionInstance -Query $query
            } -DependencyFolderPath $dependencyFolder -Variable (Get-Variable roleInstance)
        }
        'SQLServer2014'
        {
            Invoke-LabCommand -ActivityName "$roleName Sample DBs" -ComputerName $Machine -ScriptBlock {
                $backupFile = Get-ChildItem -Filter *.bak -Path C:\SQLServer2014
                $connectionInstance = if ($roleInstance -ne 'MSSQLSERVER') { "localhost\$roleInstance" } else { "localhost" }
                $query = @"
        USE [master]

        RESTORE DATABASE AdventureWorks2014
        FROM disk= '$($backupFile.FullName)'
        WITH MOVE 'AdventureWorks2014_data' TO 'C:\Program Files\Microsoft SQL Server\MSSQL12.$roleInstance\MSSQL\DATA\AdventureWorks2014.mdf',
        MOVE 'AdventureWorks2014_Log' TO 'C:\Program Files\Microsoft SQL Server\MSSQL12.$roleInstance\MSSQL\DATA\AdventureWorks2014.ldf'
        ,REPLACE
"@
                Invoke-Sqlcmd -ServerInstance $connectionInstance -Query $query
            } -DependencyFolderPath $dependencyFolder -Variable (Get-Variable roleInstance)
        }
        'SQLServer2016'
        {
            Invoke-LabCommand -ActivityName "$roleName Sample DBs" -ComputerName $Machine -ScriptBlock {
                $backupFile = Get-ChildItem -Filter *.bak -Path C:\SQLServer2016
                $connectionInstance = if ($roleInstance -ne 'MSSQLSERVER') { "localhost\$roleInstance" } else { "localhost" }
                $query = @"
        USE master
        RESTORE DATABASE WideWorldImporters
        FROM disk =
        '$($backupFile.FullName)'
        WITH MOVE 'WWI_Primary' TO
        'C:\Program Files\Microsoft SQL Server\MSSQL13.$roleInstance\MSSQL\DATA\WideWorldImporters.mdf',
        MOVE 'WWI_UserData' TO
        'C:\Program Files\Microsoft SQL Server\MSSQL13.$roleInstance\MSSQL\DATA\WideWorldImporters_UserData.ndf',
        MOVE 'WWI_Log' TO
        'C:\Program Files\Microsoft SQL Server\MSSQL13.$roleInstance\MSSQL\DATA\WideWorldImporters.ldf',
        MOVE 'WWI_InMemory_Data_1' TO
        'C:\Program Files\Microsoft SQL Server\MSSQL13.$roleInstance\MSSQL\DATA\WideWorldImporters_InMemory_Data_1',
        REPLACE
"@
                Invoke-Sqlcmd -ServerInstance $connectionInstance -Query $query
            } -DependencyFolderPath $dependencyFolder -Variable (Get-Variable roleInstance)
        }
        'SQLServer2017'
        {
            Invoke-LabCommand -ActivityName "$roleName Sample DBs" -ComputerName $Machine -ScriptBlock {
                $backupFile = Get-ChildItem -Filter *.bak -Path C:\SQLServer2017
                $connectionInstance = if ($roleInstance -ne 'MSSQLSERVER') { "localhost\$roleInstance" } else { "localhost" }
                $query = @"
        USE master
        RESTORE DATABASE WideWorldImporters
        FROM disk =
        '$($backupFile.FullName)'
        WITH MOVE 'WWI_Primary' TO
        'C:\Program Files\Microsoft SQL Server\MSSQL14.$roleInstance\MSSQL\DATA\WideWorldImporters.mdf',
        MOVE 'WWI_UserData' TO
        'C:\Program Files\Microsoft SQL Server\MSSQL14.$roleInstance\MSSQL\DATA\WideWorldImporters_UserData.ndf',
        MOVE 'WWI_Log' TO
        'C:\Program Files\Microsoft SQL Server\MSSQL14.$roleInstance\MSSQL\DATA\WideWorldImporters.ldf',
        MOVE 'WWI_InMemory_Data_1' TO
        'C:\Program Files\Microsoft SQL Server\MSSQL14.$roleInstance\MSSQL\DATA\WideWorldImporters_InMemory_Data_1',
        REPLACE
"@
                Invoke-Sqlcmd -ServerInstance $connectionInstance -Query $query
            } -DependencyFolderPath $dependencyFolder -Variable (Get-Variable roleInstance)
        }
        default
        {
            Write-LogFunctionExitWithError -Exception (New-Object System.ArgumentException("$roleName has no sample scripts yet.", 'roleName'))
        }
    }

    Write-LogFunctionExit
}
#endregion

#region New-LabSqlAccount
function New-LabSqlAccount
{
    param
    (
        [Parameter(Mandatory = $true)]
        [AutomatedLab.Machine]
        $Machine,

        [Parameter(Mandatory = $true)]
        [hashtable]
        $RoleProperties
    )

    $usersAndPasswords = @{}
    $groups = @()
    if ($RoleProperties.ContainsKey('SQLSvcAccount') -and $RoleProperties.ContainsKey('SQLSvcPassword'))
    {
        $usersAndPasswords[$RoleProperties['SQLSvcAccount']] = $RoleProperties['SQLSvcPassword']
    }

    if ($RoleProperties.ContainsKey('AgtSvcAccount') -and $RoleProperties.ContainsKey('AgtSvcPassword'))
    {
        $usersAndPasswords[$RoleProperties['AgtSvcAccount']] = $RoleProperties['AgtSvcPassword']
    }

    if ($RoleProperties.ContainsKey('RsSvcAccount') -and $RoleProperties.ContainsKey('RsSvcPassword'))
    {
        $usersAndPasswords[$RoleProperties['RsSvcAccount']] = $RoleProperties['RsSvcPassword']
    }

    if ($RoleProperties.ContainsKey('AsSvcAccount') -and $RoleProperties.ContainsKey('AsSvcPassword'))
    {
        $usersAndPasswords[$RoleProperties['AsSvcAccount']] = $RoleProperties['AsSvcPassword']
    }

    if ($RoleProperties.ContainsKey('IsSvcAccount') -and $RoleProperties.ContainsKey('IsSvcPassword'))
    {
        $usersAndPasswords[$RoleProperties['IsSvcAccount']] = $RoleProperties['IsSvcPassword']
    }

    if ($RoleProperties.ContainsKey('SqlSysAdminAccounts'))
    {
        $groups += $RoleProperties['SqlSysAdminAccounts']
    }

    if ($RoleProperties.ContainsKey('ConfigurationFile'))
    {
        $config = Get-Content -Path $RoleProperties.ConfigurationFile | ConvertFrom-String -Delimiter = -PropertyNames Key, Value

        if (($config | Where-Object Key -eq SQLSvcAccount) -and ($config | Where-Object Key -eq SQLSvcPassword))
        {
            $user = ($config | Where-Object Key -eq SQLSvcAccount).Value
            $password = ($config | Where-Object Key -eq SQLSvcPassword).Value
            $user = $user.Substring(1, $user.Length - 2)
            $password = $password.Substring(1, $password.Length - 2)
            $usersAndPasswords[$user] = $password
        }

        if (($config | Where-Object Key -eq AgtSvcAccount) -and ($config | Where-Object Key -eq AgtSvcPassword))
        {
            $user = ($config | Where-Object Key -eq AgtSvcAccount).Value
            $password = ($config | Where-Object Key -eq AgtSvcPassword).Value
            $user = $user.Substring(1, $user.Length - 2)
            $password = $password.Substring(1, $password.Length - 2)
            $usersAndPasswords[$user] = $password
        }

        if (($config | Where-Object Key -eq RsSvcAccount) -and ($config | Where-Object Key -eq RsSvcPassword))
        {
            $user = ($config | Where-Object Key -eq RsSvcAccount).Value
            $password = ($config | Where-Object Key -eq RsSvcPassword).Value
            $user = $user.Substring(1, $user.Length - 2)
            $password = $password.Substring(1, $password.Length - 2)
            $usersAndPasswords[$user] = $password
        }

        if (($config | Where-Object Key -eq AsSvcAccount) -and ($config | Where-Object Key -eq AsSvcPassword))
        {
            $user = ($config | Where-Object Key -eq AsSvcAccount).Value
            $password = ($config | Where-Object Key -eq AsSvcPassword).Value
            $user = $user.Substring(1, $user.Length - 2)
            $password = $password.Substring(1, $password.Length - 2)
            $usersAndPasswords[$user] = $password
        }

        if (($config | Where-Object Key -eq IsSvcAccount) -and ($config | Where-Object Key -eq IsSvcPassword))
        {
            $user = ($config | Where-Object Key -eq IsSvcAccount).Value
            $password = ($config | Where-Object Key -eq IsSvcPassword).Value
            $user = $user.Substring(1, $user.Length - 2)
            $password = $password.Substring(1, $password.Length - 2)
            $usersAndPasswords[$user] = $password
        }

        if (($config | Where-Object Key -eq SqlSysAdminAccounts))
        {
            $group = ($config | Where-Object Key -eq SqlSysAdminAccounts).Value
            $groups += $group.Substring(1, $group.Length - 2)
        }
    }

    if ($RoleProperties.ContainsKey('SqlSysAdminAccounts'))
    {
        $groups += $RoleProperties['SqlSysAdminAccounts']
    }

    if ($RoleProperties.ContainsKey('ConfigurationFile'))
    {
        $config = Get-Content -Path $RoleProperties.ConfigurationFile | ConvertFrom-String -Delimiter = -PropertyNames Key, Value

        if (($config | Where-Object Key -eq SQLSvcAccount) -and ($config | Where-Object Key -eq SQLSvcPassword))
        {
            $user = ($config | Where-Object Key -eq SQLSvcAccount).Value
            $password = ($config | Where-Object Key -eq SQLSvcPassword).Value
            $user = $user.Substring(1, $user.Length - 2)
            $password = $password.Substring(1, $password.Length - 2)
            $usersAndPasswords[$user] = $password
        }

        if (($config | Where-Object Key -eq AgtSvcAccount) -and ($config | Where-Object Key -eq AgtSvcPassword))
        {
            $user = ($config | Where-Object Key -eq AgtSvcAccount).Value
            $password = ($config | Where-Object Key -eq AgtSvcPassword).Value
            $user = $user.Substring(1, $user.Length - 2)
            $password = $password.Substring(1, $password.Length - 2)
            $usersAndPasswords[$user] = $password
        }

        if (($config | Where-Object Key -eq RsSvcAccount) -and ($config | Where-Object Key -eq RsSvcPassword))
        {
            $user = ($config | Where-Object Key -eq RsSvcAccount).Value
            $password = ($config | Where-Object Key -eq RsSvcPassword).Value
            $user = $user.Substring(1, $user.Length - 2)
            $password = $password.Substring(1, $password.Length - 2)
            $usersAndPasswords[$user] = $password
        }

        if (($config | Where-Object Key -eq AsSvcAccount) -and ($config | Where-Object Key -eq AsSvcPassword))
        {
            $user = ($config | Where-Object Key -eq AsSvcAccount).Value
            $password = ($config | Where-Object Key -eq AsSvcPassword).Value
            $user = $user.Substring(1, $user.Length - 2)
            $password = $password.Substring(1, $password.Length - 2)
            $usersAndPasswords[$user] = $password
        }

        if (($config | Where-Object Key -eq IsSvcAccount) -and ($config | Where-Object Key -eq IsSvcPassword))
        {
            $user = ($config | Where-Object Key -eq IsSvcAccount).Value
            $password = ($config | Where-Object Key -eq IsSvcPassword).Value
            $user = $user.Substring(1, $user.Length - 2)
            $password = $password.Substring(1, $password.Length - 2)
            $usersAndPasswords[$user] = $password
        }

        if (($config | Where-Object Key -eq SqlSysAdminAccounts))
        {
            $group = ($config | Where-Object Key -eq SqlSysAdminAccounts).Value
            $groups += $group.Substring(1, $group.Length - 2)
        }
    }

    foreach ($kvp in $usersAndPasswords.GetEnumerator())
    {
        $user = $kvp.Key

        if ($kvp.Key.Contains("\"))
        {
            $domain = ($kvp.Key -split "\\")[0]
            $user = ($kvp.Key -split "\\")[1]
        }

        if ($kvp.Key.Contains("@"))
        {
            $domain = ($kvp.Key -split "@")[1]
            $user = ($kvp.Key -split "@")[0]
        }

        $password = $kvp.Value

        if ($domain -match 'NT Authority|BUILTIN')
        {
            continue
        }

        if ($domain)
        {
            $dc = Get-LabVm -Role RootDC, FirstChildDC | Where-Object { $_.DomainName -eq $domain -or ($_.DomainName -split "\.")[0] -eq $domain }

            if (-not $dc)
            {
                Write-ScreenInfo -Message ('User {0} will not be created. No domain controller found for {1}' -f $user,$domain) -Type Warning
            }

            Invoke-LabCommand -ComputerName $dc -ActivityName ("Creating user '$user' in domain '$domain'") -ScriptBlock {
                $existingUser = $null #required as the session is not removed
                try
                {
                    $existingUser = Get-ADUser -Identity $user -Server localhost
                }
                catch { }

                if (-not ($existingUser))
                {
                    New-ADUser -SamAccountName $user -AccountPassword ($password | ConvertTo-SecureString -AsPlainText -Force) -Name $user -PasswordNeverExpires $true -CannotChangePassword $true -Enabled $true -Server localhost
                }
            } -Variable (Get-Variable -Name user, password)
        }
        else
        {
            Invoke-LabCommand -ComputerName $Machine -ActivityName ("Creating local user '$user'") -ScriptBlock {
                if (-not (Get-LocalUser $user -ErrorAction SilentlyContinue))
                {
                    New-LocalUser -Name $user -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword -Password ($password | ConvertTo-SecureString -AsPlainText -Force)
                }
            } -Variable (Get-Variable -Name user, password)
        }
    }

    foreach ($group in $groups)
    {
        if ($group.Contains("\"))
        {
            $domain = ($group -split "\\")[0]
            $groupName = ($group -split "\\")[1]
        }

        if ($group.Contains("@"))
        {
            $domain = ($group -split "@")[1]
            $groupName = ($group -split "@")[0]
        }

        if ($domain -match 'NT Authority|BUILTIN')
        {
            continue
        }

        if ($domain)
        {
            $dc = Get-LabVM -Role RootDC, FirstChildDC | Where-Object { $_.DomainName -eq $domain -or ($_.DomainName -split "\.")[0] -eq $domain }

            if (-not $dc)
            {
                Write-ScreenInfo -Message ('User {0} will not be created. No domain controller found for {1}' -f $user, $domain) -Type Warning
            }

            Invoke-LabCommand -ComputerName $dc -ActivityName ("Creating group '$groupName' in domain '$domain'") -ScriptBlock {
                $existingGroup = $null #required as the session is not removed
                try
                {
                    $existingGroup = Get-ADGroup -Identity $groupName -Server localhost
                }
                catch { }

                if (-not ($existingGroup))
                {
                    $newGroup = New-ADGroup -Name $groupName -GroupScope Global -Server localhost -PassThru
                    #adding the account the script is running under to the SQL admin group
                    $newGroup | Add-ADGroupMember -Members ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)

                }
            } -Variable (Get-Variable -Name groupName)
        }
        else
        {
            Invoke-LabCommand $Machine -ActivityName ('Creating local user {0}' -f $user) -ScriptBlock {
                if (-not (Get-LocalUser $user -ErrorAction SilentlyContinue))
                {
                    New-LocalUser -Name $user -AccountNeverExpires -PasswordNeverExpires -UserMayNotChangePassword -Password ($password | ConvertTo-SecureString -AsPlainText -Force)
                }
            } -Variable (Get-Variable -Name user, password)
        }
    }
}
#endregion
