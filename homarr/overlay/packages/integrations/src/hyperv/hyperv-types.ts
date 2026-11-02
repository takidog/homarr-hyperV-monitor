import { z } from "zod/v4";

const bytes = z.number().int().nonnegative();
const percent = z.number().min(0).max(100);

export const hypervSnapshotSchema = z.object({
  schemaVersion: z.literal(1),
  collectedAt: z.iso.datetime({ offset: true }),
  host: z.object({
    id: z.string().min(1),
    name: z.string().min(1),
    cpuUsagePercent: percent,
    logicalProcessorCount: z.number().int().positive(),
    gpuUsagePercent: percent.nullable().optional(),
    memoryTotalBytes: bytes.positive(),
    memoryUsedBytes: bytes,
    uptimeSeconds: bytes,
  }),
  virtualMachines: z.array(
    z.object({
      id: z.uuid(),
      name: z.string().min(1),
      state: z.string().min(1),
      cpuUsagePercent: percent,
      processorCount: z.number().int().positive(),
      gpuPartitionCount: z.number().int().nonnegative().nullable().optional(),
      gpuUsagePercent: percent.nullable().optional(),
      memoryAssignedBytes: bytes,
      memoryDemandBytes: bytes.nullable(),
      memoryStartupBytes: bytes,
      memoryMinimumBytes: bytes,
      memoryMaximumBytes: bytes,
      dynamicMemoryEnabled: z.boolean(),
      uptimeSeconds: bytes,
    }),
  ),
  volumes: z.array(
    z.object({
      id: z.string().min(1),
      name: z.string().min(1),
      totalBytes: bytes.positive(),
      usedBytes: bytes,
      fileSystem: z.string().nullable(),
    }),
  ),
});

export type HyperVSnapshot = z.infer<typeof hypervSnapshotSchema>;
