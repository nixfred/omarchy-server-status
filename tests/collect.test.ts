import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
  groupDisksBySource,
  parseContainers,
  parseDiskRows,
  parseHost,
  parseSize,
  splitSections,
} from "../backend/collect";

const SAMPLE = `@@HOST@@
demo-app-01
4
0.35 0.20 0.19 1/523 12345
563122.33 2100000.00
@@MEM@@
Mem:      7789748224  2670592000   245760000    41943040  4873356224  5119148032
Swap:     2147479552   536870912  1610608640
@@DISK@@
/dev/vda1 ext4 /               126692061184  21474836480 100086840320
/dev/vdb1 ext4 /lhcos-data  281474976710656            0 281474976710656
@@NET@@
    lo: 8000000    100    0    0    0     0          0         0  8000000    100    0    0    0     0       0          0
  eth0: 18579456000 200000    0    0    0     0          0         0 1073741824 150000    0    0    0     0       0          0
tailscale0: 52428800   9000    0    0    0     0          0         0 31457280   8000    0    0    0     0       0          0
docker0: 999999999   500    0    0    0     0          0         0 999999999   500    0    0    0     0       0          0
@@DOCKER_PS@@
{"Names":"web-1","Image":"example/web:sha-abc","Status":"Up 6 days (healthy)","State":"running"}
{"Names":"redis-1","Image":"redis:8.10-alpine","Status":"Up 6 days (healthy)","State":"running"}
@@DOCKER_STATS@@
{"Name":"web-1","CPUPerc":"9.39%","MemUsage":"1.254GiB / 4GiB","MemPerc":"31.34%","NetIO":"1.2GB / 300MB","BlockIO":"10MB / 5MB","PIDs":"58"}
{"Name":"redis-1","CPUPerc":"0.20%","MemUsage":"4.2MiB / 512MiB","MemPerc":"0.82%","NetIO":"100MB / 90MB","BlockIO":"1MB / 0B","PIDs":"6"}
@@DOCKER_INSPECT@@
{"Name":"/web-1","Restarts":0,"StartedAt":"2026-08-13T02:00:00Z","Status":"running","OOM":false,"Health":"healthy"}
{"Name":"/redis-1","Restarts":2,"StartedAt":"2026-08-13T02:00:00Z","Status":"running","OOM":false,"Health":"healthy"}
@@END@@
`;

describe("splitSections", () => {
  test("splits marker-delimited sections", () => {
    const sections = splitSections(SAMPLE);
    expect([...sections.keys()]).toEqual([
      "HOST",
      "MEM",
      "DISK",
      "NET",
      "DOCKER_PS",
      "DOCKER_STATS",
      "DOCKER_INSPECT",
    ]);
    expect(sections.get("DOCKER_PS")?.length).toBe(2);
  });
});

describe("parseHost", () => {
  const host = parseHost(splitSections(SAMPLE));

  test("reads hostname, cpu, load, uptime", () => {
    expect(host?.hostname).toBe("demo-app-01");
    expect(host?.cpuCount).toBe(4);
    expect(host?.load1).toBe(0.35);
    expect(host?.uptimeSeconds).toBe(563122);
  });

  test("reads memory and swap", () => {
    expect(host?.memTotalBytes).toBe(7789748224);
    expect(host?.memUsedBytes).toBe(2670592000);
    expect(host?.memAvailableBytes).toBe(5119148032);
    expect(host?.swapUsedBytes).toBe(536870912);
  });

  test("keeps real disks and drops pseudo COS mounts", () => {
    expect(host?.disks.length).toBe(1);
    expect(host?.disks[0].mount).toBe("/");
  });

  test("sums physical interfaces only", () => {
    // lo, docker0 excluded; eth0 + tailscale0 included
    expect(host?.netRxBytes).toBe(18579456000 + 52428800);
    expect(host?.netTxBytes).toBe(1073741824 + 31457280);
  });
});

