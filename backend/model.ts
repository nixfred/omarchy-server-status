export type FlowState = "pass" | "running" | "warn" | "fail" | "unknown" | "idle";

export interface HostMetrics {
  hostname: string;
  cpuCount: number;
  load1: number;
  load5: number;
  load15: number;
  uptimeSeconds: number;
  memTotalBytes: number;
  memUsedBytes: number;
  memAvailableBytes: number;
  swapTotalBytes: number;
  swapUsedBytes: number;
  disks: DiskMetrics[];
  /** Cumulative counters; the panel derives rates between refreshes. */
  netRxBytes: number;
  netTxBytes: number;
}

export interface DiskMetrics {
  mount: string;
  totalBytes: number;
  usedBytes: number;
  availBytes: number;
}

export interface ContainerMetrics {
  name: string;
  image: string;
  status: string;
  state: string;
  health: string;
  restarts: number;
  startedAt: string;
  oomKilled: boolean;
  cpuPercent: number | null;
  memUsageBytes: number | null;
  memLimitBytes: number | null;
  memPercent: number | null;
  netIo: string;
  blockIo: string;
  pids: number | null;
}

export interface ServerSnapshot {
  schemaVersion: 1;
  generatedAt: string;
  sshHost: string;
  host: HostMetrics | null;
  containers: ContainerMetrics[];
  error: string;
}
