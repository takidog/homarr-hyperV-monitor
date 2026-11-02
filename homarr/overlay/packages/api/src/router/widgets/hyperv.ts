import { hypervSummaryRequestHandler } from "@homarr/request-handler/hyperv";

import { createOneWidgetIntegrationMiddleware } from "../../middlewares/integration";
import { createTRPCRouter, publicProcedure } from "../../trpc";

export const hypervRouter = createTRPCRouter({
  getSummary: publicProcedure
    .meta({
      mcp: {
        enabled: true,
        description:
          "Get a Hyper-V host's CPU, RAM, local volumes and VM states/usage. VM memory is demand and assigned bytes, not exact guest usage. Requires integrationId from integration_all and query permission for that Hyper-V integration. Read-only.",
      },
    })
    .concat(createOneWidgetIntegrationMiddleware("query", "hyperv"))
    .query(async ({ ctx }) => {
      const { data } = await hypervSummaryRequestHandler.handler(ctx.integration, {}).getDataAsync();
      return data;
    }),
});
