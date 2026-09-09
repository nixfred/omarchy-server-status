import type {
  ContainerMetrics,
  DiskMetrics,
  HostMetrics,
  ServerSnapshot,
} from "./model";

const SSH_TIMEOUT_MS = 15_000;
const MAX_SSH_STDOUT_BYTES = 1_048_576; // 1 MiB
const MAX_SSH_STDERR_BYTES = 16_384;
const MAX_CONTAINERS = 256;
const MAX_DISKS = 64;

/**
 * Collect a stream under a byte budget. The cap sits at the producer,
 * before the bytes accumulate in memory; overflow kills the child via
 * onOverflow and is reported rather than silently truncated.
 */
export async function readBounded(
  stream: ReadableStream<Uint8Array>,
  maxBytes: number,
  onOverflow: () => void,
): Promise<{ text: string; overflow: boolean }> {
  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        onOverflow();
        return { text: "", overflow: true };
      }
      chunks.push(value);
    }
  } finally {
    reader.cancel().catch(() => {});
  }
  return { text: Buffer.concat(chunks).toString("utf8"), overflow: false };
}

/**
 * One read-only remote script per refresh. Container calls prefer
 * `sudo -n docker` (operator accounts deliberately outside the docker
 * group), then plain `docker`, then the same pair for `podman` (rootless
 * and rootful). A host with none of those simply yields empty container
 * sections. `inspect` uses a narrow format string on purpose —
 * full inspect JSON would leak container environment variables (secrets)
 * into the snapshot. Section names stay `DOCKER_*` so existing parsers
 * and the snapshot cache keep working.
 */
export const REMOTE_SCRIPT = `
set -o pipefail
echo "@@HOST@@"
hostname
nproc
cat /proc/loadavg
cat /proc/uptime
echo "@@MEM@@"
free -b | sed -n "2p;3p"
echo "@@DISK@@"
df -B1 --output=source,fstype,target,size,used,avail -x tmpfs -x devtmpfs -x overlay -x squashfs -x iso9660 2>/dev/null | tail -n +2
echo "@@NET@@"
tail -n +3 /proc/net/dev
if sudo -n docker version >/dev/null 2>&1; then CTR="sudo -n docker"
elif docker version >/dev/null 2>&1; then CTR="docker"
elif sudo -n podman version >/dev/null 2>&1; then CTR="sudo -n podman"
elif podman version >/dev/null 2>&1; then CTR="podman"
else CTR=""; fi
echo "@@DOCKER_PS@@"
[ -n "$CTR" ] && $CTR ps --all --format "{{json .}}" 2>/dev/null || true
echo "@@DOCKER_STATS@@"
[ -n "$CTR" ] && $CTR stats --no-stream --format "{{json .}}" 2>/dev/null || true
echo "@@DOCKER_INSPECT@@"
ids=$([ -n "$CTR" ] && $CTR ps -aq 2>/dev/null || true)
if [ -n "$ids" ]; then
  $CTR inspect --format '{"Name":{{json .Name}},"Restarts":{{.RestartCount}},"StartedAt":{{json .State.StartedAt}},"Status":{{json .State.Status}},"OOM":{{.State.OOMKilled}},"Health":{{if .State.Health}}{{json .State.Health.Status}}{{else}}"none"{{end}}}' $ids 2>/dev/null || true
fi
echo "@@END@@"
`;

export function sshCommandForHost(sshHost: string): string[] {
  return ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "--", sshHost];
}

export async function runSsh(sshHost: string): Promise<{ stdout: string; error: string }> {
  const process = Bun.spawn(
    [...sshCommandForHost(sshHost), REMOTE_SCRIPT],
    { stdout: "pipe", stderr: "pipe", env: { ...Bun.env } },
  );

  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    process.kill();
  }, SSH_TIMEOUT_MS);

  const [stdout, stderr, exitCode] = await Promise.all([
    readBounded(process.stdout, MAX_SSH_STDOUT_BYTES, () => process.kill()),
    readBounded(process.stderr, MAX_SSH_STDERR_BYTES, () => process.kill()),
    process.exited,
  ]);
  clearTimeout(timer);

  if (timedOut) return { stdout: "", error: `ssh ${sshHost} timed out` };
  if (stdout.overflow || stderr.overflow) {
    return { stdout: "", error: `ssh ${sshHost} output exceeded ${MAX_SSH_STDOUT_BYTES} bytes` };
  }
  if (exitCode !== 0 && !stdout.text.includes("@@HOST@@")) {
    return {
      stdout: "",
      error: stderr.text.trim().replace(/\s+/g, " ").slice(0, 240) || `ssh exited ${exitCode}`,
    };
  }
  return { stdout: stdout.text, error: "" };
}

