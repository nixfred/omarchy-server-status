import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import {
  REMOTE_SCRIPT,
  groupDisksBySource,
  parseContainers,
  parseDiskRows,
  parseHost,
  parseSize,
  splitSections,
} from "../backend/collect";
import { deviceKind, parseTailnetStatus } from "../backend/tailnet";

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
efivarfs efivarfs /sys/firmware/efi/efivars 262144 212992 49152
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

describe("SSH command construction", () => {
  test("terminates SSH options before the host supplied by discovery or settings", async () => {
    const collect = await import("../backend/collect");
    const commandForHost = (collect as Record<string, unknown>).sshCommandForHost;
    expect(typeof commandForHost).toBe("function");
    if (typeof commandForHost !== "function") return;
    expect(commandForHost("-oProxyCommand=touch /tmp/should-not-run")).toEqual([
      "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "--",
      "-oProxyCommand=touch /tmp/should-not-run",
    ]);
  });

  test("excludes read-only ISO mounts from disk capacity alerts", () => {
    expect(REMOTE_SCRIPT).toContain("-x iso9660");
  });
});

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

  test("reports df source and type alongside each disk", () => {
    expect(host?.disks[0].source).toBe("/dev/vda1");
    expect(host?.disks[0].fstype).toBe("ext4");
    expect(host?.disks[0].sharedMounts).toEqual([]);
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

describe("parseTailnetStatus", () => {
  const snapshot = parseTailnetStatus(JSON.stringify({
    BackendState: "Running",
    Self: {
      ID: "self-1", HostName: "server-one", DNSName: "server-one.example.ts.net.", OS: "linux",
      Online: true, TailscaleIPs: ["100.64.0.1"], Tags: ["tag:server"],
    },
    Peer: {
      ios: {
        ID: "ios-1", HostName: "localhost", DNSName: "iphone.example.ts.net.", OS: "iOS",
        Online: false, LastSeen: "2026-08-20T12:00:00Z", TailscaleIPs: ["100.64.0.2"],
      },
      mac: {
        ID: "mac-1", HostName: "laptop-one", DNSName: "laptop-one.example.ts.net.", OS: "macOS",
        Online: true, TailscaleIPs: ["100.64.0.3"],
      },
    },
  }));

  test("keeps self and offline peers clickable in the discovery model", () => {
    expect(snapshot.devices.map((device) => device.id)).toEqual(["self-1", "ios-1", "mac-1"]);
    expect(snapshot.devices.find((device) => device.id === "ios-1")?.online).toBe(false);
  });

  test("uses MagicDNS for generic mobile hostnames", () => {
    const iphone = snapshot.devices.find((device) => device.id === "ios-1");
    expect(iphone?.name).toBe("iphone");
    expect(iphone?.sshHost).toBe("iphone.example.ts.net");
    expect(iphone?.supportsMetrics).toBe(false);
  });

  test("classifies host types and Linux metric support", () => {
    expect(snapshot.devices[0].kind).toBe("Linux server");
    expect(snapshot.devices[0].supportsMetrics).toBe(true);
    expect(deviceKind("android", [])).toBe("Android device");
  });
});

describe("Panel.qml delayed callbacks", () => {
  const panel = readFileSync(new URL("../Panel.qml", import.meta.url), "utf8");

  test("does not defer unbound QML methods across plugin teardown", () => {
    expect(panel).not.toMatch(/Qt\.callLater\(\s*(?:refreshSelectedHost|refreshTailnetIfStale|root\.openTerminal)\s*\)/);
  });

  test("terminates SSH options before interactive terminal hosts", () => {
    const terminalCommand = panel.match(/function terminalCommand\([^)]*\)\s*\{[\s\S]*?\n  \}/)?.[0] || "";
    const openBtop = panel.match(/function openBtop\(\)\s*\{[\s\S]*?\n  \}/)?.[0] || "";
    expect(terminalCommand).toContain('"ssh", "-t", "--", host');
    expect(openBtop).toContain('terminalCommand(activeHost, ["btop || htop || top"])');
  });

  test("left-click selects machine chips and right-click opens SSH", () => {
    const openTerminalFor = panel.match(/function openTerminalFor\([^)]*\)\s*\{[\s\S]*?\n  \}/)?.[0] || "";
    expect(openTerminalFor).toContain("Quickshell.execDetached(terminalCommand(host, []))");
    expect(openTerminalFor).not.toContain("launchInNewWorkspace");
    expect(panel).toContain('text: "MACHINES · LEFT-CLICK TO INSPECT · RIGHT-CLICK TO SSH"');
    expect(panel).toContain("root.selectDevice(parent.modelData)");
    expect(panel).toContain("root.openTerminalFor(parent.target, parent.modelData)");
    expect(panel).not.toContain("id: chipSshAction");
  });

  test("alerts on the 5-minute load average, not the sampling-window spike", () => {
    // The plugin's own SSH connection spikes the remote run queue (PAM session
    // hooks and update-motd.d scripts firing alongside our docker queries), so
    // load1 read during a refresh reports a critical alert on an idle host.
    // That burst recurs on every refresh, so the averaging window — not a
    // debounce — is what rejects it.
    const hostRows = panel.match(/function hostRows\([^)]*\)\s*\{[\s\S]*?\n  \}/)?.[0] || "";
    expect(hostRows).toContain("info.load5 / info.cpuCount");
    expect(hostRows).not.toContain("info.load1 / info.cpuCount");
  });

  test("still shows all three load averages so nothing is hidden", () => {
    const hostRows = panel.match(/function hostRows\([^)]*\)\s*\{[\s\S]*?\n  \}/)?.[0] || "";
    expect(hostRows).toContain('"1m " + info.load1.toFixed(2)');
    expect(hostRows).toContain('" · 5m " + info.load5.toFixed(2)');
    expect(hostRows).toContain('" · 15m " + info.load15.toFixed(2)');
  });

  test("puts the grouped-volume count in the label, not the elided detail", () => {
    // The detail row is a single elided Text on a quarter-width tile, so a
    // suffix appended there is cut off before it can be read. The count has to
    // ride on the short bold label instead.
    const hostRows = panel.match(/function hostRows\([^)]*\)\s*\{[\s\S]*?\n  \}/)?.[0] || "";
    expect(hostRows).toContain('label: "Disk " + disk.mount + (sharedCount > 0 ? " +" + sharedCount : "")');
    const suffix = panel.match(/function diskShareSuffix\([^)]*\)\s*\{[\s\S]*?\n  \}/)?.[0] || "";
    expect(suffix).not.toContain("volumes");
  });

  test("sanitizes remote mount paths before the shell-owned tooltip", () => {
    // PanelToolTip cannot be pinned to PlainText from here, so each host-derived
    // entry goes through plain() individually — plain() strips newlines, so
    // sanitizing the joined string would collapse the list into one line.
    const tooltip = panel.match(/function diskTooltip\([^)]*\)\s*\{[\s\S]*?\n  \}/)?.[0] || "";
    expect(tooltip).toContain("mounts.map(plain).join");
    expect(tooltip).toContain("plain(fstype)");
    expect(tooltip).not.toMatch(/plain\([^)]*mounts\.join/);
  });

  test("names every grouped mount in the tooltip", () => {
    const tooltip = panel.match(/function diskTooltip\([^)]*\)\s*\{[\s\S]*?\n  \}/)?.[0] || "";
    expect(tooltip).toContain("[String(disk.mount)].concat(shared)");
    expect(tooltip).toContain("volumes on one filesystem");
    expect(panel).toContain("text: metricTile.tooltipText");
  });

  test("metric tiles report hover even when they cannot be muted", () => {
    // The MouseArea used to be disabled unless the tile was mutable, which
    // meant a healthy grouped disk could never show its tooltip.
    expect(panel).toContain("hoverEnabled: true");
    expect(panel).toContain("acceptedButtons: metricTile.canToggleMute ? Qt.LeftButton : Qt.NoButton");
    expect(panel).not.toContain("enabled: metricTile.canToggleMute");
  });

  test("privacy mode keeps the volume count but drops the mount paths", () => {
    const label = panel.match(/function displayMetricLabel\([^)]*\)\s*\{[\s\S]*?\n  \}/)?.[0] || "";
    expect(label).toContain('"Disk volume" + (grouped ? grouped[0] : "")');
    const tip = panel.match(/function displayMetricTooltip\([^)]*\)\s*\{[\s\S]*?\n  \}/)?.[0] || "";
    expect(tip).toContain('text.split("\\n")[0]');
  });

  test("panel version matches manifest.json", () => {
    // pluginVersion is hardcoded so the panel needs no runtime file read; this
    // test is what keeps it honest when the manifest is bumped.
    const manifest = JSON.parse(readFileSync(new URL("../manifest.json", import.meta.url), "utf8"));
    const declared = panel.match(/readonly property string pluginVersion:\s*"([^"]+)"/)?.[1];
    expect(declared).toBe(manifest.version);
  });

  test("about row carries the version and both links", () => {
    expect(panel).toContain('readonly property string repoUrl: "https://github.com/nixfred/omarchy-server-status"');
    expect(panel).toContain('readonly property string authorUrl: "https://nixfred.com"');
    expect(panel).toContain("`${root.pluginName} ${root.pluginVersion}`");
    expect(panel).toContain('label: "GitHub"');
    expect(panel).toContain('label: "nixfred.com"');
  });

  test("about links open through the omarchy browser launcher", () => {
    const openUrl = panel.match(/function openUrl\([^)]*\)\s*\{[\s\S]*?\n  \}/)?.[0] || "";
    expect(openUrl).toContain('Quickshell.execDetached(["omarchy-launch-browser", String(url)])');
    expect(openUrl).toContain("root.close()");
  });

  test("contains no Hyprland workspace-switch launch path", () => {
    expect(panel).not.toContain("launchInNewWorkspace");
    expect(panel).not.toContain("workspaceProcess");
    expect(panel).not.toContain("pendingWorkspaceLaunch");
    expect(panel).not.toContain("Hyprland workspace switch failed");
  });

  test("guards deferred callbacks before invoking root methods", () => {
    const callbacks = [...panel.matchAll(/Qt\.callLater\(function\(\)\s*\{([\s\S]*?)\}\)/g)];
    expect(callbacks.length).toBeGreaterThan(0);
    for (const callback of callbacks) {
      if (/\broot\.[A-Za-z_$][\w$]*\s*\(/.test(callback[1])) {
        expect(callback[1]).toMatch(/if \(typeof root === "undefined" \|\| !root \|\| typeof root\.[A-Za-z_$][\w$]* !== "function"\) return/);
      }
    }
  });

  test("masks container names in privacy-mode notification bodies", () => {
    const describeProblems = panel.match(/function describeProblems\([\s\S]*?\n  \}/)?.[0] || "";
    expect(describeProblems).not.toContain("problems.push(list[c].name");
    expect(describeProblems).toContain("displayContainerName(list[c], list)");
  });

  test("masks collector errors in privacy-mode notification bodies", () => {
    const maybeNotify = panel.match(/function maybeNotify\([\s\S]*?\n  \}/)?.[0] || "";
    expect(maybeNotify).not.toContain("String(next.error");
    expect(maybeNotify).toContain("displayError(next.error)");
  });

  test("masks metric labels in privacy-mode notification bodies", () => {
    const describeProblems = panel.match(/function describeProblems\([\s\S]*?\n  \}/)?.[0] || "";
    expect(describeProblems).not.toContain("problems.push(rows[index].label");
    expect(describeProblems).toContain("displayMetricLabel(rows[index])");
  });
});