describe("parseContainers", () => {
  const containers = parseContainers(splitSections(SAMPLE));

  test("joins ps, stats, and inspect by name", () => {
    expect(containers.length).toBe(2);
    const web = containers.find((c) => c.name === "web-1");
    expect(web?.health).toBe("healthy");
    expect(web?.cpuPercent).toBe(9.39);
    expect(web?.memUsageBytes).toBe(parseSize("1.254GiB"));
    expect(web?.memLimitBytes).toBe(4 * 1024 ** 3);
    expect(web?.memPercent).toBe(31.3);
    const redis = containers.find((c) => c.name === "redis-1");
    expect(redis?.restarts).toBe(2);
  });
});

describe("parseSize", () => {
  test("handles binary and decimal units", () => {
    expect(parseSize("512MiB")).toBe(512 * 1024 ** 2);
    expect(parseSize("1.5GB")).toBe(1_500_000_000);
    expect(parseSize("bogus")).toBe(null);
  });
});

describe("btrfs subvolume grouping", () => {
  // One disk, two partitions: four btrfs subvolumes sharing the btrfs
  // partition, plus a separate boot partition.
  const BTRFS_DF = [
    "/dev/nvme0n1p2 btrfs / 500107862016 460099244032 40008617984",
    "/dev/nvme0n1p2 btrfs /home 500107862016 460099244032 40008617984",
    "/dev/nvme0n1p2 btrfs /var/log 500107862016 460099244032 40008617984",
    "/dev/nvme0n1p2 btrfs /.snapshots 500107862016 460099244032 40008617984",
    "/dev/nvme0n1p1 vfat /boot 1073741824 268435456 805306368",
  ];

  const disks = groupDisksBySource(parseDiskRows(BTRFS_DF));

  test("collapses subvolumes of one filesystem into a single disk", () => {
    expect(disks.length).toBe(2);
  });

  test("keeps separate partitions of the same physical disk apart", () => {
    expect(disks.map((disk) => disk.mount).sort()).toEqual(["/", "/boot"]);
  });

  test("picks the shallowest mount as the group's primary", () => {
    const pool = disks.find((disk) => disk.source === "/dev/nvme0n1p2");
    expect(pool?.mount).toBe("/");
    expect(pool?.fstype).toBe("btrfs");
    expect(pool?.sharedMounts).toEqual(["/.snapshots", "/home", "/var/log"]);
  });

  test("raises one warning, not four, for a filesystem near capacity", () => {
    // 460099244032 / 500107862016 = 92%, over the 80% fail threshold. Before
    // grouping this produced four identical red cards and skewed the rollup.
    const failing = disks.filter((disk) => disk.usedBytes / disk.totalBytes >= 0.8);
    expect(failing.length).toBe(1);
  });

  test("reports the fullest member so quotas cannot hide a full subvolume", () => {
    const quota = groupDisksBySource(parseDiskRows([
      "/dev/nvme0n1p2 btrfs / 1000 100 900",
      "/dev/nvme0n1p2 btrfs /home 1000 950 50",
    ]));
    expect(quota.length).toBe(1);
    expect(quota[0].usedBytes).toBe(950);
  });

  test("does not group filesystems df cannot name", () => {
    const unnamed = groupDisksBySource(parseDiskRows([
      "- fuse /mnt/a 1000 100 900",
      "- fuse /mnt/b 2000 200 1800",
    ]));
    expect(unnamed.length).toBe(2);
  });

  test("keeps mount points containing spaces intact", () => {
    const rows = parseDiskRows(["/dev/sdb1 ext4 /mnt/my backup drive 1000 100 900"]);
    expect(rows.length).toBe(1);
    expect(rows[0].mount).toBe("/mnt/my backup drive");
  });
});

describe("CPU load averaging window", () => {
  const panel = readFileSync(new URL("../Panel.qml", import.meta.url), "utf8");

  test("alerts on the 5-minute average, not the sampling-window spike", () => {
    const hostRows = panel.match(/function hostRows\([^)]*\)\s*\{[\s\S]*?\n  \}/)?.[0] || "";
    expect(hostRows).toContain("info.load5 / info.cpuCount");
    expect(hostRows).not.toContain("info.load1 / info.cpuCount");
  });

  test("still shows all three averages so nothing is hidden", () => {
    const panelText = panel;
    expect(panelText).toContain('"1m " + info.load1.toFixed(2)');
    expect(panelText).toContain('" · 5m " + info.load5.toFixed(2)');
    expect(panelText).toContain('" · 15m " + info.load15.toFixed(2)');
  });
});
