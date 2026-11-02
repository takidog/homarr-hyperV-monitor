import { createIntegrationAsync } from "@homarr/integrations/factory";
import type { HyperVSnapshot } from "@homarr/integrations/types";

import { createIntegrationRequestHandler } from "./lib/integration-request-handler";

export const hypervSummaryRequestHandler = createIntegrationRequestHandler<
  HyperVSnapshot,
  "hyperv",
  Record<string, never>
>({
  cacheNamespace: "hyperv:summary",
  cacheTtlMs: 5_000,
  fallbackToStaleOnError: false,
  async requestAsync(integration) {
    const instance = await createIntegrationAsync(integration);
    return await instance.getSummaryAsync();
  },
});
