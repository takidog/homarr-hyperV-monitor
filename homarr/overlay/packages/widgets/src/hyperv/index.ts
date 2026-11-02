import { IconBrandWindows, IconServerOff } from "@tabler/icons-react";

import { getWidgetIntegrationConfig } from "@homarr/definitions";

import { createWidgetDefinition } from "../definition";
import { optionsBuilder } from "../options";

export const { definition, componentLoader } = createWidgetDefinition("hyperv", {
  icon: IconBrandWindows,
  supportsAdvancedFocus: true,
  queryKey: [["widget", "hyperv", "getSummary"]],
  refetchInterval: 10,
  ...getWidgetIntegrationConfig("hyperv"),
  createOptions() {
    return optionsBuilder.from((factory) => ({
      hostName: factory.text({ defaultValue: "", withDescription: true }),
      showStoppedVms: factory.switch({ defaultValue: true }),
      showStorage: factory.switch({ defaultValue: false }),
    }));
  },
  errors: {
    INTERNAL_SERVER_ERROR: {
      icon: IconServerOff,
      message: (t) => t("widget.hyperv.error.unavailable"),
    },
  },
}).withDynamicImport(() => import("./component"));
