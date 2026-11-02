# Hyper-V agent for Homarr

A read-only Windows PowerShell 5.1 agent for Windows 10/11 Pro and Windows Server with the Hyper-V role and PowerShell management tools. It exposes one authenticated endpoint, `GET /api/v1/snapshot`. No VM control or remote command endpoint is implemented. It does not enable VM resource metering, change VMs, or require guest agents to be installed by Homarr.

## Run

Run in an elevated Windows PowerShell window on the Hyper-V host. Generate a random token in a directory accessible only to the agent account and administrators:

```powershell
$bytes = New-Object byte[] 32
$random = [Security.Cryptography.RandomNumberGenerator]::Create()
$random.GetBytes($bytes)
$random.Dispose()
[IO.File]::WriteAllText('C:\secure\hyperv-api-key.txt', ([BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()))
.\Start-HyperVAgent.ps1 -ApiKeyFile 'C:\secure\hyperv-api-key.txt'
```

The default listener is `http://127.0.0.1:9276/`. Initial collection takes a few seconds; until then the API returns 503. Test it locally:

```powershell
$headers = @{ Authorization = 'Bearer ' + (Get-Content 'C:\secure\hyperv-api-key.txt' -Raw).Trim() }
Invoke-RestMethod 'http://127.0.0.1:9276/api/v1/snapshot' -Headers $headers
```

In Homarr, use the **Hyper-V** integration, set its URL to the agent's reachable origin, and supply this token as the API key. Add the integration to the dedicated **Hyper-V** widget. A Docker container's `localhost` is the container, not the Windows host. For Docker Desktop, use `host.docker.internal` with an appropriate host listener; for a separate server, use the Windows host's LAN name/address.

## Startup and network access

`Install-HyperVAgent.ps1` copies the two runtime scripts to `%ProgramFiles%\Homarr Hyper-V Agent`, creates a random token in `%ProgramData%\Homarr Hyper-V Agent\api-key.txt`, and registers the **Homarr Hyper-V Agent** startup task. It runs as SYSTEM because local Hyper-V/CIM access needs privileges. Both directories are restricted to SYSTEM and Administrators. The task restarts on failure and can run without a signed-in user. Installation does not open a firewall port.

Prefer a TLS reverse proxy on the host, forwarding to the default loopback listener. Alternatively, supply an HTTPS prefix and bind a certificate from the Local Machine certificate store to that port using HTTP.sys:

```powershell
netsh http add sslcert ipport=0.0.0.0:9276 certhash=YOUR_CERTIFICATE_THUMBPRINT appid='{7602CF35-FB39-4B48-ACCB-54B8F2854284}'
.\Install-HyperVAgent.ps1 -ListenPrefix 'https://hyperv.example.net:9276/'
```

The certificate must have a private key and match the hostname. Trust its CA in Homarr; do not disable certificate validation. For an isolated trusted network, HTTP on a specific LAN address is available only with the explicit `-AllowRemoteHttp` flag. HTTP exposes the bearer token to anyone able to observe that network traffic. Restrict an inbound Windows Firewall rule to the Homarr server's IP. Do not expose this listener to the internet.

To stop or remove the startup task (configuration/token files are retained):

```powershell
Stop-ScheduledTask -TaskName 'Homarr Hyper-V Agent'
Unregister-ScheduledTask -TaskName 'Homarr Hyper-V Agent' -Confirm:$false
```

For an update, stop/unregister the task and rerun the installer. The token is preserved. To rotate it, stop the task, replace the token file with another random value, update Homarr, then start the task. Keep installation and token directories protected if using a custom service account or service wrapper.

## Metrics and limitations

| Metric            | Source and meaning                                                                                                                                                                                                                                       |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Host CPU          | CIM `Win32_PerfFormattedData_HvStats_HyperVHypervisorLogicalProcessor`, `_Total.PercentTotalRunTime`; includes guests and the management OS, normalized to 0–100%.                                                                                       |
| Host RAM          | `Win32_OperatingSystem` total visible physical memory minus free physical memory; KiB converted to bytes.                                                                                                                                                |
| VM CPU            | `Get-VM.CPUUsage`, percent of that VM's allocated virtual processors; not percent of the entire host.                                                                                                                                                    |
| VM RAM            | `MemoryDemand / MemoryAssigned`. Demand is Hyper-V's guest memory estimate, not an exact guest process working-set total. Demand can exceed assignment under pressure. Running guests reporting zero demand display unknown rather than a misleading 0%. |
| VM configuration  | Startup, minimum/maximum RAM and Dynamic Memory flag, all in bytes. An off VM has no assigned RAM; its configured startup RAM remains visible.                                                                                                           |
| VM identity/state | GUID (stable across renames), the original Hyper-V state, and uptime in seconds. Only `Running` counts as running; paused/saved/off states are retained.                                                                                                 |
| Storage           | Local fixed Windows drive volumes and capacity/usage. Guest filesystem usage, VHD allocation, I/O rates, NIC rates, CSV/shared storage and Failover Cluster discovery are not supplied.                                                                  |

Add one integration per host. Collection runs locally every 10 seconds after the previous sample completes; it is independent of HTTP requests. Collection is killed after 30 seconds. A collection failure clears the cache and returns 503. Samples older than 60 seconds are not served. Homarr also validates the payload version, numeric ranges, body size and timestamp; synchronize clocks on both machines. Missing/invalid tokens return 401; other methods return 405. No credentials are returned in snapshots.

For collection failures, run `Collect-HyperVSnapshot.ps1` directly as the same account. Confirm `Get-VM` and the Hyper-V logical processor CIM counters work. Host counter failures must be fixed instead of substituting management-OS CPU readings. The startup task's Last Run Result diagnoses launch failures; a 503 diagnoses collection failure or warm-up.

References: [Get-VM](https://learn.microsoft.com/en-us/powershell/module/hyper-v/get-vm), [Hyper-V performance counters](https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/role/hyper-v-server/detecting-virtualized-environment-bottlenecks), [Windows Admin Center VM metrics](https://learn.microsoft.com/en-us/windows-server/manage/windows-admin-center/use/manage-virtual-machines).
