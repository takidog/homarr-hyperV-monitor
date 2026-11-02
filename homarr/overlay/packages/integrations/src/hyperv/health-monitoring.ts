import type {
  ClusterHealthMonitoring,
  SystemHealthMonitoring,
} from "../interfaces/health-monitoring/health-monitoring-types";
import type { HyperVSnapshot } from "./hyperv-types";

export const toSystemHealth = ({ host, volumes }: HyperVSnapshot): SystemHealthMonitoring => ({
  version: "—",
  cpuModelName: "—",
  cpuUtilization: host.cpuUsagePercent,
  memUsedInBytes: host.memoryUsedBytes,
  memAvailableInBytes: Math.max(0, host.memoryTotalBytes - host.memoryUsedBytes),
  uptime: host.uptimeSeconds,
  network: null,
  loadAverage: null,
  rebootRequired: null,
  availablePkgUpdates: null,
  cpuTemp: undefined,
  fileSystem: volumes.map((volume) => ({
    deviceName: volume.name,
    used: String(volume.usedBytes),
    available: String(Math.max(0, volume.totalBytes - volume.usedBytes)),
    percentage: (volume.usedBytes / volume.totalBytes) * 100,
  })),
  smart: [],
  gpu:
    host.gpuUsagePercent == null
      ? []
      : [
          {
            gpuId: "hyperv-busiest-engine",
            name: "GPU (busiest engine)",
            processorUtilization: host.gpuUsagePercent,
            memoryUtilization: null,
            temperature: null,
            fanSpeed: null,
          },
        ],
});

export const toClusterHealth = (
  { host, virtualMachines, volumes }: HyperVSnapshot,
  displayName: string,
): ClusterHealthMonitoring => ({
  nodes: [
    {
      type: "node",
      id: host.id,
      name: displayName,
      node: displayName,
      isRunning: true,
      status: "running",
      cpu: { utilization: host.cpuUsagePercent / 100, cores: host.logicalProcessorCount },
      memory: { used: host.memoryUsedBytes, total: host.memoryTotalBytes },
      gpuUsagePercent: host.gpuUsagePercent,
      storage: {
        used: volumes.length ? volumes.reduce((sum, volume) => sum + volume.usedBytes, 0) : null,
        total: volumes.length ? volumes.reduce((sum, volume) => sum + volume.totalBytes, 0) : null,
        read: null,
        write: null,
      },
      network: { in: null, out: null },
      uptime: host.uptimeSeconds,
      haState: null,
    },
  ],
  vms: virtualMachines.map((vm) => ({
    // Homarr's shared VM resource uses the historic Proxmox discriminator.
    type: "qemu",
    id: vm.id,
    vmId: vm.id,
    name: vm.name,
    node: displayName,
    isRunning: vm.state.toLowerCase() === "running",
    status: vm.state,
    cpu: { utilization: vm.cpuUsagePercent / 100, cores: vm.processorCount },
    // Hyper-V reports demand / assigned memory, not guest process RSS.
    memory: { used: vm.memoryDemandBytes, total: vm.memoryAssignedBytes },
    gpuUsagePercent: vm.gpuPartitionCount === 0 ? undefined : vm.gpuUsagePercent,
    storage: { used: null, total: null, read: null, write: null },
    network: { in: null, out: null },
    uptime: vm.uptimeSeconds,
    haState: null,
  })),
  lxcs: [],
  storages: volumes.map((volume) => ({
    type: "storage",
    id: volume.id,
    name: volume.name,
    node: displayName,
    isRunning: true,
    status: "available",
    storagePlugin: volume.fileSystem ?? "—",
    used: volume.usedBytes,
    total: volume.totalBytes,
    isShared: false,
  })),
});
