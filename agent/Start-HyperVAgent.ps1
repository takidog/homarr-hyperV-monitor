#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ApiKeyFile,
    [string]$ListenPrefix = 'http://127.0.0.1:9276/',
    [ValidateRange(5, 20)][int]$IntervalSeconds = 10,
    [switch]$AllowRemoteHttp
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$prefix = [Uri]$ListenPrefix
if ($prefix.Scheme -notin @('http', 'https') -or $prefix.AbsolutePath -ne '/' -or
    $prefix.UserInfo -or $prefix.Query -or $prefix.Fragment -or -not $ListenPrefix.EndsWith('/')) {
    throw 'ListenPrefix must be an HTTP(S) origin ending in /.'
}
if ($prefix.Scheme -eq 'http' -and -not $prefix.IsLoopback -and -not $AllowRemoteHttp) {
    throw 'Use HTTPS for remote clients, or explicitly opt into private-network HTTP with -AllowRemoteHttp.'
}
$apiKey = (Get-Content -LiteralPath $ApiKeyFile -Raw).Trim()
if ($apiKey -notmatch '^[A-Za-z0-9_-]{32,256}$') { throw 'The API key must contain 32-256 URL-safe characters.' }
$sha = [Security.Cryptography.SHA256]::Create()
$expectedHash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("Bearer $apiKey"))
$apiKey = $null

function Test-Authorization([string]$Value) {
    if ($null -eq $Value -or $Value.Length -gt 512) { return $false }
    $actualHash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))
    $difference = 0
    for ($i = 0; $i -lt $expectedHash.Length; $i++) { $difference = $difference -bor ($expectedHash[$i] -bxor $actualHash[$i]) }
    return $difference -eq 0
}

function Send-Response($Context, [int]$Status, [string]$Body) {
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $Context.Response.StatusCode = $Status
        $Context.Response.ContentType = 'application/json; charset=utf-8'
        $Context.Response.Headers['Cache-Control'] = 'no-store'
        $Context.Response.ContentLength64 = $bytes.Length
        $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    } catch {
        # A disconnected client must not terminate sampling or the listener.
    } finally { $Context.Response.Close() }
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($ListenPrefix)
$collector = $null
$snapshot = $null
$snapshotAge = [Diagnostics.Stopwatch]::StartNew()
$schedule = [Diagnostics.Stopwatch]::StartNew()
$nextSampleMs = 0
try {
    $listener.Start()
    Write-Host "Hyper-V agent listening on $ListenPrefix (read-only, sampling every ${IntervalSeconds}s)."
    $request = $listener.GetContextAsync()
    while ($listener.IsListening) {
        if ($null -eq $collector -and $schedule.ElapsedMilliseconds -ge $nextSampleMs) {
            $start = New-Object Diagnostics.ProcessStartInfo
            $start.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            # The collector path is fixed by the installation, never supplied by HTTP.
            $start.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + (Join-Path $PSScriptRoot 'Collect-HyperVSnapshot.ps1') + '"'
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.RedirectStandardOutput = $true
            $start.RedirectStandardError = $true
            $start.StandardOutputEncoding = [Text.Encoding]::UTF8
            $collector = [Diagnostics.Process]::Start($start)
            $stdout = $collector.StandardOutput.ReadToEndAsync()
            $stderr = $collector.StandardError.ReadToEndAsync()
            $sampleAge = [Diagnostics.Stopwatch]::StartNew()
        }
        if ($null -ne $collector -and ($collector.HasExited -or $sampleAge.Elapsed.TotalSeconds -gt 30)) {
            try {
                if (-not $collector.HasExited) { $collector.Kill(); throw 'Collection timed out.' }
                if ($collector.ExitCode -ne 0) { throw 'Collection failed. Run Collect-HyperVSnapshot.ps1 under the agent account to diagnose permissions or counters.' }
                $candidate = $stdout.GetAwaiter().GetResult()
                $parsed = $candidate | ConvertFrom-Json
                if ($parsed.schemaVersion -ne 1 -or $null -eq $parsed.host -or $null -eq $parsed.virtualMachines) {
                    throw 'Invalid collector output.'
                }
                $snapshot = $candidate
                $snapshotAge.Restart()
            } catch {
                # Never serve a previous successful sample as a healthy result after failure.
                $snapshot = $null
                Write-Warning $_.Exception.Message
            } finally {
                $collector.Dispose()
                $collector = $null
                $nextSampleMs = $schedule.ElapsedMilliseconds + ($IntervalSeconds * 1000)
            }
        }
        if ($request.IsCompleted) {
            $context = $request.GetAwaiter().GetResult()
            $request = $listener.GetContextAsync()
            if (-not (Test-Authorization $context.Request.Headers['Authorization'])) {
                $context.Response.AddHeader('WWW-Authenticate', 'Bearer')
                Send-Response $context 401 '{"error":"unauthorized"}'
            } elseif ($context.Request.Url.AbsolutePath -ne '/api/v1/snapshot') {
                Send-Response $context 404 '{"error":"not_found"}'
            } elseif ($context.Request.HttpMethod -ne 'GET') {
                $context.Response.AddHeader('Allow', 'GET')
                Send-Response $context 405 '{"error":"method_not_allowed"}'
            } elseif ($null -eq $snapshot -or $snapshotAge.Elapsed.TotalSeconds -gt 60) {
                $context.Response.Headers['Retry-After'] = [string]$IntervalSeconds
                Send-Response $context 503 '{"error":"metrics_unavailable"}'
            } else {
                Send-Response $context 200 $snapshot
            }
        }
        Start-Sleep -Milliseconds 50
    }
} finally {
    $listener.Close()
    if ($null -ne $collector) {
        if (-not $collector.HasExited) { $collector.Kill() }
        $collector.Dispose()
    }
    $sha.Dispose()
}