export function splitSections(raw: string): Map<string, string[]> {
  const sections = new Map<string, string[]>();
  let current = "";
  for (const line of raw.split("\n")) {
    const marker = line.trim().match(/^@@([A-Z_]+)@@$/);
    if (marker) {
      current = marker[1];
      if (current !== "END") sections.set(current, []);
      continue;
    }
    if (current && current !== "END" && line.trim() !== "") {
      sections.get(current)?.push(line);
    }
  }
  return sections;
}

function parseJsonLines<T>(lines: string[]): T[] {
  const rows: T[] = [];
  for (const line of lines) {
    try {
      rows.push(JSON.parse(line) as T);
    } catch {
      // tolerate stray non-JSON output between rows
    }
  }
  return rows;
}

/** "142.3MiB / 4GiB" → bytes pair. */
export function parseSize(value: string): number | null {
  const match = value.trim().match(/^([\d.]+)\s*([KMGTP]?i?B)$/i);
  if (!match) return null;
  const units: Record<string, number> = {
    b: 1,
    kb: 1e3,
    kib: 1024,
    mb: 1e6,
    mib: 1024 ** 2,
    gb: 1e9,
    gib: 1024 ** 3,
    tb: 1e12,
    tib: 1024 ** 4,
  };
  const factor = units[match[2].toLowerCase()];
  return factor === undefined ? null : Math.round(Number(match[1]) * factor);
}

interface DiskRow {
  source: string;
  fstype: string;
  mount: string;
  totalBytes: number;
  usedBytes: number;
  availBytes: number;
}

/**
 * df rows are `source fstype target size used avail`. Parse from both ends:
 * the three counters are always last and the source is always first, so a
 * mount point containing spaces stays intact instead of shifting every column.
 */
export function parseDiskRows(lines: string[]): DiskRow[] {
  const rows: DiskRow[] = [];
  for (const line of lines) {
    const parts = line.trim().split(/\s+/);
    if (parts.length < 6) continue;

    const totalBytes = Number(parts[parts.length - 3]);
    const usedBytes = Number(parts[parts.length - 2]);
    const availBytes = Number(parts[parts.length - 1]);
    if (!Number.isFinite(totalBytes) || !Number.isFinite(usedBytes) || !Number.isFinite(availBytes))
      continue;

    const mount = parts.slice(2, parts.length - 3).join(" ");
    if (!mount.startsWith("/")) continue;

    // Drop pseudo filesystems (e.g. Tencent Lighthouse COS mounts report
    // hundreds of TB, and efivarfs looks full despite not being storage users
    // can act on); anything above 50 TiB is not a local disk here.
    if (totalBytes <= 0 || totalBytes >= 50 * 1024 ** 4) continue;
    if (mount.startsWith("/sys/") || mount.startsWith("/proc/") || mount.startsWith("/dev/")) continue;

    rows.push({ source: parts[0], fstype: parts[1], mount, totalBytes, usedBytes, availBytes });
  }
  return rows;
}

/** Prefer `/`, then the shallowest path, so a group's primary mount is stable. */
function compareMountPriority(a: DiskRow, b: DiskRow): number {
  const aRoot = a.mount === "/";
  const bRoot = b.mount === "/";
  if (aRoot !== bRoot) return aRoot ? -1 : 1;

  const depth = (mount: string) => mount.split("/").filter(Boolean).length;
  const byDepth = depth(a.mount) - depth(b.mount);
  if (byDepth !== 0) return byDepth;
  if (a.mount.length !== b.mount.length) return a.mount.length - b.mount.length;
  return a.mount.localeCompare(b.mount);
}

