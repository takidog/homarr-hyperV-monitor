#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$Executable = (Join-Path $PSScriptRoot 'hyperv-monitor.exe'),
    [string]$Config = (Join-Path $env:USERPROFILE '.homarr-hyperv-monitor\config.json'),
    [switch]$Replace
)
$ErrorActionPreference = 'Stop'
$taskName = 'Homarr Hyper-V Agent'
$installDirectory = Join-Path $env:ProgramFiles 'Homarr Hyper-V Agent'
$dataDirectory = Join-Path $env:ProgramData 'Homarr Hyper-V Agent'
$sourceConfig = [IO.Path]::GetFullPath($Config)
$settings = Get-Content -LiteralPath $sourceConfig -Raw | ConvertFrom-Json
if (-not (Test-Path -LiteralPath $Executable -PathType Leaf)) { throw 'Build or download hyperv-monitor.exe first.' }
if (-not $settings.token -or -not $settings.bind -or -not $settings.port) { throw 'Run hyperv-monitor.exe configure first.' }
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task -and -not $Replace) { throw 'Task already exists. Use -Replace to update the installed agent from this config.' }

# Read all source material before stopping an existing installation.
$binary = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Executable).Path)
$tlsFiles = @{}
foreach ($property in @('tlsCert', 'tlsKey')) {
    if ($settings.$property) {
        $path = $settings.$property
        if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path (Split-Path $sourceConfig) $path }
        $tlsFiles[$property] = [IO.File]::ReadAllBytes($path)
        $settings.$property = Join-Path $dataDirectory $(if ($property -eq 'tlsCert') { 'server.crt' } else { 'server.key' })
    }
}
if ($task) { Stop-ScheduledTask -TaskName $taskName; Start-Sleep -Seconds 2 }
New-Item -ItemType Directory -Path $installDirectory, $dataDirectory -Force | Out-Null
foreach ($directory in @($installDirectory, $dataDirectory)) {
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    }
    Set-Acl -LiteralPath $directory -AclObject $acl
}
$target = Join-Path $installDirectory 'hyperv-monitor.exe'
$targetConfig = Join-Path $dataDirectory 'config.json'
[IO.File]::WriteAllBytes($target, $binary)
foreach ($property in $tlsFiles.Keys) { [IO.File]::WriteAllBytes($settings.$property, $tlsFiles[$property]) }
[IO.File]::WriteAllText($targetConfig, ($settings | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
# Also reset explicit permissions/owners on files retained from an earlier install.
foreach ($file in (Get-ChildItem -LiteralPath $installDirectory, $dataDirectory -File)) {
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow')))
    }
    Set-Acl -LiteralPath $file.FullName -AclObject $acl
}
$action = New-ScheduledTaskAction -Execute $target -Argument ('run --config "' + $targetConfig + '"')
$taskSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $taskSettings -User 'SYSTEM' -RunLevel Highest -Description 'Read-only Hyper-V metrics for Homarr (Go agent)' -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
Write-Host "Installed '$taskName'. Config: $targetConfig"
Write-Host 'Only allow inbound access from your Homarr server. No firewall rule was added automatically.'
