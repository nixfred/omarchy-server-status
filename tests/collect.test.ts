import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { REMOTE_SCRIPT, parseContainers, parseHost, parseSize, splitSections } from "../backend/collect";
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
/               126692061184  21474836480 100086840320
/sys/firmware/efi/efivars 262144 212992 49152
/lhcos-data  281474976710656            0 281474976710656
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