/**
 * btrfs subvolumes, bind mounts, and anything else mounted more than once all
 * share a single allocation pool, and df reports the same capacity for each of
 * them. Listing them separately means one filesystem crossing a threshold
 * raises the identical warning several times over — noise that also skews the
 * host colour and notification text. Group by filesystem source so a shared
 * pool counts once, and name the other mounts on the survivor.
 */
export function groupDisksBySource(rows: DiskRow[]): DiskMetrics[] {
  const groups = new Map<string, DiskRow[]>();
  for (const row of rows) {
    // df prints "-" for a source it cannot name; fall back to the mount so
    // those stay distinct rather than collapsing into one bogus group.
    const key = row.source !== "" && row.source !== "-" ? row.source : `mount:${row.mount}`;
    const existing = groups.get(key);
    if (existing) existing.push(row);
    else groups.set(key, [row]);
  }

  const disks: DiskMetrics[] = [];
  for (const group of groups.values()) {
    const primary = [...group].sort(compareMountPriority)[0];
    // Subvolume quotas can make members disagree; report the fullest so
    // grouping can never hide the member closest to full.
    const fullest = group.reduce((worst, row) => (row.usedBytes > worst.usedBytes ? row : worst));
    const sharedMounts = group
      .map((row) => row.mount)
      .filter((mount) => mount !== primary.mount)
      .sort();

    disks.push({
      mount: primary.mount,
      totalBytes: fullest.totalBytes,
      usedBytes: fullest.usedBytes,
      availBytes: fullest.availBytes,
      source: primary.source,
      fstype: primary.fstype,
      sharedMounts,
    });
  }

  return disks.sort((a, b) => a.mount.localeCompare(b.mount));
}

export function parseHost(sections: Map<string, string[]>): HostMetrics | null {
  const hostLines = sections.get("HOST") || [];
  if (hostLines.length < 4) return null;
  const [hostname, cpuRaw, loadRaw, uptimeRaw] = hostLines;
  const load = loadRaw.trim().split(/\s+/);

  const memLines = sections.get("MEM") || [];
  const memRow = (memLines[0] || "").trim().split(/\s+/);
  const swapRow = (memLines[1] || "").trim().split(/\s+/);

  // Cap after grouping: the cap exists to bound how much a compromised host
  // can make the panel hold, and grouping is what decides how many disks
  // there actually are.
  const disks = groupDisksBySource(parseDiskRows(sections.get("DISK") || []))
    .slice(0, MAX_DISKS);

  let netRx = 0;
  let netTx = 0;
  for (const line of sections.get("NET") || []) {
    const parts = line.trim().split(/\s+/);
    if (parts.length < 10) continue;
    const iface = parts[0].replace(/:$/, "");
    if (
      iface === "lo" ||
      iface.startsWith("br-") ||
      iface.startsWith("veth") ||
      iface === "docker0" ||
      iface === "podman0"
    )
      continue;
    netRx += Number(parts[1]) || 0;
    netTx += Number(parts[9]) || 0;
  }

  return {
    hostname: hostname.trim(),
    cpuCount: Number(cpuRaw.trim()) || 1,
    load1: Number(load[0]) || 0,
    load5: Number(load[1]) || 0,
    load15: Number(load[2]) || 0,
    uptimeSeconds: Math.round(Number(uptimeRaw.trim().split(/\s+/)[0]) || 0),
    memTotalBytes: Number(memRow[1]) || 0,
    memUsedBytes: Number(memRow[2]) || 0,
    memAvailableBytes: Number(memRow[6]) || 0,
    swapTotalBytes: Number(swapRow[1]) || 0,
    swapUsedBytes: Number(swapRow[2]) || 0,
    disks,
    netRxBytes: netRx,
    netTxBytes: netTx,
  };
}

interface PsRow {
  Names?: string | string[];
  Image?: string;
  Status?: string;
  State?: string;
}

