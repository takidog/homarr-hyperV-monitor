import type { IntegrationDefinition } from "@site/src/types";

export const hypervIntegration: IntegrationDefinition = {
  name: "Hyper-V",
  description: "Monitor a Windows Hyper-V host and its virtual machines through a read-only agent.",
  iconUrl: "https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons@master/svg/microsoft.svg",
  path: "../../integrations/hyperv",
};
