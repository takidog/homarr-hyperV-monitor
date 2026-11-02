# Hyper-V Go agent

A standalone Windows Go executable, using an embedded Windows PowerShell 5.1 collector (`Get-VM` and local CIM). The HTTP server, token authentication, configuration, TLS, scheduling and timeout handling are implemented in Go. No Go runtime or separate collector script is needed on the host. Hyper-V and its PowerShell management tools are required.

Only `GET /api/v1/snapshot` is exposed. There is no username/password login, VM control, remote command API or guest agent installation.

## Configure once, then run

Download the Windows amd64 archive from [Releases](https://github.com/takidog/homarr-hyperV-monitor/releases). Extract it and run from an elevated terminal on the Hyper-V host:

```powershell
.\hyperv-monitor.exe configure --bind 127.0.0.1 --port 9276
.\hyperv-monitor.exe
```

Configuration is saved to `%USERPROFILE%\.homarr-hyperv-monitor\config.json`. Subsequent launches without arguments load that file. The dedicated directory is restricted to the current user, Administrators and SYSTEM. The file contains the API token: do not commit or share it.

| Configure option | Meaning |
| --- | --- |
| `--bind IP` | Specific IPv4/IPv6 address; default `127.0.0.1` |
| `--port PORT` | Listener port; default `9276` |
| `--token TOKEN` | Your 32–256 character URL-safe token; omitted = cryptographically random 256-bit token |
| `--token-file PATH` | Read an existing token from a file, avoiding shell history |
| `--interval SECONDS` | Collection interval after each sample; default 10, range 5–20 |
| `--config PATH` | Custom config file in a dedicated directory |
| `--generate-tls` | Generate a self-signed certificate for a specific bind IP, valid for two years |
| `--tls-cert PATH --tls-key PATH` | Use an existing PEM certificate/private key pair |
| `--allow-remote-http` | Explicit opt-in to unencrypted HTTP on a trusted private network |
| `--force` | Replace config; omitted options reset to defaults and omitted token creates a new one |

Changing settings requires restarting the process/task. You can edit the JSON directly, or rerun `configure --force` with all intended values. Generated certificates are not overwritten; to reuse them, specify `--tls-cert` and `--tls-key`. A bind-IP change requires a certificate with matching SANs. For a custom config, launch with `hyperv-monitor.exe --config PATH`.

## HTTPS across machines

Example addresses below are documentation placeholders. Replace them with the Windows and Homarr server IPs:

```powershell
.\hyperv-monitor.exe configure --bind 192.0.2.10 --port 9276 --generate-tls
.\hyperv-monitor.exe
New-NetFirewallRule -DisplayName 'Homarr Hyper-V HTTPS' -Direction Inbound -Action Allow -Protocol TCP -LocalAddress 192.0.2.10 -LocalPort 9276 -RemoteAddress 192.0.2.20
```

Copy **only `server.crt`** to Homarr's `/appdata/trusted-certificates/` directory, then restart Homarr. Keep `server.key` and `config.json` private. No HTTP.sys certificate binding is needed: Go terminates TLS directly. Set the integration URL to `https://192.0.2.10:9276` and API key to `token` from config. Do not disable certificate validation. Renew the generated certificate before expiry and update Homarr's trusted certificate.

A container's `localhost` is the container, not the Windows host. Restrict the Windows firewall to the Homarr server's source IP. HTTP exposes the token to network observers; do not expose the listener to the internet. Initial collection takes a few seconds and returns 503 until ready.

## Start automatically

After configuring and checking the agent, stop the foreground instance and run the included installer as administrator:

```powershell
.\Install-HyperVAgent.ps1
```

It copies the exe into `%ProgramFiles%\Homarr Hyper-V Agent`, copies config/certificates into `%ProgramData%\Homarr Hyper-V Agent`, restricts both to SYSTEM and Administrators, and registers the **Homarr Hyper-V Agent** startup task as SYSTEM. No firewall rule is added automatically. The installed task uses the ProgramData copy; editing your home-directory config does not change that copy.

For an update or config change, run `Install-HyperVAgent.ps1 -Replace` with the intended config. `-Executable PATH` and `-Config PATH` select custom input files. This also replaces the earlier PowerShell prototype's scheduled task.

```powershell
Stop-ScheduledTask -TaskName 'Homarr Hyper-V Agent'
Unregister-ScheduledTask -TaskName 'Homarr Hyper-V Agent' -Confirm:$false
```

These commands remove automatic startup, retaining files/config. To rotate a token, stop the agent, change `token` in the active config, update Homarr's API key and start the agent again.

## Build and check

On Windows with Go 1.25 or newer (release built with Go 1.27.3):

```powershell
cd agent
go test ./...
go vet ./...
go build -trimpath -ldflags '-s -w -X main.version=0.2.0' -o hyperv-monitor.exe .
```

The binary is not Authenticode-signed. Releases include SHA-256 checksums. The source has no third-party Go dependencies. Tests cover token rejection, method/path restrictions, stale/failed sample rejection and remote HTTP opt-in; real Hyper-V collection and SYSTEM startup were also checked on a Windows host.

## Metrics and limitations

| Metric            | Source and meaning                                                                                                                                                                                                                                       |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Host CPU          | CIM `Win32_PerfFormattedData_HvStats_HyperVHypervisorLogicalProcessor`, `_Total.PercentTotalRunTime`; includes guests and the management OS, normalized to 0–100%.                                                                                       |
| Host RAM          | `Win32_OperatingSystem` total visible physical memory minus free physical memory; KiB converted to bytes.                                                                                                                                                |
| VM CPU            | `Get-VM.CPUUsage`, percent of that VM's allocated virtual processors; not percent of the entire host.                                                                                                                                                    |
| GPU / GPU-PV | WDDM `GPU Engine` counters, summed per physical engine and reduced to the busiest engine. VM readings use `Msvm_ComputerSystem.ProcessID` to attribute worker-process activity. This is physical-engine utilization, not GPU partition quota utilization. Unavailable counters/mappings return null; Off/Saved VMs with assigned GPU-PV adapters report zero. No VRAM or DDA metrics. |
| VM RAM            | `MemoryDemand / MemoryAssigned`. Demand is Hyper-V's guest memory estimate, not an exact guest process working-set total. Demand can exceed assignment under pressure. Running guests reporting zero demand display unknown rather than a misleading 0%. |
| VM configuration  | Startup, minimum/maximum RAM and Dynamic Memory flag, all in bytes. An off VM has no assigned RAM; its configured startup RAM remains visible.                                                                                                           |
| VM identity/state | GUID (stable across renames), the original Hyper-V state, and uptime in seconds. Only `Running` counts as running; paused/saved/off states are retained.                                                                                                 |
| Storage           | Local fixed Windows drive volumes and capacity/usage. Guest filesystem usage, VHD allocation, I/O rates, NIC rates, CSV/shared storage and Failover Cluster discovery are not supplied.                                                                  |

Add one integration per host. Collection runs locally every 10 seconds after the previous sample completes; it is independent of HTTP requests. Collection is killed after 30 seconds. A collection failure clears the cache and returns 503. Samples older than 60 seconds are not served. Homarr also validates the payload version, numeric ranges, body size and timestamp; synchronize clocks on both machines. Missing/invalid tokens return 401; other methods return 405. No credentials are returned in snapshots.

For collection failures, run `Collect-HyperVSnapshot.ps1` directly as the same account. Confirm `Get-VM` and the Hyper-V logical processor CIM counters work. Host counter failures must be fixed instead of substituting management-OS CPU readings. Run the exe with its active config in an elevated terminal to inspect launch/collection errors. The startup task's Last Run Result diagnoses launch failures; a 503 diagnoses collection failure or warm-up.

References: [Get-VM](https://learn.microsoft.com/en-us/powershell/module/hyper-v/get-vm), [Hyper-V performance counters](https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/role/hyper-v-server/detecting-virtualized-environment-bottlenecks), [Windows Admin Center VM metrics](https://learn.microsoft.com/en-us/windows-server/manage/windows-admin-center/use/manage-virtual-machines).

GPU metrics require agent v0.2 or later and matching widget code. Older snapshots remain valid; the GPU fields are optional. GPU probe failures do not fail CPU/RAM sampling. WDDM counters are integer percentages, so small per-context loads can be rounded down. See the [GPU-PV notes](../README.md#gpu-pv-monitoring) for attribution and driver limitations.
