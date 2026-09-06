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
 * One read-only remote script per refresh. Docker calls prefer
 * `sudo -n docker` (operator accounts deliberately outside the docker
 * group) and fall back to plain `docker` for docker-group hosts; a host
 * with neither simply yields empty docker sections.
 * `docker inspect` uses a narrow format string on purpose —
 * full inspect JSON would leak container environment variables (secrets)
 * into the snapshot.
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
df -B1 --output=target,size,used,avail -x tmpfs -x devtmpfs -x overlay -x squashfs -x iso9660 2>/dev/null | tail -n +2
echo "@@NET@@"
tail -n +3 /proc/net/dev
if sudo -n docker version >/dev/null 2>&1; then DOCKER="sudo -n docker"; elif docker version >/dev/null 2>&1; then DOCKER="docker"; else DOCKER=""; fi
echo "@@DOCKER_PS@@"
[ -n "$DOCKER" ] && $DOCKER ps --all --format "{{json .}}" 2>/dev/null || true
echo "@@DOCKER_STATS@@"
[ -n "$DOCKER" ] && $DOCKER stats --no-stream --format "{{json .}}" 2>/dev/null || true
echo "@@DOCKER_INSPECT@@"
ids=$([ -n "$DOCKER" ] && $DOCKER ps -aq 2>/dev/null || true)
if [ -n "$ids" ]; then
  $DOCKER inspect --format '{"Name":{{json .Name}},"Restarts":{{.RestartCount}},"StartedAt":{{json .State.StartedAt}},"Status":{{json .State.Status}},"OOM":{{.State.OOMKilled}},"Health":{{if .State.Health}}{{json .State.Health.Status}}{{else}}"none"{{end}}}' $ids 2>/dev/null || true
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

export function parseHost(sections: Map<string, string[]>): HostMetrics | null {
  const hostLines = sections.get("HOST") || [];
  if (hostLines.length < 4) return null;
  const [hostname, cpuRaw, loadRaw, uptimeRaw] = hostLines;
  const load = loadRaw.trim().split(/\s+/);

  const memLines = sections.get("MEM") || [];
  const memRow = (memLines[0] || "").trim().split(/\s+/);
  const swapRow = (memLines[1] || "").trim().split(/\s+/);

  const disks: DiskMetrics[] = (sections.get("DISK") || [])
    .map((line) => line.trim().split(/\s+/))
    .filter((parts) => parts.length >= 4 && parts[0].startsWith("/"))
    .map((parts) => ({
      mount: parts[0],
      totalBytes: Number(parts[1]) || 0,
      usedBytes: Number(parts[2]) || 0,
      availBytes: Number(parts[3]) || 0,
    }))
    // Drop pseudo filesystems (e.g. Tencent Lighthouse COS mounts report
    // hundreds of TB, and efivarfs looks full despite not being storage users
    // can act on); anything above 50 TiB is not a local disk here.
    .filter((disk) =>
      disk.totalBytes > 0
      && disk.totalBytes < 50 * 1024 ** 4
      && !disk.mount.startsWith("/sys/")
      && !disk.mount.startsWith("/proc/")
      && !disk.mount.startsWith("/dev/"))
    .slice(0, MAX_DISKS);

  let netRx = 0;
  let netTx = 0;
  for (const line of sections.get("NET") || []) {
    const parts = line.trim().split(/\s+/);
    if (parts.length < 10) continue;
    const iface = parts[0].replace(/:$/, "");
    if (iface === "lo" || iface.startsWith("br-") || iface.startsWith("veth") || iface === "docker0")
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
  Names?: string;
  Image?: string;
  Status?: string;
  State?: string;
}

interface StatsRow {
  Name?: string;
  CPUPerc?: string;
  MemUsage?: string;
  MemPerc?: string;
  NetIO?: string;
  BlockIO?: string;
  PIDs?: string;
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
    const name = String(row.Names || "");
    const stat = statsByName.get(name);
    const info = inspectByName.get(name);
    const memParts = String(stat?.MemUsage || "").split("/");
    const memUsage = memParts.length === 2 ? parseSize(memParts[0]) : null;
    const memLimit = memParts.length === 2 ? parseSize(memParts[1]) : null;

    return {
      name,
      image: String(row.Image || ""),
      status: String(row.Status || ""),
      state: String(info?.Status || row.State || ""),
      health: String(info?.Health || "none"),
      restarts: Number(info?.Restarts ?? 0),
      startedAt: String(info?.StartedAt || ""),
      oomKilled: Boolean(info?.OOM),
      cpuPercent: stat?.CPUPerc ? Number(String(stat.CPUPerc).replace("%", "")) : null,
      memUsageBytes: memUsage,
      memLimitBytes: memLimit,
      memPercent:
        memUsage !== null && memLimit !== null && memLimit > 0
          ? Math.round((memUsage / memLimit) * 1000) / 10
          : null,
      netIo: String(stat?.NetIO || ""),
      blockIo: String(stat?.BlockIO || ""),
      pids: stat?.PIDs ? Number(stat.PIDs) : null,
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
