import { readBounded } from "./collect";
import type { TailnetDevice, TailnetSnapshot } from "./model";

const TAILSCALE_TIMEOUT_MS = 10_000;
const MAX_TAILSCALE_STDOUT_BYTES = 4_194_304; // 4 MiB
const MAX_TAILSCALE_STDERR_BYTES = 16_384;
const MAX_DEVICES = 512;

type JsonRecord = Record<string, unknown>;

function record(value: unknown): JsonRecord {
  return value && typeof value === "object" ? value as JsonRecord : {};
}

function strings(value: unknown): string[] {
  return Array.isArray(value) ? value.map(String).filter(Boolean) : [];
}

function cleanDnsName(value: unknown): string {
  return String(value || "").replace(/\.+$/, "");
}

function dnsShortName(value: unknown): string {
  return cleanDnsName(value).split(".")[0] || "";
}

export function deviceKind(osValue: unknown, tagsValue: unknown): string {
  const os = String(osValue || "unknown").toLowerCase();
  const tags = strings(tagsValue).map((tag) => tag.toLowerCase());
  if (os === "linux") return tags.includes("tag:server") ? "Linux server" : "Linux host";
  if (os === "macos" || os === "darwin") return "Mac";
  if (os === "windows") return "Windows PC";
  if (os === "ios") return "iPhone / iPad";
  if (os === "android") return "Android device";
  return os === "unknown" ? "Unknown device" : String(osValue);
}

function parseDevice(value: unknown, self: boolean): TailnetDevice | null {
  const source = record(value);
  const id = String(source.ID || source.StableID || "");
  const hostName = String(source.HostName || "");
  const dnsName = cleanDnsName(source.DNSName);
  const dnsShort = dnsShortName(dnsName);
  const genericHostName = hostName === "" || hostName.toLowerCase() === "localhost";
  const name = genericHostName ? (dnsShort || hostName || id) : hostName;
  if (id === "" && name === "") return null;
  const os = String(source.OS || "unknown");
  const lastSeenRaw = String(source.LastSeen || "");
  const lastSeen = lastSeenRaw.startsWith("0001-") ? "" : lastSeenRaw;
  return {
    id: id || `${dnsName}|${hostName}`,
    name,
    hostName,
    dnsName,
    os,
    kind: deviceKind(os, source.Tags),
    online: Boolean(source.Online),
    ips: strings(source.TailscaleIPs),
    tags: strings(source.Tags),
    lastSeen,
    active: Boolean(source.Active),
    self,
    sshHost: dnsName || hostName || name,
    supportsMetrics: os.toLowerCase() === "linux",
  };
}

export function parseTailnetStatus(raw: string): TailnetSnapshot {
  const parsed = record(JSON.parse(raw));
  const devices: TailnetDevice[] = [];
  const self = parseDevice(parsed.Self, true);
  if (self) devices.push(self);

  const peerValue = parsed.Peer;
  const peers = Array.isArray(peerValue)
    ? peerValue
    : Object.values(record(peerValue));
  for (const peer of peers) {
    // Cap before the sort so an oversized peer map never materializes fully.
    if (devices.length >= MAX_DEVICES) break;
    const device = parseDevice(peer, false);
    if (device) devices.push(device);
  }

  devices.sort((a, b) => {
    if (a.self !== b.self) return a.self ? -1 : 1;
    return a.name.localeCompare(b.name, undefined, { sensitivity: "base" });
  });

  return {
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    backendState: String(parsed.BackendState || "Unknown"),
    devices,
    error: "",
  };
}

export async function collectTailnetSnapshot(): Promise<TailnetSnapshot> {
  const process = Bun.spawn(["tailscale", "status", "--json"], {
    stdout: "pipe",
    stderr: "pipe",
    env: { ...Bun.env },
  });
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    process.kill();
  }, TAILSCALE_TIMEOUT_MS);
  const [stdout, stderr, exitCode] = await Promise.all([
    readBounded(process.stdout, MAX_TAILSCALE_STDOUT_BYTES, () => process.kill()),
    readBounded(process.stderr, MAX_TAILSCALE_STDERR_BYTES, () => process.kill()),
    process.exited,
  ]);
  clearTimeout(timer);

  if (timedOut || stdout.overflow || stderr.overflow || exitCode !== 0) {
    return {
      schemaVersion: 1,
      generatedAt: new Date().toISOString(),
      backendState: "Unavailable",
      devices: [],
      error: timedOut
        ? "tailscale status timed out"
        : stdout.overflow || stderr.overflow
          ? `tailscale status output exceeded ${MAX_TAILSCALE_STDOUT_BYTES} bytes`
          : stderr.text.trim().replace(/\s+/g, " ").slice(0, 240) || `tailscale exited ${exitCode}`,
    };
  }

  try {
    return parseTailnetStatus(stdout.text);
  } catch (error) {
    return {
      schemaVersion: 1,
      generatedAt: new Date().toISOString(),
      backendState: "Invalid",
      devices: [],
      error: `Could not read tailscale status: ${String(error)}`,
    };
  }
}