interface StatsRow {
  Name?: string;
  CPUPerc?: string;
  CPU?: number | string;
  MemUsage?: string | number;
  MemLimit?: number;
  MemPerc?: string | number;
  NetIO?: string;
  BlockIO?: string;
  PIDs?: string | number;
}

function psName(row: PsRow): string {
  const names = row.Names;
  if (Array.isArray(names)) return String(names[0] || "");
  return String(names || "");
}

function cpuPercentFromStats(stat: StatsRow | undefined): number | null {
  if (!stat) return null;
  if (stat.CPUPerc != null && stat.CPUPerc !== "") {
    const n = Number(String(stat.CPUPerc).replace("%", ""));
    return Number.isFinite(n) ? n : null;
  }
  if (stat.CPU != null && stat.CPU !== "") {
    const n = Number(stat.CPU);
    return Number.isFinite(n) ? Math.round(n * 10) / 10 : null;
  }
  return null;
}

function memFromStats(stat: StatsRow | undefined): {
  usage: number | null;
  limit: number | null;
  percent: number | null;
} {
  if (!stat) return { usage: null, limit: null, percent: null };

  let usage: number | null = null;
  let limit: number | null = null;
  if (typeof stat.MemUsage === "number") {
    usage = stat.MemUsage;
    limit = typeof stat.MemLimit === "number" ? stat.MemLimit : null;
  } else {
    const memParts = String(stat.MemUsage || "").split("/");
    usage = memParts.length === 2 ? parseSize(memParts[0]) : null;
    limit = memParts.length === 2 ? parseSize(memParts[1]) : null;
  }

  let percent: number | null = null;
  if (stat.MemPerc != null && stat.MemPerc !== "") {
    const n = Number(String(stat.MemPerc).replace("%", ""));
    if (Number.isFinite(n)) percent = Math.round(n * 10) / 10;
  }
  if (percent === null && usage !== null && limit !== null && limit > 0) {
    percent = Math.round((usage / limit) * 1000) / 10;
  }

  return { usage, limit, percent };
}

interface InspectRow {
  Name?: string;
  Restarts?: number;
  StartedAt?: string;
  Status?: string;
  OOM?: boolean;
  Health?: string;
}

export function parseContainers(sections: Map<string, string[]>): ContainerMetrics[] {
  const ps = parseJsonLines<PsRow>(sections.get("DOCKER_PS") || []);
  const stats = parseJsonLines<StatsRow>(sections.get("DOCKER_STATS") || []);
  const inspect = parseJsonLines<InspectRow>(sections.get("DOCKER_INSPECT") || []);

  const statsByName = new Map(stats.map((row) => [String(row.Name || ""), row]));
  const inspectByName = new Map(
    inspect.map((row) => [String(row.Name || "").replace(/^\//, ""), row]),
  );

  return ps.slice(0, MAX_CONTAINERS).map((row) => {
    const name = psName(row);
    const stat = statsByName.get(name);
    const info = inspectByName.get(name);
    const mem = memFromStats(stat);

    return {
      name,
      image: String(row.Image || ""),
      status: String(row.Status || row.State || ""),
      state: String(info?.Status || row.State || ""),
      health: String(info?.Health || "none"),
      restarts: Number(info?.Restarts ?? 0),
      startedAt: String(info?.StartedAt || ""),
      oomKilled: Boolean(info?.OOM),
      cpuPercent: cpuPercentFromStats(stat),
      memUsageBytes: mem.usage,
      memLimitBytes: mem.limit,
      memPercent: mem.percent,
      netIo: String(stat?.NetIO || ""),
      blockIo: String(stat?.BlockIO || ""),
      pids: stat?.PIDs != null && stat.PIDs !== "" ? Number(stat.PIDs) : null,
    };
  });
}

export async function collectSnapshot(sshHost: string): Promise<ServerSnapshot> {
  const { stdout, error } = await runSsh(sshHost);
  if (error) {
    return {
      schemaVersion: 1,
      generatedAt: new Date().toISOString(),
      sshHost,
      host: null,
      containers: [],
      error,
    };
  }
  const sections = splitSections(stdout);
  return {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    sshHost,
    host: parseHost(sections),
    containers: parseContainers(sections),
    error: "",
  };
}
