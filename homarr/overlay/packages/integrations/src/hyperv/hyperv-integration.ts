import { ParseError, readBoundedJsonResponseAsync, ResponseError } from "@homarr/common/server";
import { fetchWithTrustedCertificatesAsync } from "@homarr/core/infrastructure/http";

import type { IntegrationTestingInput } from "../base/integration";
import { Integration } from "../base/integration";
import { TestConnectionError } from "../base/test-connection/test-connection-error";
import type { TestingResult } from "../base/test-connection/test-connection-service";
import type {
  IClusterHealthMonitoringIntegration,
  ISystemHealthMonitoringIntegration,
} from "../interfaces/health-monitoring/health-monitoring-integration";
import { toClusterHealth, toSystemHealth } from "./health-monitoring";
import { hypervSnapshotSchema } from "./hyperv-types";

export class HyperVIntegration
  extends Integration
  implements ISystemHealthMonitoringIntegration, IClusterHealthMonitoringIntegration
{
  public async getSystemInfoAsync() {
    return toSystemHealth(await this.getSummaryAsync());
  }

  public async getClusterInfoAsync() {
    return toClusterHealth(await this.getSummaryAsync(), this.integration.name);
  }

  protected async testingAsync(input: IntegrationTestingInput): Promise<TestingResult> {
    const response = await input.fetchAsync(this.url("/api/v1/snapshot"), {
      headers: this.authHeaders(),
      signal: AbortSignal.timeout(10_000),
      redirect: "error",
    });
    if (!response.ok) return TestConnectionError.StatusResult(response);
    try {
      await parseSnapshotAsync(response);
    } catch (error) {
      if (error instanceof ParseError) return TestConnectionError.ParseResult(error);
      throw error;
    }
    return { success: true };
  }

  public async getSummaryAsync() {
    const response = await fetchWithTrustedCertificatesAsync(this.url("/api/v1/snapshot"), {
      headers: this.authHeaders(),
      signal: AbortSignal.timeout(10_000),
      redirect: "error",
    });
    if (!response.ok) throw new ResponseError(response);
    return await parseSnapshotAsync(response);
  }

  private authHeaders() {
    return { Authorization: `Bearer ${this.getSecretValue("apiKey")}` };
  }
}

async function parseSnapshotAsync(response: Parameters<typeof readBoundedJsonResponseAsync>[0]) {
  try {
    const snapshot = hypervSnapshotSchema.parse(await readBoundedJsonResponseAsync(response, 4 * 1024 * 1024));
    const age = Date.now() - Date.parse(snapshot.collectedAt);
    if (age > 60_000 || age < -60_000) throw new Error("Hyper-V sample is stale or the host clock is out of sync");
    return snapshot;
  } catch (error) {
    throw new ParseError("Invalid or stale Hyper-V snapshot", {
      cause: error instanceof Error ? error : new Error(String(error)),
    });
  }
}