describe("Panel.qml alert policy", () => {
  const panel = readFileSync(new URL("../Panel.qml", import.meta.url), "utf8");

  test("forces bar and host indicators to repaint immediately after mute changes", () => {
    const barState = panel.match(/readonly property string barState:\s*\{[\s\S]*?\n  \}/)?.[0] || "";
    const toggleWarningMute = panel.match(/function toggleWarningMute\([^)]*\)\s*\{[\s\S]*?\n  \}/)?.[0] || "";
    const hostIndicatorState = panel.match(/function hostIndicatorState\([^)]*\)\s*\{[\s\S]*?\n  \}/)?.[0] || "";
    expect(barState).toContain("alertPolicyRevision");
    expect(toggleWarningMute).toContain("alertPolicyRevision += 1");
    expect(hostIndicatorState).toContain("alertPolicyRevision");
  });

  test("excludes muted metrics and containers before choosing the host state", () => {
    const summary = panel.match(/function summaryFor\([^)]*\)\s*\{[\s\S]*?\n  \}/)?.[0] || "";
    expect(summary).toMatch(/isWarningMuted\(hostAlias, rows\[index\]\.id\)\) continue[\s\S]*rows\[index\]\.state === "fail"/);
    expect(summary).toMatch(/isWarningMuted\(hostAlias, containerWarningId\(list\[c\]\)\)\) continue[\s\S]*state === "fail"/);
  });
});

