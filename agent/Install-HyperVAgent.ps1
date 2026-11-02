#Requires -Version 5.1
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$ListenPrefix = 'http://127.0.0.1:9276/',
    [ValidateRange(5, 20)][int]$IntervalSeconds = 10,
    [switch]$AllowRemoteHttp
)

$ErrorActionPreference = 'Stop'
$taskName = 'Homarr Hyper-V Agent'
$installDirectory = Join-Path $env:ProgramFiles 'Homarr Hyper-V Agent'
$dataDirectory = Join-Path $env:ProgramData 'Homarr Hyper-V Agent'
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    throw "Task '$taskName' already exists. Stop and unregister it before reinstalling; the API key is preserved."
}
$uri = [Uri]$ListenPrefix
if ($ListenPrefix -match '["\r\n]' -or $uri.Scheme -notin @('http', 'https') -or
    $uri.AbsolutePath -ne '/' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or -not $ListenPrefix.EndsWith('/')) {
    throw 'ListenPrefix must be an HTTP(S) origin ending in /.'
}
if ($uri.Scheme -eq 'http' -and -not $uri.IsLoopback -and -not $AllowRemoteHttp) {
    throw 'Use HTTPS for remote clients, or pass -AllowRemoteHttp for a trusted private network.'
}
New-Item -ItemType Directory -Path $installDirectory, $dataDirectory -Force | Out-Null
# Only SYSTEM and local Administrators can replace executable scripts or read the token.
foreach ($directory in @($installDirectory, $dataDirectory)) {
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $directory -AclObject $acl
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Start-HyperVAgent.ps1'), (Join-Path $PSScriptRoot 'Collect-HyperVSnapshot.ps1') -Destination $installDirectory -Force
$keyFile = Join-Path $dataDirectory 'api-key.txt'
if (-not (Test-Path -LiteralPath $keyFile)) {
    $bytes = New-Object byte[] 32
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $random.GetBytes($bytes) } finally { $random.Dispose() }
    [IO.File]::WriteAllText($keyFile, ([BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()))
}
# Reinstalling must also remove explicit permissions on existing files and
# replace their owner; changing only the parent would preserve those grants.
foreach ($file in @($keyFile, (Join-Path $installDirectory 'Start-HyperVAgent.ps1'), (Join-Path $installDirectory 'Collect-HyperVSnapshot.ps1'))) {
    $acl = New-Object Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow')))
    }
    Set-Acl -LiteralPath $file -AclObject $acl
}
$arguments = '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' +
    (Join-Path $installDirectory 'Start-HyperVAgent.ps1') + '" -ApiKeyFile "' + $keyFile +
    '" -ListenPrefix "' + $ListenPrefix + '" -IntervalSeconds ' + $IntervalSeconds
if ($AllowRemoteHttp) { $arguments += ' -AllowRemoteHttp' }
$action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $arguments
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -Settings $settings -User 'SYSTEM' -RunLevel Highest -Description 'Read-only Hyper-V metrics for Homarr' | Out-Null
Start-ScheduledTask -TaskName $taskName
Write-Host "Installed '$taskName'. API key: $keyFile"
Write-Host 'Allow inbound access only from your Homarr server. HTTPS requires an HTTP.sys certificate binding.'
