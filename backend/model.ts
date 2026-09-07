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
  /** Filesystem source as df reports it, e.g. "/dev/mapper/root". */
  source?: string;
  /** Filesystem type, e.g. "btrfs" or "ext4". */
  fstype?: string;
  /**
   * Other mount points backed by this same filesystem — btrfs subvolumes,
   * bind mounts. They share one allocation pool, so they are reported as one
   * disk rather than several identical ones. Absent on snapshots cached by
   * versions before grouping existed.
   */
  sharedMounts?: string[];
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

export interface TailnetDevice {
  id: string;
  name: string;
  hostName: string;
  dnsName: string;
  os: string;
  kind: string;
  online: boolean;
  ips: string[];
  tags: string[];
  lastSeen: string;
  active: boolean;
  self: boolean;
  sshHost: string;
  supportsMetrics: boolean;
}

export interface TailnetSnapshot {
  schemaVersion: 1;
  generatedAt: string;
  backendState: string;
  devices: TailnetDevice[];
  error: string;
}