describe("btrfs subvolume grouping", () => {
  // The reporter's layout: one disk, two partitions, four btrfs subvolumes
  // sharing the btrfs partition plus a separate boot partition.
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
    // 460099244032 / 500107862016 = 92% — over the 80% fail threshold. Before
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
    expect(quota[0].mount).toBe("/");
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
    expect(rows[0].usedBytes).toBe(100);
  });

  test("asks df for the source and type columns", () => {
    expect(REMOTE_SCRIPT).toContain("--output=source,fstype,target,size,used,avail");
  });
});

describe("bounded collection", () => {
  const streamOf = (...chunks: string[]) => new ReadableStream<Uint8Array>({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(new TextEncoder().encode(chunk));
      controller.close();
    },
  });

  test("returns the full text under the byte budget", async () => {
    const { readBounded } = await import("../backend/collect");
    const result = await readBounded(streamOf("hello ", "world"), 64, () => {});
    expect(result).toEqual({ text: "hello world", overflow: false });
  });

  test("kills the producer and reports overflow past the budget", async () => {
    const { readBounded } = await import("../backend/collect");
    let killed = false;
    const result = await readBounded(streamOf("a".repeat(10), "b".repeat(10)), 15, () => { killed = true; });
    expect(result.overflow).toBe(true);
    expect(result.text).toBe("");
    expect(killed).toBe(true);
  });

  test("caps container rows before they reach the panel", () => {
    const lines = Array.from({ length: 300 }, (_, i) =>
      `{"Names":"c${i}","Image":"img","Status":"Up","State":"running"}`);
    const sections = new Map<string, string[]>([
      ["DOCKER_PS", lines],
      ["DOCKER_STATS", []],
      ["DOCKER_INSPECT", []],
    ]);
    expect(parseContainers(sections).length).toBe(256);
  });

  test("caps tailnet devices before sorting", () => {
    const peers: Record<string, unknown> = {};
    for (let i = 0; i < 600; i += 1) peers[`p${i}`] = { ID: `id${i}`, HostName: `host${i}`, OS: "linux" };
    const snapshot = parseTailnetStatus(JSON.stringify({ BackendState: "Running", Peer: peers }));
    expect(snapshot.devices.length).toBe(512);
  });
});

describe("Panel.qml rendering sinks", () => {
  const panel = readFileSync(new URL("../Panel.qml", import.meta.url), "utf8");

  test("pins every Text element to PlainText", () => {
    const textCount = (panel.match(/\bText\s*\{/g) || []).length;
    const pinned = (panel.match(/textFormat:\s*Text\.PlainText/g) || []).length;
    expect(textCount).toBeGreaterThan(0);
    expect(pinned).toBe(textCount);
  });

  test("sanitizes remote-derived strings before shell-owned sinks", () => {
    expect(panel).toContain("function plain(");
    expect(panel).toMatch(/tooltipText: root\.plain\(`Tailscale Host Monitor/);
    expect(panel).toMatch(/"notify-send",[^\n]*"--", plain\(title\), plain\(body\)/);
    expect(panel).toContain('["wl-copy", "--", text]');
  });

  test("collects backend output through a byte budget, not StdioCollector", () => {
    expect(panel).not.toContain("StdioCollector");
    expect((panel.match(/splitMarker: ""/g) || []).length).toBe(4);
    expect(panel).toContain("maxBackendOutputChars");
  });
});
