"use client";

import { Accordion, Alert, Badge, Group, Progress, ScrollArea, SimpleGrid, Stack, Text } from "@mantine/core";
import { IconServerOff } from "@tabler/icons-react";

import { clientApi } from "@homarr/api/client";
import type { HyperVSnapshot } from "@homarr/integrations/types";
import { useByteFormatter } from "@homarr/settings";
import type { ScopedTranslationFunction } from "@homarr/translation";
import { useI18n } from "@homarr/translation/client";

import { WidgetEmptyState } from "../common/empty-state";
import { getUsableWidgetQueryData, isInitialWidgetQueryPending } from "../common/query-state";
import { WidgetQueryLoadingState } from "../common/query-state-indicator";
import type { WidgetComponentProps } from "../definition";

export default function HyperVWidget(props: WidgetComponentProps<"hyperv">) {
  const integrationId = props.integrationIds[0];
  return integrationId ? <HyperVContent {...props} integrationId={integrationId} /> : <WidgetEmptyState />;
}

function HyperVContent({
  integrationId,
  options,
  width,
  displayMode,
}: WidgetComponentProps<"hyperv"> & { integrationId: string }) {
  const t = useI18n("widget.hyperv");
  const { formatBytesPair } = useByteFormatter();
  const query = clientApi.widget.hyperv.getSummary.useQuery({ integrationId });
  const data = getUsableWidgetQueryData(query);
  if (isInitialWidgetQueryPending(query)) return <WidgetQueryLoadingState />;
  // Never display cached measurements as healthy after a failed refresh.
  if (query.error || (data && Date.now() - Date.parse(data.collectedAt) > 60_000)) {
    return (
      <Alert color="orange" icon={<IconServerOff size={18} />} m="xs">
        {t("error.unavailable")}
      </Alert>
    );
  }
  if (!data) return <WidgetEmptyState />;

  const advanced = displayMode === "advanced";
  const narrow = !advanced && width < 360;
  const memory = formatBytesPair(data.host.memoryUsedBytes, data.host.memoryTotalBytes);
  const running = data.virtualMachines.filter((vm) => vm.state === "Running").length;
  const vms = data.virtualMachines
    .filter((vm) => options.showStoppedVms || vm.state === "Running")
    .toSorted((a, b) => Number(b.state === "Running") - Number(a.state === "Running") || a.name.localeCompare(b.name));

  return (
    <ScrollArea h={advanced ? "auto" : "100%"} offsetScrollbars="y" type="auto">
      <Stack p="sm" gap="md">
        <Group justify="space-between" gap="xs">
          <Text size="sm" fw={600} style={{ overflowWrap: "anywhere" }}>
            {options.hostName?.trim() || data.host.name}
          </Text>
          <Badge variant="light" color="blue">
            {t("running", { running, total: data.virtualMachines.length })}
          </Badge>
        </Group>
        <SimpleGrid cols={narrow ? 1 : 2} spacing="md">
          <Metric
            label="CPU"
            value={data.host.cpuUsagePercent}
            detail={t("logicalProcessors", { count: data.host.logicalProcessorCount })}
          />
          <Metric
            label="RAM"
            value={(data.host.memoryUsedBytes / data.host.memoryTotalBytes) * 100}
            detail={`${memory.used} / ${memory.total}`}
          />
        </SimpleGrid>
        <Text size="xs" c="dimmed">
          {t("hostUptime", { value: uptime(data.host.uptimeSeconds, t) })}
        </Text>

        <Stack gap="xs">
          <Text size="sm" fw={600}>
            {t("virtualMachines")}
          </Text>
          {vms.length === 0 ? (
            <Text size="sm" c="dimmed">
              {t(options.showStoppedVms ? "noVms" : "noRunningVms")}
            </Text>
          ) : (
            <Accordion multiple variant="default">
              {vms.map((vm) => (
                <VmRow key={vm.id} vm={vm} narrow={narrow} />
              ))}
            </Accordion>
          )}
        </Stack>

        {(options.showStorage || advanced) && data.volumes.length > 0 && (
          <Stack gap="sm">
            <Text size="sm" fw={600}>
              {t("hostStorage")}
            </Text>
            {data.volumes.map((volume) => {
              const storage = formatBytesPair(volume.usedBytes, volume.totalBytes);
              return (
                <Metric
                  key={volume.id}
                  label={volume.name}
                  value={(volume.usedBytes / volume.totalBytes) * 100}
                  detail={`${storage.used} / ${storage.total}`}
                />
              );
            })}
          </Stack>
        )}
        <Text size="xs" c="dimmed">
          {t("sampledAt", { time: new Date(data.collectedAt).toLocaleTimeString() })}
        </Text>
      </Stack>
    </ScrollArea>
  );
}

function Metric({ label, value, detail }: { label: string; value: number; detail: string }) {
  return (
    <Stack gap={4}>
      <Group justify="space-between" gap="xs">
        <Text size="xs" fw={600} style={{ overflowWrap: "anywhere" }}>
          {label}
        </Text>
        <Text size="sm" fw={600}>
          {value.toFixed(1)}%
        </Text>
      </Group>
      <Progress
        value={Math.min(100, Math.max(0, value))}
        size="sm"
        color={value >= 90 ? "orange" : "blue"}
        aria-label={label}
      />
      <Text size="xs" c="dimmed">
        {detail}
      </Text>
    </Stack>
  );
}

function VmRow({ vm, narrow }: { vm: HyperVSnapshot["virtualMachines"][number]; narrow: boolean }) {
  const t = useI18n("widget.hyperv");
  const { formatBytes } = useByteFormatter();
  const demand = vm.memoryDemandBytes === null ? "—" : formatBytes(vm.memoryDemandBytes);
  const assigned = formatBytes(vm.memoryAssignedBytes);
  const cpu = vm.state === "Running" ? vm.cpuUsagePercent : 0;
  const stateLabel =
    vm.state === "Running"
      ? t("state.running")
      : vm.state === "Off"
        ? t("state.off")
        : vm.state === "Paused"
          ? t("state.paused")
          : vm.state === "Saved"
            ? t("state.saved")
            : vm.state;
  return (
    <Accordion.Item value={vm.id}>
      <Accordion.Control>
        <Stack gap={4}>
          <Group justify="space-between" gap="xs">
            <Text size="sm" fw={500} style={{ overflowWrap: "anywhere" }}>
              {vm.name}
            </Text>
            <Badge size="xs" variant="light" color={vm.state === "Running" ? "green" : "gray"}>
              {stateLabel}
            </Badge>
          </Group>
          <Group gap="sm">
            <Text size="xs">CPU {cpu.toFixed(1)}%</Text>
            <Text size="xs">
              {t("memoryDemandAssigned")} {demand} / {assigned}
            </Text>
          </Group>
        </Stack>
      </Accordion.Control>
      <Accordion.Panel>
        <Stack gap="sm">
          <Text size="xs" c="dimmed">
            {t(vm.memoryDemandBytes === null ? "memoryUnavailable" : "memoryExplanation")}
          </Text>
          <SimpleGrid cols={narrow ? 1 : 2} spacing="xs">
            <Detail label={t("virtualProcessors")} value={String(vm.processorCount)} />
            <Detail label={t("uptime")} value={uptime(vm.uptimeSeconds, t)} />
            <Detail label={t("startupMemory")} value={formatBytes(vm.memoryStartupBytes)} />
            <Detail label={t("dynamicMemory")} value={t(vm.dynamicMemoryEnabled ? "enabled" : "disabled")} />
            {vm.dynamicMemoryEnabled && (
              <>
                <Detail label={t("minimumMemory")} value={formatBytes(vm.memoryMinimumBytes)} />
                <Detail label={t("maximumMemory")} value={formatBytes(vm.memoryMaximumBytes)} />
              </>
            )}
          </SimpleGrid>
          <Detail label={t("vmId")} value={vm.id} />
        </Stack>
      </Accordion.Panel>
    </Accordion.Item>
  );
}

function Detail({ label, value }: { label: string; value: string }) {
  return (
    <Stack gap={0}>
      <Text size="xs" c="dimmed">
        {label}
      </Text>
      <Text size="xs" style={{ overflowWrap: "anywhere" }}>
        {value}
      </Text>
    </Stack>
  );
}

function uptime(seconds: number, t: ScopedTranslationFunction<"widget.hyperv">) {
  const days = Math.floor(seconds / 86400);
  const hours = Math.floor((seconds % 86400) / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  return t("duration", { days, hours, minutes });
}
