import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "ThemePalette.js" as ThemePalette

Panel {
  id: root

  moduleName: "io.github.nixfred.tailscale-host-monitor"
  ipcTarget: "io.github.nixfred.tailscale-host-monitor"

  // Kept in step with manifest.json by a test, rather than read from disk at
  // runtime: the panel should not gain a file read and a failure mode just to
  // print its own version.
  readonly property string pluginVersion: "0.8.0"
  readonly property string pluginName: "Tailscale Host Monitor"
  readonly property string repoUrl: "https://github.com/nixfred/omarchy-server-status"
  readonly property string authorUrl: "https://nixfred.com"

  property bool refreshing: false
  property string processOutput: ""
  property string processError: ""
  property string lastError: ""
  property string fetchHost: ""
  property var pendingHosts: []
  property var snapshotsByHost: ({})
  property var previousByHost: ({})
  property var notifiedKeyByHost: ({})
  property string activeHost: ""
  property bool tailnetRefreshing: false
  property double lastTailnetScanAtMs: 0
  property string tailnetOutput: ""
  property string tailnetProcessError: ""
  property string tailnetError: ""
  property string tailnetBackendState: "Unknown"
  property var tailnetDevices: []
  property bool pickerOpen: false
  property bool selectionReady: false
  property var selectedHosts: []
  property var mutedWarningsByHost: ({})
  property var mutedHostAlerts: []
  // QML cannot reliably observe reads nested inside plain JS maps. Bump this
  // whenever alert policy changes so bar/host-state bindings repaint now,
  // rather than waiting for the next telemetry snapshot.
  property int alertPolicyRevision: 0
  property var hostFetchFailedByHost: ({})
  property string copiedValue: ""
  property string draggedHost: ""
  property string draggedHostName: ""
  property string dragTargetHost: ""
  property bool dragAfterTarget: false
  property real dragPointerX: 0
  property real dragPointerY: 0
  property real dragGhostWidth: 0
  property real dragGhostHeight: 0
  property bool snapshotCacheReady: false
  property bool startupSelectionCaptured: false
  property var startupSelectedHosts: []
  property bool tailnetInitialScanComplete: false
  property bool startupSweepStarted: false
  property bool startupSweepComplete: false
  property var startupAwaitingHosts: []
  property int startupSweepTotal: 0
  property int startupSweepFinished: 0

  readonly property string sshHosts: String(setting("sshHosts", ""))
  readonly property int legacyRefreshIntervalSec: boundedInt(setting("refreshIntervalSec", 30), 10, 3600)
  readonly property string hostScanPreset: String(setting("hostScanPreset", "30 seconds"))
  readonly property int customHostScanSec: boundedInt(setting("customHostScanSec", legacyRefreshIntervalSec), 10, 3600)
  readonly property string tailnetScanPreset: String(setting("tailnetScanPreset", "5 minutes"))
  readonly property int customTailnetScanSec: boundedInt(setting("customTailnetScanSec", 300), 30, 3600)
  readonly property string allHostsScanPreset: String(setting("allHostsScanPreset", "5 minutes"))
  readonly property int customAllHostsScanSec: boundedInt(setting("customAllHostsScanSec", 300), 60, 86400)
  readonly property int hostScanIntervalSec: cadenceSeconds(hostScanPreset, customHostScanSec, legacyRefreshIntervalSec)
  readonly property int tailnetScanIntervalSec: cadenceSeconds(tailnetScanPreset, customTailnetScanSec, 300)
  readonly property int allHostsScanIntervalSec: cadenceSeconds(allHostsScanPreset, customAllHostsScanSec, 300)
  readonly property int panelWidth: boundedInt(setting("panelWidth", 1000), 320, 1200)
  readonly property bool privacyMode: String(setting("privacyMode", false)).toLowerCase() === "true"
  // Backend output is byte-capped at the producer (backend/collect.ts and
  // backend/tailnet.ts); these budgets are defense in depth so no
  // whole-stream collector remains in the shell process. .length counts
  // UTF-16 units, which is fine for a backstop.
  readonly property int maxBackendOutputChars: 2097152
  readonly property int maxBackendErrorChars: 16384
  readonly property string backendPath: decodeURIComponent(
    String(Qt.resolvedUrl("backend/server-status.ts")).replace(/^file:\/\//, ""))
  readonly property string selectionPath: Quickshell.env("HOME") + "/.config/omarchy/server-status.json"
  readonly property string themeColorsPath:
    Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"

  // Raw colors.toml contents, reloaded on theme change and on panel open.
  property var themeColorValues: ({})

  // Built-in traffic lights, used when a theme's own palette cannot carry the
  // meaning. See ThemePalette.js for what disqualifies one.
  readonly property var fallbackStatusColors: ({
    pass: "#69c58a",
    warn: "#e5b45d",
    fail: "#e66a6a"
  })

  readonly property var statusColors: ThemePalette.statusPalette(
    themeColorValues, fallbackStatusColors, String(Color.background))
  readonly property string snapshotCachePath: {
    var configured = String(Quickshell.env("XDG_CACHE_HOME") || "").trim()
    var directory = configured !== "" ? configured : Quickshell.env("HOME") + "/.cache"
    return directory + "/omarchy-server-status-snapshots.json"
  }

  readonly property var legacyHostList: sshHosts.split(":").map(function(entry) {
    return entry.trim()
  }).filter(function(entry) { return entry !== "" })
  readonly property var hostList: selectionReady ? selectedHosts : legacyHostList
  readonly property var monitoredDevices: hostList.map(function(host) {
    return root.deviceForTarget(host)
  }).filter(function(device) { return device !== null })
  readonly property var activeDevice: deviceForTarget(activeHost)
  readonly property var snapshot: snapshotsByHost[activeHost] || ({ host: null, containers: [], error: "" })
  readonly property var hostInfo: snapshot.host || null
  readonly property var containers: snapshot.containers instanceof Array ? snapshot.containers : []
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string barState: {
    var observedAlertPolicyRevision = alertPolicyRevision
    if (!startupSweepComplete) return "pass"
    var state = worstState()
    if (state === "fail") return "fail"
    if (state === "pass") return "pass"
    return "warn"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: {
    activeHost = hostList.length > 0 ? hostList[0] : ""
  }

  function normalizedHost(value) {
    var host = String(value || "").trim().toLowerCase()
    var at = host.lastIndexOf("@")
    if (at >= 0) host = host.substring(at + 1)
    return host.replace(/\.+$/, "")
  }

  function deviceAliases(device) {
    if (!device) return []
    var values = [device.name, device.hostName, device.dnsName, device.sshHost]
    var dnsShort = normalizedHost(device.dnsName).split(".")[0]
    if (dnsShort !== "") values.push(dnsShort)
    return values.map(normalizedHost).filter(function(value, index, all) {
      return value !== "" && all.indexOf(value) === index
    })
  }

  function deviceMatchesHost(device, host) {
    var normalized = normalizedHost(host)
    if (normalized === "") return false
    var aliases = deviceAliases(device)
    if (aliases.indexOf(normalized) >= 0) return true
    var shortName = normalized.split(".")[0]
    return aliases.indexOf(shortName) >= 0
  }

  function deviceForTarget(host) {
    for (var index = 0; index < tailnetDevices.length; index += 1) {
      if (deviceMatchesHost(tailnetDevices[index], host)) return tailnetDevices[index]
    }
    return null
  }

  function monitoredTarget(device) {
    for (var index = 0; index < hostList.length; index += 1) {
      if (deviceMatchesHost(device, hostList[index])) return hostList[index]
    }
    return ""
  }

  function configuredTarget(device) {
    var monitored = monitoredTarget(device)
    if (monitored !== "") return monitored
    return device ? String(device.sshHost || device.name || "") : ""
  }

  function isMonitored(device) {
    return monitoredTarget(device) !== ""
  }

  function saveSelection(hosts) {
    var clean = hosts.map(function(host) { return String(host || "").trim() })
      .filter(function(host, index, all) { return host !== "" && all.indexOf(host) === index })
    selectedHosts = clean
    selectionReady = true
    writeSelection()
  }

  function sameHostList(left, right) {
    if (!(left instanceof Array) || !(right instanceof Array) || left.length !== right.length) return false
    for (var index = 0; index < left.length; index += 1)
      if (String(left[index]) !== String(right[index])) return false
    return true
  }

  function writeSelection() {
    if (!selectionReady) return
    selectionFile.setText(JSON.stringify({
      version: 1,
      monitoredHosts: selectedHosts,
      activeHost: activeHost,
      mutedHosts: mutedHostAlerts,
      mutedWarnings: mutedWarningsByHost
    }, null, 2) + "\n")
  }

  function loadSelection(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      if (!parsed || parsed.version !== 1 || !(parsed.monitoredHosts instanceof Array))
        throw new Error("Unsupported selection file")
      var loadedHosts = parsed.monitoredHosts.map(String).filter(function(host) { return host.trim() !== "" })
      if (!startupSelectionCaptured) {
        startupSelectedHosts = loadedHosts.slice()
        startupSelectionCaptured = true
      }
      if (!sameHostList(selectedHosts, loadedHosts)) selectedHosts = loadedHosts
      var loadedMutes = ({})
      if (parsed.mutedWarnings && typeof parsed.mutedWarnings === "object") {
        var muteHosts = Object.keys(parsed.mutedWarnings)
        for (var muteIndex = 0; muteIndex < muteHosts.length; muteIndex += 1) {
          var muteHost = String(muteHosts[muteIndex])
          var muteIds = parsed.mutedWarnings[muteHost]
          if (muteIds instanceof Array)
            loadedMutes[muteHost] = muteIds.map(String).filter(function(id, index, all) {
              return id !== "" && all.indexOf(id) === index
            })
        }
      }
      mutedWarningsByHost = loadedMutes
      mutedHostAlerts = parsed.mutedHosts instanceof Array
        ? parsed.mutedHosts.map(String).filter(function(host, index, all) {
            return host !== "" && all.indexOf(host) === index
          })
        : []
      alertPolicyRevision += 1
      var savedActive = String(parsed.activeHost || "")
      activeHost = loadedHosts.indexOf(savedActive) >= 0
        ? savedActive
        : (loadedHosts.length > 0 ? loadedHosts[0] : "")
    } catch (error) {
      selectedHosts = legacyHostList.slice()
      mutedHostAlerts = []
      alertPolicyRevision += 1
      if (!startupSelectionCaptured) {
        startupSelectedHosts = selectedHosts.slice()
        startupSelectionCaptured = true
      }
      activeHost = selectedHosts.length > 0 ? selectedHosts[0] : ""
    }
    selectionReady = true
    maybeStartStartupSweep()
    if (opened) Qt.callLater(function() {
      if (typeof root === "undefined" || !root || typeof root.refreshSelectedHost !== "function") return
      root.refreshSelectedHost()
    })
  }

  function loadSnapshotCache(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      if (!parsed || parsed.version !== 1 || !parsed.snapshots || typeof parsed.snapshots !== "object")
        throw new Error("Unsupported snapshot cache")
      var loaded = ({})
      var hosts = Object.keys(parsed.snapshots)
      for (var index = 0; index < hosts.length; index += 1) {
        var hostAlias = String(hosts[index])
        var snapshotValue = parsed.snapshots[hostAlias]
        if (snapshotValue && snapshotValue.schemaVersion === 1)
          loaded[hostAlias] = snapshotValue
      }
      // A live response can beat the disk read during shell startup. Current
      // in-memory values win so an older cache never rolls fresh data back.
      snapshotsByHost = Object.assign({}, loaded, snapshotsByHost)
    } catch (error) {
      // Cache corruption is non-fatal. The next successful host response
      // replaces the file with a clean cache.
    }
    snapshotCacheReady = true
    if (Object.keys(snapshotsByHost).length > 0) snapshotCacheWriteTimer.restart()
  }

  function writeSnapshotCache() {
    if (!snapshotCacheReady) return
    var kept = ({})
    var hosts = Object.keys(snapshotsByHost)
    for (var index = 0; index < hosts.length; index += 1) {
      var hostAlias = String(hosts[index])
      var value = snapshotsByHost[hostAlias]
      if (value && value.schemaVersion === 1) kept[hostAlias] = value
    }
    snapshotCacheFile.setText(JSON.stringify({
      version: 1,
      savedAt: new Date().toISOString(),
      snapshots: kept
    }, null, 2) + "\n")
    snapshotCachePermissionsTimer.restart()
  }

  function scheduleSnapshotCacheWrite() {
    if (snapshotCacheReady) snapshotCacheWriteTimer.restart()
  }

  function snapshotIsFresh(hostAlias, maxAgeSec) {
    var value = snapshotsByHost[String(hostAlias || "")]
    if (!value || !value.generatedAt) return false
    var generatedAtMs = new Date(value.generatedAt).getTime()
    if (!isFinite(generatedAtMs)) return false
    return Date.now() - generatedAtMs < Math.max(1, Number(maxAgeSec) || 1) * 1000
  }

  function toggleMonitored(device) {
    if (!device) return
    var next = hostList.filter(function(host) { return !deviceMatchesHost(device, host) })
    if (next.length === hostList.length) next.push(String(device.sshHost || device.name))
    saveSelection(next)
    if (isMonitored(device)) {
      selectHost(configuredTarget(device))
    } else if (deviceMatchesHost(device, activeHost)) {
      selectHost(next.length > 0 ? next[0] : "")
    }
  }

  function moveHostRelative(sourceHost, targetHost, afterTarget) {
    var source = String(sourceHost || "")
    var target = String(targetHost || "")
    if (source === "" || target === "" || source === target) return
    var next = hostList.slice()
    var sourceIndex = next.indexOf(source)
    if (sourceIndex < 0 || next.indexOf(target) < 0) return
    var moved = next.splice(sourceIndex, 1)[0]
    var targetIndex = next.indexOf(target)
    next.splice(targetIndex + (afterTarget ? 1 : 0), 0, moved)
    if (!sameHostList(next, hostList)) saveSelection(next)
  }

  function updateHostDrag(sourceHost, flowX, flowY) {
    draggedHost = String(sourceHost || "")
    dragPointerX = flowX
    dragPointerY = flowY
    if (flowX < -Style.space(16) || flowY < -Style.space(16)
        || flowX > monitoredFlow.width + Style.space(16)
        || flowY > monitoredFlow.height + Style.space(16)) {
      dragTargetHost = ""
      return
    }
    var nearestHost = ""
    var nearestAfter = false
    var nearestDistance = Number.POSITIVE_INFINITY
    for (var index = 0; index < monitoredRepeater.count; index += 1) {
      var item = monitoredRepeater.itemAt(index)
      if (!item || item.target === draggedHost) continue
      var origin = item.mapToItem(monitoredFlow, 0, 0)
      var centerX = origin.x + item.width / 2
      var centerY = origin.y + item.height / 2
      var dx = flowX - centerX
      var dy = flowY - centerY
      var distance = dx * dx + dy * dy
      if (distance < nearestDistance) {
        nearestDistance = distance
        nearestHost = item.target
        nearestAfter = Math.abs(dy) <= item.height ? flowX >= centerX : flowY >= centerY
      }
    }
    dragTargetHost = nearestHost
    dragAfterTarget = nearestAfter
  }

  function finishHostDrag() {
    var source = draggedHost
    var target = dragTargetHost
    var after = dragAfterTarget
    draggedHost = ""
    draggedHostName = ""
    dragTargetHost = ""
    dragAfterTarget = false
    if (source !== "" && target !== "") moveHostRelative(source, target, after)
  }

  function cancelHostDrag() {
    draggedHost = ""
    draggedHostName = ""
    dragTargetHost = ""
    dragAfterTarget = false
  }

  function warningIds(hostAlias) {
    var ids = mutedWarningsByHost[String(hostAlias || "")]
    return ids instanceof Array ? ids : []
  }

  function isWarningMuted(hostAlias, warningId) {
    var ids = warningIds(hostAlias)
    var id = String(warningId || "")
    if (ids.indexOf(id) >= 0) return true
    // Container warning ids gained a runtime segment when Docker and Podman
    // became collectable together ("container-docker-web-1" rather than
    // "container-web-1"). Mutes recorded before that still name the old id, and
    // a mute silently reverting is worse than a stale entry: someone muted that
    // card on purpose. Accept the legacy form for docker, which is what every
    // pre-existing mute was.
    var legacy = legacyWarningId(id)
    return legacy !== "" && ids.indexOf(legacy) >= 0
  }

  function legacyWarningId(warningId) {
    var id = String(warningId || "")
    return id.indexOf("container-docker-") === 0
      ? "container-" + id.slice("container-docker-".length)
      : ""
  }

  function isHostMuted(hostAlias) {
    return mutedHostAlerts.indexOf(String(hostAlias || "")) >= 0
  }

  function toggleHostMute(hostAlias) {
    var host = String(hostAlias || "")
    if (host === "") return
    var next = mutedHostAlerts.slice()
    var index = next.indexOf(host)
    if (index >= 0) next.splice(index, 1)
    else next.push(host)
    mutedHostAlerts = next
    alertPolicyRevision += 1
    writeSelection()
  }

  function setHostFetchFailed(hostAlias, failed) {
    var host = String(hostAlias || "")
    if (host === "") return
    var next = Object.assign({}, hostFetchFailedByHost)
    if (failed) next[host] = true
    else delete next[host]
    hostFetchFailedByHost = next
  }

  function toggleWarningMute(hostAlias, warningId) {
    var host = String(hostAlias || "")
    var id = String(warningId || "")
    if (host === "" || id === "") return
    var nextMap = Object.assign({}, mutedWarningsByHost)
    var nextIds = warningIds(host).slice()
    var index = nextIds.indexOf(id)
    // Unmuting must also clear a legacy entry, or the card would re-mute itself
    // on the next read through the compatibility path above.
    var legacy = legacyWarningId(id)
    var legacyIndex = legacy !== "" ? nextIds.indexOf(legacy) : -1
    if (index >= 0 || legacyIndex >= 0) {
      if (index >= 0) nextIds.splice(index, 1)
      legacyIndex = legacy !== "" ? nextIds.indexOf(legacy) : -1
      if (legacyIndex >= 0) nextIds.splice(legacyIndex, 1)
    } else nextIds.push(id)
    if (nextIds.length > 0) nextMap[host] = nextIds
    else delete nextMap[host]
    mutedWarningsByHost = nextMap
    alertPolicyRevision += 1
    writeSelection()
  }

  function containerWarningId(container) {
    var runtime = String(container && container.runtime || "docker")
    return "container-" + runtime + "-" + String(container && container.name || "")
  }

  function copyText(value) {
    var text = String(value || "")
    if (text === "") return
    Quickshell.execDetached(["wl-copy", "--", text])
    copiedValue = text
    copyReset.restart()
  }

  // Tooltips, PanelHero and notifications are rendered by the shell with
  // Text.AutoText; this plugin cannot pin the format there. Remote-derived
  // strings (hostnames, DNS names, container names) must lose markup and
  // control characters and get a length cap before crossing that boundary.
  function plain(value) {
    return String(value || "")
      .replace(/[<>&]/g, " ")
      .replace(/[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "")
      .slice(0, 200)
  }

  function osIcon(os) {
    var value = String(os || "").toLowerCase()
    if (value === "linux") return "󰌽"
    if (value === "windows") return "󰖳"
    if (value === "macos" || value === "darwin" || value === "ios") return ""
    if (value === "android") return "󰀲"
    return "󰟀"
  }

  function privateHostNumber(hostAlias, device) {
    var index = hostList.indexOf(String(hostAlias || ""))
    if (index < 0 && device) index = tailnetDevices.indexOf(device)
    return String(Math.max(0, index) + 1).padStart(2, "0")
  }

  function displayHostName(hostAlias, actual, device) {
    if (!privacyMode) return String(actual || hostAlias || "Unknown")
    return "Host " + privateHostNumber(hostAlias, device)
  }

  function displayDns(hostAlias, actual, device) {
    if (!privacyMode) return String(actual || "")
    return "host-" + privateHostNumber(hostAlias, device) + ".tailnet.example"
  }

  function displayIp(actual) {
    return privacyMode && String(actual || "") !== "" ? "100.x.x.x" : String(actual || "")
  }

  function displayMetricLabel(metric) {
    var label = String(metric && metric.label || "")
    if (privacyMode && String(metric && metric.id || "").indexOf("disk-") === 0) {
      var grouped = label.match(/ \+\d+$/)
      return "Disk volume" + (grouped ? grouped[0] : "")
    }
    return label
  }

  function displayMetricDetail(metric) {
    var detail = String(metric && metric.detail || "")
    if (!privacyMode) return detail
    var id = String(metric && metric.id || "")
    if (id === "uptime") return detail.split(" · ")[0]
    if (id === "tailscale-ip") return "100.x.x.x"
    if (id === "magic-dns") return "host.tailnet.example"
    if (id === "tailscale-tags") return "Private tags"
    return detail
  }

  function displayContainerName(container, sourceContainers) {
    if (!privacyMode) return String(container && container.name || "")
    var list = sourceContainers instanceof Array ? sourceContainers : containers
    var index = list.indexOf(container)
    return "Container " + String(Math.max(0, index) + 1).padStart(2, "0")
  }

  function displayError(value) {
    if (!privacyMode) return String(value || "")
    return String(value || "") !== "" ? "Host telemetry is currently unavailable." : ""
  }

  function primaryIp(device) {
    if (!device || !(device.ips instanceof Array)) return ""
    for (var index = 0; index < device.ips.length; index += 1)
      if (String(device.ips[index]).indexOf(":") < 0) return String(device.ips[index])
    return device.ips.length > 0 ? String(device.ips[0]) : ""
  }

  function lastSeenText(device) {
    if (!device) return ""
    if (device.online) return "Online now"
    if (!device.lastSeen) return "Offline"
    return "Last seen " + new Date(device.lastSeen).toLocaleString()
  }

  function boundedInt(value, minimum, maximum) {
    var parsed = parseInt(String(value), 10)
    if (!isFinite(parsed)) parsed = minimum
    return Math.max(minimum, Math.min(maximum, parsed))
  }

  function cadenceSeconds(preset, customSeconds, fallback) {
    var value = String(preset || "")
    if (value === "15 seconds") return 15
    if (value === "30 seconds") return 30
    if (value === "1 minute") return 60
    if (value === "5 minutes") return 300
    if (value === "15 minutes") return 900
    if (value === "30 minutes") return 1800
    if (value === "1 hour") return 3600
    if (value === "Custom") return Number(customSeconds) || fallback
    return fallback
  }

  function cadenceText(seconds) {
    var value = Number(seconds) || 0
    if (value >= 3600 && value % 3600 === 0) return (value / 3600) + "h"
    if (value >= 60 && value % 60 === 0) return (value / 60) + "m"
    return value + "s"
  }

  function stateColor(state) {
    if (state === "pass") return statusColors.pass
    if (state === "running") return Color.accent
    if (state === "warn") return statusColors.warn
    if (state === "fail") return statusColors.fail
    if (state === "muted") return root.dim
    return root.dim
  }

  function barStateText() {
    if (!startupSweepComplete) return startupProgressText()
    if (barState === "fail") return "Critical"
    if (barState === "warn") return "Warning / awaiting data"
    return "Healthy"
  }

  function stateGlyph(state) {
    if (state === "pass") return "✓"
    if (state === "running") return "↻"
    if (state === "warn") return "!"
    if (state === "fail") return "×"
    if (state === "idle") return "·"
    if (state === "muted") return "−"
    return "?"
  }

  function formatBytes(bytes) {
    var value = Number(bytes) || 0
    var units = ["B", "KiB", "MiB", "GiB", "TiB"]
    var unit = 0
    while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit += 1 }
    return (value >= 10 ? Math.round(value) : Math.round(value * 10) / 10) + " " + units[unit]
  }

  function formatUptime(seconds) {
    var total = Number(seconds) || 0
    var days = Math.floor(total / 86400)
    var hours = Math.floor((total % 86400) / 3600)
    return days > 0 ? days + "d " + hours + "h" : hours + "h " + Math.floor((total % 3600) / 60) + "m"
  }

  // Thresholds from the capacity plan: warn at mem>75% / disk>70% /
  // load-per-core>0.7, red at mem>85% / disk>80% / load-per-core>1.0.
  function levelFor(fraction, warnAt, failAt) {
    if (!isFinite(fraction)) return "unknown"
    if (fraction >= failAt) return "fail"
    if (fraction >= warnAt) return "warn"
    return "pass"
  }

  function sharedMountsOf(disk) {
    return disk && disk.sharedMounts instanceof Array ? disk.sharedMounts : []
  }

  // The backend reports one card per filesystem, not per mount point, because
  // btrfs subvolumes and bind mounts share an allocation pool and would
  // otherwise raise the same warning several times.
  //
  // The count goes in the LABEL, not the detail. The detail line is a single
  // elided row on a quarter-width tile, so anything appended there is cut off
  // before it can be read — which made a grouped card indistinguishable from a
  // host that had simply lost three filesystems. The label is short, bold, and
  // drawn first, so "Disk / +3" survives.
  function diskShareSuffix(disk) {
    var fstype = String(disk && disk.fstype || "")
    return sharedMountsOf(disk).length > 0 && fstype !== "" ? " · " + fstype : ""
  }

  // Full membership lives in the hover tooltip, where there is room for it.
  function diskTooltip(disk) {
    var shared = sharedMountsOf(disk)
    if (shared.length < 1) return ""
    var fstype = String(disk && disk.fstype || "")
    var mounts = [String(disk.mount)].concat(shared)
    // Mount paths and the filesystem type come from the remote host and land in
    // PanelToolTip, a shell-owned component this plugin cannot pin to
    // PlainText. Sanitize each entry separately: plain() strips C0 controls,
    // newline included, so cleaning the joined string would flatten the list.
    return (fstype !== "" ? plain(fstype) + " · " : "") + mounts.length
      + " volumes on one filesystem\n" + mounts.map(plain).join("\n")
  }

  function displayMetricTooltip(metric) {
    var text = String(metric && metric.tooltip || "")
    if (text === "" || !privacyMode) return text
    // Mount paths name real directories. Keep the summary line, drop the list.
    return String(metric && metric.id || "").indexOf("disk-") === 0
      ? text.split("\n")[0] : text
  }

  function hostRows(info, previous, elapsedSec) {
    if (!info) return []
    var rows = []
    // Judge the 5-minute average, not load1. Opening the SSH session for a
    // refresh briefly spikes the remote run queue itself: PAM session hooks
    // and /etc/update-motd.d scripts (fail2ban, podman, incus, log greps) run
    // on connect, concurrently with this plugin's own docker/podman queries. A load1
    // sample read inside that burst reports a critical alert on a host that is
    // sitting idle, immediately followed by a recovery notification.
    //
    // A consecutive-sample debounce would not catch this: the burst is caused
    // by our own connection, so it recurs on every single refresh rather than
    // flapping randomly. A longer averaging window is what actually rejects a
    // two-second spike, and sustained load — the thing worth alerting on —
    // still reaches load5 within a couple of scans.
    //
    // Diagnosed by @kanthi with sar -q evidence from a 4-vCPU Azure VM.
    var loadPerCore = info.cpuCount > 0 ? info.load5 / info.cpuCount : 0
    rows.push({
      id: "cpu",
      label: "CPU load",
      state: levelFor(loadPerCore, 0.7, 1.0),
      detail: "1m " + info.load1.toFixed(2) + " · 5m " + info.load5.toFixed(2)
        + " · 15m " + info.load15.toFixed(2) + " · " + info.cpuCount + " cores",
      value: Math.min(1, loadPerCore)
    })
    var memFrac = info.memTotalBytes > 0 ? (info.memTotalBytes - info.memAvailableBytes) / info.memTotalBytes : 0
    rows.push({
      id: "mem",
      label: "Memory",
      state: levelFor(memFrac, 0.75, 0.85),
      detail: formatBytes(info.memTotalBytes - info.memAvailableBytes) + " / " + formatBytes(info.memTotalBytes)
        + (info.swapUsedBytes > 0 ? " · swap " + formatBytes(info.swapUsedBytes) : ""),
      value: memFrac
    })
    for (var index = 0; index < info.disks.length; index += 1) {
      var disk = info.disks[index]
      var frac = disk.totalBytes > 0 ? disk.usedBytes / disk.totalBytes : 0
      var sharedCount = sharedMountsOf(disk).length
      rows.push({
        id: "disk-" + disk.mount,
        label: "Disk " + disk.mount + (sharedCount > 0 ? " +" + sharedCount : ""),
        state: levelFor(frac, 0.7, 0.8),
        detail: formatBytes(disk.usedBytes) + " / " + formatBytes(disk.totalBytes) + diskShareSuffix(disk),
        value: frac,
        tooltip: diskTooltip(disk)
      })
    }
    var netDetail = "rx " + formatBytes(info.netRxBytes) + " · tx " + formatBytes(info.netTxBytes) + " total"
    if (previous && previous.host && elapsedSec > 0) {
      var rx = (info.netRxBytes - previous.host.netRxBytes) / elapsedSec
      var tx = (info.netTxBytes - previous.host.netTxBytes) / elapsedSec
      if (rx >= 0 && tx >= 0)
        netDetail = "↓ " + formatBytes(rx) + "/s · ↑ " + formatBytes(tx) + "/s"
    }
    rows.push({ id: "net", label: "Network", state: "pass", detail: netDetail, value: 0 })
    rows.push({
      id: "uptime",
      label: "Uptime",
      state: "pass",
      detail: formatUptime(info.uptimeSeconds) + " · " + info.hostname,
      value: 0
    })
    return rows
  }

  function tailnetRows(device) {
    if (!device) return []
    var rows = [{
      id: "tailscale-status",
      label: "Tailscale",
      state: device.online ? "pass" : "fail",
      detail: lastSeenText(device),
      value: 0
    }, {
      id: "device-type",
      label: "Device type",
      state: "pass",
      detail: device.kind + " · " + String(device.os || "unknown"),
      value: 0
    }]
    var ip = primaryIp(device)
    if (ip !== "") rows.push({ id: "tailscale-ip", label: "Tailscale IP", state: "pass", detail: ip, value: 0 })
    if (device.dnsName) rows.push({ id: "magic-dns", label: "MagicDNS", state: "pass", detail: device.dnsName, value: 0 })
    if (device.tags instanceof Array && device.tags.length > 0)
      rows.push({ id: "tailscale-tags", label: "Tags", state: "pass", detail: device.tags.join(", "), value: 0 })
    return rows
  }

  function containerState(container) {
    if (container.oomKilled) return "fail"
    if (container.state === "running") {
      if (container.health === "unhealthy") return "fail"
      if (container.health === "starting") return "running"
      return "pass"
    }
    if (container.state === "restarting") return "fail"
    if (container.state === "paused") return "warn"
    if (container.state === "exited" || container.state === "dead") return "warn"
    return "unknown"
  }

  function containerDetail(container) {
    var parts = []
    if (container.runtime) parts.push(String(container.runtime))
    if (container.cpuPercent !== null) parts.push("cpu " + container.cpuPercent.toFixed(1) + "%")
    if (container.memPercent !== null)
      parts.push("mem " + formatBytes(container.memUsageBytes) + " (" + container.memPercent.toFixed(0) + "%)")
    if (container.restarts > 0) parts.push(container.restarts + " restarts")
    if (container.health !== "none") parts.push(container.health)
    else parts.push(container.state)
    return parts.join(" · ")
  }

  function workloadHeader() {
    var list = root.containers
    var kvm = 0
    var other = 0
    for (var i = 0; i < list.length; i += 1) {
      if (String(list[i] && list[i].runtime || "") === "kvm") kvm += 1
      else other += 1
    }
    if (kvm > 0 && other > 0) return "CONTAINERS · " + other + " · VMS · " + kvm
    if (kvm > 0) return "VMS · " + kvm
    return "CONTAINERS · " + list.length
  }

  function summaryFor(hostAlias) {
    if (isHostMuted(hostAlias)) return "pass"
    var device = deviceForTarget(hostAlias)
    if (!device) return tailnetInitialScanComplete ? "fail" : "unknown"
    if (device && !device.online) return "fail"
    if (device && !device.supportsMetrics) return "pass"
    if (hostFetchFailedByHost[hostAlias] === true) return "fail"
    var snap = snapshotsByHost[hostAlias]
    if (!snap) return "unknown"
    if (snap.error) return "fail"
    var worst = "pass"
    var rows = hostRows(snap.host, null, 0)
    for (var index = 0; index < rows.length; index += 1) {
      if (isWarningMuted(hostAlias, rows[index].id)) continue
      if (rows[index].state === "fail") return "fail"
      if (rows[index].state === "warn") worst = "warn"
    }
    var list = snap.containers instanceof Array ? snap.containers : []
    for (var c = 0; c < list.length; c += 1) {
      if (isWarningMuted(hostAlias, containerWarningId(list[c]))) continue
      var state = containerState(list[c])
      if (state === "fail") return "fail"
      if (state === "warn") worst = "warn"
    }
    return worst
  }

  function worstState() {
    if (tailnetError !== "") return "unknown"
    var order = ["fail", "warn", "unknown", "pass"]
    var worst = "unknown"
    var rank = order.length
    var sawAny = false
    var targets = hostList
    for (var index = 0; index < targets.length; index += 1) {
      sawAny = true
      var state = summaryFor(targets[index])
      var current = order.indexOf(state)
      if (current >= 0 && current < rank) { rank = current; worst = order[current] }
    }
    return sawAny ? worst : "unknown"
  }

  function hostIndicatorState(hostAlias) {
    var observedAlertPolicyRevision = alertPolicyRevision
    return startupSweepComplete ? summaryFor(hostAlias) : "pass"
  }

  function maybeStartStartupSweep() {
    if (startupSweepStarted || !selectionReady || !tailnetInitialScanComplete) return
    startupSweepStarted = true
    startupSweepTotal = startupSelectedHosts.length
    var targets = []
    for (var index = 0; index < startupSelectedHosts.length; index += 1) {
      var hostAlias = String(startupSelectedHosts[index] || "")
      var device = deviceForTarget(hostAlias)
      if (device && device.online && device.supportsMetrics) targets.push(hostAlias)
    }
    startupAwaitingHosts = targets.slice()
    startupSweepFinished = Math.max(0, startupSweepTotal - targets.length)
    if (targets.length === 0) {
      startupSweepComplete = true
      return
    }
    enqueue(targets)
  }

  function finishStartupHost(hostAlias) {
    var waiting = startupAwaitingHosts.slice()
    var index = waiting.indexOf(String(hostAlias || ""))
    if (index < 0) return
    waiting.splice(index, 1)
    startupAwaitingHosts = waiting
    startupSweepFinished = Math.min(startupSweepTotal, startupSweepFinished + 1)
    if (waiting.length === 0) startupSweepComplete = true
  }

  function startupProgressText() {
    if (startupSweepComplete) return "Startup scan complete"
    if (!startupSweepStarted) return "Preparing startup scan"
    return `Startup scan ${startupSweepFinished}/${startupSweepTotal}`
  }

  function selectHost(hostAlias) {
    if (activeHost === hostAlias) return
    activeHost = hostAlias
    writeSelection()
    refreshSelectedHost(false)
  }

  function selectDevice(device) {
    if (!device || !isMonitored(device)) return
    selectHost(configuredTarget(device))
  }

  function metricTargets() {
    if (tailnetDevices.length === 0) return []
    var targets = []
    for (var index = 0; index < monitoredDevices.length; index += 1) {
      var device = monitoredDevices[index]
      if (device.online && device.supportsMetrics) targets.push(configuredTarget(device))
    }
    return targets
  }

  function refresh() {
    refreshTailnet()
    refreshSelectedHost(true)
  }

  function refreshSelectedHost(force) {
    if (!startupSweepComplete) return
    var device = activeDevice
    if (!device || !device.online || !device.supportsMetrics) return
    if (!force && snapshotIsFresh(activeHost, hostScanIntervalSec)) return
    enqueue([activeHost])
  }

  function refreshAll() {
    refreshTailnet()
    refreshAllHosts()
  }

  function refreshAllHosts() {
    if (!startupSweepComplete) return
    enqueue(metricTargets())
  }

  function refreshTailnetIfStale() {
    if (Date.now() - lastTailnetScanAtMs >= tailnetScanIntervalSec * 1000)
      refreshTailnet()
  }

  function refreshTailnet() {
    if (tailnetProcess.running) return
    tailnetOutput = ""
    tailnetProcessError = ""
    tailnetRefreshing = true
    tailnetProcess.command = ["bun", "run", backendPath, "tailnet", "--compact"]
    tailnetProcess.running = true
  }

  function storeTailnet(raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      if (!parsed || parsed.schemaVersion !== 1 || !(parsed.devices instanceof Array))
        throw new Error("Unsupported tailnet snapshot")
      tailnetBackendState = String(parsed.backendState || "Unknown")
      tailnetError = String(parsed.error || "")
      tailnetDevices = parsed.devices
      lastTailnetScanAtMs = Date.now()
      tailnetInitialScanComplete = true
      if (!activeDevice || !isMonitored(activeDevice))
        selectHost(monitoredDevices.length > 0 ? configuredTarget(monitoredDevices[0]) : "")
      if (opened && activeDevice && activeDevice.online && activeDevice.supportsMetrics)
        refreshSelectedHost(false)
      maybeStartStartupSweep()
    } catch (error) {
      tailnetError = "Could not read Tailscale network: " + String(error)
    }
  }

  function enqueue(hosts) {
    var queue = pendingHosts.slice()
    for (var index = 0; index < hosts.length; index += 1) {
      var hostAlias = String(hosts[index] || "")
      if (hostAlias !== "" && queue.indexOf(hostAlias) < 0 && hostAlias !== fetchHost)
        queue.push(hostAlias)
    }
    pendingHosts = queue
    pump()
  }

  function pump() {
    if (statusProcess.running || startupPaceTimer.running) return
    if (pendingHosts.length === 0) { refreshing = false; return }
    var queue = pendingHosts.slice()
    fetchHost = queue.shift()
    pendingHosts = queue
    processOutput = ""
    processError = ""
    refreshing = true
    statusProcess.command = ["bun", "run", backendPath, "status", "--host", fetchHost, "--compact"]
    statusProcess.running = true
  }

  function storeSnapshot(hostAlias, raw) {
    try {
      var parsed = JSON.parse(String(raw || ""))
      if (!parsed || parsed.schemaVersion !== 1) throw new Error("Unsupported snapshot")
      setHostFetchFailed(hostAlias, String(parsed.error || "") !== "")
      var previous = snapshotsByHost[hostAlias]
      maybeNotify(hostAlias, previous, parsed)
      var previousMap = Object.assign({}, previousByHost)
      if (previous) previousMap[hostAlias] = previous
      previousByHost = previousMap
      var merged = Object.assign({}, snapshotsByHost)
      merged[hostAlias] = parsed
      snapshotsByHost = merged
      scheduleSnapshotCacheWrite()
      if (hostAlias === activeHost) lastError = parsed.error || ""
    } catch (error) {
      if (hostAlias === activeHost)
        lastError = "Could not read server status: " + String(error)
    }
  }

  function maybeNotify(hostAlias, previous, next) {
    if (!startupSweepComplete) return
    if (isHostMuted(hostAlias)) return
    if (!previous) return
    var prevSummary = summaryForSnapshot(previous, hostAlias)
    var nextSummary = summaryForSnapshot(next, hostAlias)
    if (prevSummary === nextSummary) return
    var device = deviceForTarget(hostAlias)
    var notificationHost = displayHostName(hostAlias, device ? device.name : hostAlias, device)
    var title = ""
    var urgency = "normal"
    if (nextSummary === "fail") {
      title = "Server alert · " + notificationHost
      urgency = "critical"
    } else if (nextSummary === "warn" && prevSummary === "pass") {
      title = "Server warning · " + notificationHost
    } else if (nextSummary === "pass" && (prevSummary === "fail" || prevSummary === "warn")) {
      title = "Server recovered · " + notificationHost
    } else if (nextSummary === "unknown" && prevSummary !== "unknown") {
      title = "Server unreachable · " + notificationHost
      urgency = "critical"
    } else {
      return
    }
    var body = describeProblems(next, hostAlias)
      || displayError(next.error)
      || "All metrics back within thresholds"
    var key = hostAlias + "|" + nextSummary + "|" + body
    if (notifiedKeyByHost[hostAlias] === key) return
    var keys = Object.assign({}, notifiedKeyByHost)
    keys[hostAlias] = key
    notifiedKeyByHost = keys
    Quickshell.execDetached(["notify-send", "-a", "Server Status", "-u", urgency, "--", plain(title), plain(body)])
  }

  function summaryForSnapshot(snap, hostAlias) {
    if (!snap) return "unknown"
    if (snap.error) return "fail"
    var worst = "pass"
    var rows = hostRows(snap.host, null, 0)
    for (var index = 0; index < rows.length; index += 1) {
      if (isWarningMuted(hostAlias, rows[index].id)) continue
      if (rows[index].state === "fail") return "fail"
      if (rows[index].state === "warn") worst = "warn"
    }
    var list = snap.containers instanceof Array ? snap.containers : []
    for (var c = 0; c < list.length; c += 1) {
      if (isWarningMuted(hostAlias, containerWarningId(list[c]))) continue
      var state = containerState(list[c])
      if (state === "fail") return "fail"
      if (state === "warn") worst = "warn"
    }
    return worst
  }

  function describeProblems(snap, hostAlias) {
    if (!snap) return ""
    var problems = []
    var rows = hostRows(snap.host, null, 0)
    for (var index = 0; index < rows.length; index += 1) {
      if (isWarningMuted(hostAlias, rows[index].id)) continue
      if (rows[index].state === "fail" || rows[index].state === "warn")
        problems.push(displayMetricLabel(rows[index]) + " " + Math.round(rows[index].value * 100) + "%")
    }
    var list = snap.containers instanceof Array ? snap.containers : []
    for (var c = 0; c < list.length; c += 1) {
      if (isWarningMuted(hostAlias, containerWarningId(list[c]))) continue
      var state = containerState(list[c])
      if (state === "fail" || state === "warn")
        problems.push(displayContainerName(list[c], list) + ": "
          + (list[c].health !== "none" ? list[c].health : list[c].state))
    }
    return problems.slice(0, 4).join(", ")
  }

  function elapsedSince(hostAlias) {
    var previous = previousByHost[hostAlias]
    var current = snapshotsByHost[hostAlias]
    if (!previous || !current) return 0
    var elapsed = (new Date(current.generatedAt).getTime() - new Date(previous.generatedAt).getTime()) / 1000
    return isFinite(elapsed) && elapsed > 0 ? elapsed : 0
  }

  function terminalCommand(hostAlias, command) {
    var host = String(hostAlias || "").trim()
    if (host === "") return []
    var remoteCommand = command instanceof Array ? command : []
    return [
      "uwsm-app", "--", "xdg-terminal-exec", "--title=SSH · " + host,
      "--", "ssh", "-t", "--", host
    ].concat(remoteCommand)
  }

  function openTerminalFor(hostAlias, device) {
    var host = String(hostAlias || "").trim()
    if (host === "" || !device || !device.online) return
    root.close()
    Quickshell.execDetached(terminalCommand(host, []))
  }

  function openTerminal() {
    openTerminalFor(activeHost, activeDevice)
  }

  function openBtop() {
    if (activeHost === "" || !activeDevice || !activeDevice.online || !activeDevice.supportsMetrics) return
    root.close()
    Quickshell.execDetached(terminalCommand(activeHost, ["btop || htop || top"]))
  }

  function openUrl(url) {
    root.close()
    Quickshell.execDetached(["omarchy-launch-browser", String(url)])
  }

  function openSettings() {
    root.close()
    Quickshell.execDetached(["omarchy-launch-editor", selectionPath])
  }

  onOpenedChanged: if (opened) {
    // The shell's Color singleton reads colors.toml once and relies on an IPC
    // push for theme switches, which this plugin does not receive, so reload
    // here as well as on the file watch.
    themeColorsFile.reload()
    refreshTailnetIfStale()
    refreshSelectedHost(false)
  }
  // Settings can land after component creation; whenever the derived host
  // list changes, repair the active selection and refetch.
  onHostListChanged: {
    var current = deviceForTarget(activeHost)
    if (hostList.indexOf(activeHost) < 0 && (!current || !isMonitored(current)))
      activeHost = hostList.length > 0 ? hostList[0] : ""
    Qt.callLater(function() {
      if (typeof root === "undefined" || !root || typeof root.refreshTailnetIfStale !== "function") return
      root.refreshTailnetIfStale()
    })
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.plain(`Tailscale Host Monitor · ${root.barStateText()} · ${root.activeDevice ? root.displayHostName(root.activeHost, root.activeDevice.name, root.activeDevice) : (root.activeHost ? root.displayHostName(root.activeHost, root.activeHost, null) : "no nodes")}`)
    iconComponent: Component {
      Item {
        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          text: "󰒋"
          color: root.stateColor(root.barState)
          font.family: root.fontFamily
          font.pixelSize: Style.bar.iconFont
        }

        Rectangle {
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          width: Style.space(5)
          height: width
          radius: width / 2
          color: root.stateColor(root.barState)
          border.width: 1
          border.color: Util.alpha(root.foreground, 0.75)
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refreshAll()
      // Qt 6.11 synthesizes a context-menu event after delivering a right
      // click. Opening a terminal here can move focus and tear down panel
      // items while Qt is still walking the scene for that event, crashing
      // in QQuickItem::mapToScene(). Let delivery finish before launching.
      else if (buttonCode === Qt.RightButton) Qt.callLater(function() {
        if (typeof root === "undefined" || !root || typeof root.openTerminal !== "function") return
        root.openTerminal()
      })
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(root.panelWidth))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r") root.refresh()
        else if (text === "R") root.refreshAll()
        else if (text === "t" || text === "T") root.openTerminal()
        else if (text === "b" || text === "B") root.openBtop()
        else if (text === "e" || text === "E") root.openSettings()
        else if (text >= "1" && text <= "9") {
          var index = parseInt(text, 10) - 1
          if (index < root.hostList.length) root.selectHost(root.hostList[index])
        }
      }

      Column {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

          PanelHero {
            width: parent.width
            title: root.plain(root.hostInfo
              ? root.displayHostName(root.activeHost, root.hostInfo.hostname, root.activeDevice)
              : (root.activeDevice ? root.displayHostName(root.activeHost, root.activeDevice.name, root.activeDevice) : "No monitored nodes"))
            meta: root.activeDevice
              ? `TAILSCALE HOST MONITOR · SELECTED HOST`
              : "TAILSCALE HOST MONITOR"
            detail: root.plain(root.activeDevice
              ? `${root.activeDevice.kind} · ${root.displayDns(root.activeHost, root.activeDevice.dnsName || root.activeHost, root.activeDevice)}`
              : "Choose which Tailscale nodes this dashboard monitors")
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Item {
                implicitWidth: Style.font.display
                implicitHeight: Style.font.display

                Text {
                  textFormat: Text.PlainText
                  anchors.centerIn: parent
                  text: "󰒋"
                  color: root.activeHost === "" ? root.dim : root.stateColor(root.hostIndicatorState(root.activeHost))
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }
          }

          Flow {
            id: monitoredFlow
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              width: monitoredFlow.width
              text: "MACHINES · LEFT-CLICK TO INSPECT · RIGHT-CLICK TO SSH"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              id: monitoredRepeater
              model: root.monitoredDevices

              Rectangle {
                required property var modelData
                readonly property string target: root.configuredTarget(modelData)
                readonly property bool active: target === root.activeHost
                width: monitoredChipContent.implicitWidth + Style.space(20)
                height: monitoredChipContent.implicitHeight + Style.space(10)
                radius: height / 2
                color: active
                  ? Util.alpha(root.stateColor(root.hostIndicatorState(target)), 0.22)
                  : (root.dragTargetHost === target
                    ? Util.alpha(Color.accent, 0.2)
                    : Util.alpha(root.foreground, 0.07))
                border.width: active || root.dragTargetHost === target ? 1 : 0
                border.color: root.dragTargetHost === target ? Color.accent : root.stateColor(root.hostIndicatorState(target))
                opacity: root.draggedHost === target ? 0.18 : (modelData.online ? 1 : 0.7)
                scale: root.dragTargetHost === target ? 1.05 : 1

                Behavior on scale { NumberAnimation { duration: 90 } }

                Row {
                  id: monitoredChipContent
                  anchors.centerIn: parent
                  spacing: Style.space(5)

                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(7)
                    height: width
                    radius: width / 2
                    color: root.stateColor(root.hostIndicatorState(target))
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.displayHostName(target, modelData.name, modelData)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰆍"
                    color: modelData.online ? Color.accent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                Rectangle {
                  visible: root.dragTargetHost === target
                  x: root.dragAfterTarget ? parent.width + Style.space(2) : -Style.space(5)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(3)
                  height: parent.height + Style.space(6)
                  radius: width / 2
                  color: Color.accent
                  z: 4
                }

                MouseArea {
                  id: monitoredMouse
                  property bool dragging: false
                  property bool suppressClick: false
                  property real pressedX: 0
                  property real pressedY: 0
                  anchors.fill: parent
                  acceptedButtons: Qt.LeftButton | Qt.RightButton
                  cursorShape: dragging ? Qt.ClosedHandCursor : Qt.PointingHandCursor

                  onPressed: function(mouse) {
                    dragging = false
                    suppressClick = false
                    pressedX = mouse.x
                    pressedY = mouse.y
                  }

                  onPositionChanged: function(mouse) {
                    if (!(mouse.buttons & Qt.LeftButton)) return
                    var distance = Math.abs(mouse.x - pressedX) + Math.abs(mouse.y - pressedY)
                    if (!dragging && distance >= Style.space(5)) {
                      dragging = true
                      suppressClick = true
                      root.draggedHost = parent.target
                      root.draggedHostName = root.displayHostName(parent.target, parent.modelData.name, parent.modelData)
                      root.dragGhostWidth = parent.width
                      root.dragGhostHeight = parent.height
                    }
                    if (dragging) {
                      var point = parent.mapToItem(monitoredFlow, mouse.x, mouse.y)
                      root.updateHostDrag(parent.target, point.x, point.y)
                    }
                  }

                  onReleased: function(mouse) {
                    if (!dragging) return
                    dragging = false
                    root.finishHostDrag()
                    mouse.accepted = true
                  }

                  onCanceled: {
                    dragging = false
                    suppressClick = false
                    root.cancelHostDrag()
                  }

                  onClicked: function(mouse) {
                    if (suppressClick) {
                      suppressClick = false
                      mouse.accepted = true
                      return
                    }
                    if (mouse.button === Qt.LeftButton)
                      root.selectDevice(parent.modelData)
                    else
                      root.openTerminalFor(parent.target, parent.modelData)
                  }
                }

              }
            }

            Rectangle {
              id: manageNodesButton
              width: manageNodesLabel.implicitWidth + Style.space(18)
              height: Style.space(28)
              radius: height / 2
              color: root.pickerOpen ? Util.alpha(Color.accent, 0.2) : Util.alpha(root.foreground, 0.07)
              border.width: root.pickerOpen ? 1 : 0
              border.color: Color.accent

              Text {
                textFormat: Text.PlainText
                id: manageNodesLabel
                anchors.centerIn: parent
                text: root.pickerOpen ? "Done" : "+"
                color: root.pickerOpen ? Color.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              MouseArea {
                id: manageNodesMouse
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.pickerOpen = !root.pickerOpen
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(7)
            visible: root.pickerOpen

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: `${root.tailnetDevices.length} Tailscale nodes · click to add or remove · offline nodes remain available`
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Flow {
              id: pickerFlow
              width: parent.width
              spacing: Style.space(4)

              Repeater {
                model: root.tailnetDevices

                Rectangle {
                  required property var modelData
                  readonly property bool selected: root.isMonitored(modelData)
                  width: (pickerFlow.width - Style.space(24)) / 7
                  height: Style.space(34)
                  radius: height / 2
                  color: selected ? Util.alpha(Color.accent, 0.16) : Util.alpha(root.foreground, 0.05)
                  border.width: selected ? 1 : 0
                  border.color: Color.accent
                  opacity: modelData.online ? 1 : 0.65

                  Row {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(9)
                    anchors.rightMargin: Style.space(9)
                    spacing: Style.space(5)

                    Text {
                      textFormat: Text.PlainText
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.osIcon(modelData.os)
                      color: modelData.online ? root.stateColor("pass") : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width - Style.space(30)
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.displayHostName(root.configuredTarget(modelData), modelData.name, modelData)
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: selected
                      elide: Text.ElideRight
                    }

                    Text {
                      textFormat: Text.PlainText
                      anchors.verticalCenter: parent.verticalCenter
                      text: selected ? "✓" : "+"
                      color: selected ? Color.accent : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: true
                    }
                  }

                  MouseArea {
                    id: pickerMouse
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleMonitored(parent.modelData)
                  }
                }
              }
            }
          }

          Item {
            width: parent.width
            height: Style.space(34)
            visible: root.activeDevice !== null

            PanelSectionHeader {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "SELECTED HOST"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Row {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(7)

              PanelActionButton {
                iconText: root.refreshing || root.tailnetRefreshing ? "󰑓" : "󰑐"
                tooltipText: root.refreshing || root.tailnetRefreshing ? "Refreshing" : "Refresh selected host and Tailscale now (r)"
                foreground: root.foreground
                enabled: !root.refreshing && !root.tailnetRefreshing
                onClicked: root.refresh()
              }

              PanelActionButton {
                iconText: "󰆍"
                tooltipText: "SSH terminal (T)"
                foreground: root.foreground
                enabled: root.activeDevice && root.activeDevice.online
                onClicked: root.openTerminal()
              }

              PanelActionButton {
                iconText: "󰄨"
                tooltipText: "btop over SSH (B)"
                foreground: root.foreground
                enabled: root.activeDevice && root.activeDevice.online && root.activeDevice.supportsMetrics
                onClicked: root.openBtop()
              }

              PanelActionButton {
                iconText: "󰒓"
                tooltipText: "Edit monitored-node selection (E)"
                foreground: root.foreground
                onClicked: root.openSettings()
              }
            }
          }

          Rectangle {
            width: parent.width
            height: Style.space(94)
            radius: Style.cornerRadius
            color: Util.alpha(root.foreground, 0.055)
            border.width: 1
            border.color: Util.alpha(root.stateColor(root.hostIndicatorState(root.activeHost)), 0.45)
            visible: root.activeDevice !== null

            RowLayout {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.leftMargin: Style.space(14)
              anchors.rightMargin: Style.space(14)
              anchors.topMargin: Style.space(12)
              spacing: Style.space(18)

              InfoField {
                Layout.preferredWidth: Style.space(135)
                label: "STATUS"
                value: root.activeDevice && root.activeDevice.online ? "Online" : "Offline"
                valueColor: root.activeDevice && root.activeDevice.online ? root.stateColor("pass") : root.urgent
              }

              InfoField {
                Layout.fillWidth: true
                label: "LAST SEEN"
                value: root.lastSeenText(root.activeDevice)
              }

              InfoField {
                Layout.fillWidth: true
                readonly property string address: root.primaryIp(root.activeDevice)
                label: root.copiedValue === address ? "TAILSCALE IP · COPIED" : "TAILSCALE IP · CLICK TO COPY"
                value: root.displayIp(root.primaryIp(root.activeDevice)) || "Unavailable"
                valueColor: root.copiedValue === address ? Color.accent : root.foreground
                clickable: address !== ""
                onActivated: root.copyText(address)
              }

              InfoField {
                Layout.fillWidth: true
                label: "DEVICE"
                value: root.activeDevice ? root.activeDevice.kind : "Unknown"
              }

              InfoField {
                Layout.preferredWidth: Style.space(125)
                label: "HOST ALERTS · CLICK"
                value: root.isHostMuted(root.activeHost) ? "Muted" : "Active"
                valueColor: root.isHostMuted(root.activeHost) ? root.dim : root.stateColor("pass")
                clickable: root.activeHost !== ""
                onActivated: root.toggleHostMute(root.activeHost)
              }
            }

            Text {
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.leftMargin: Style.space(14)
              anchors.rightMargin: Style.space(14)
              anchors.bottomMargin: Style.space(9)
              text: root.startupSweepComplete
                ? `Scan cadence · selected ${root.cadenceText(root.hostScanIntervalSec)} · Tailscale ${root.cadenceText(root.tailnetScanIntervalSec)} · all monitored ${root.cadenceText(root.allHostsScanIntervalSec)}`
                : `${root.startupProgressText()} · sequential SSH · 2s between hosts`
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: root.displayError(root.tailnetError !== "" ? root.tailnetError : root.lastError)
            visible: text !== ""
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: !root.pickerOpen && root.activeDevice && root.activeDevice.online && root.activeDevice.supportsMetrics && root.hostInfo

            PanelSectionHeader {
              text: `HOST OVERVIEW · UP ${root.formatUptime(root.hostInfo ? root.hostInfo.uptimeSeconds : 0)}`
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Flow {
              id: hostMetricFlow
              width: parent.width
              spacing: Style.space(8)

              Repeater {
                model: root.hostRows(root.hostInfo, root.previousByHost[root.activeHost], root.elapsedSince(root.activeHost))

                MetricTile {
                  required property var modelData
                  width: (hostMetricFlow.width - Style.space(24)) / 4
                  metric: modelData
                  hostAlias: root.activeHost
                  allowMute: true
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            visible: !root.pickerOpen && root.activeDevice && root.activeDevice.online && root.activeDevice.supportsMetrics && !root.hostInfo
            text: root.refreshing
              ? `Loading ${root.displayHostName(root.activeHost, root.activeDevice.name, root.activeDevice)} host information…`
              : "Host information is not available yet."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: !root.pickerOpen && root.activeDevice && root.containers.length > 0

            PanelSectionHeader {
              text: root.workloadHeader()
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Flow {
              id: containerFlow
              width: parent.width
              spacing: Style.space(8)
              readonly property int columns: root.containers.length > 20 ? 6 : (root.containers.length > 9 ? 4 : 3)

              Repeater {
                model: root.containers

                ContainerTile {
                  required property var modelData
                  width: (containerFlow.width - Style.space(8) * (containerFlow.columns - 1)) / containerFlow.columns
                  container: modelData
                }
              }
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: !root.pickerOpen && root.activeDevice && (!root.activeDevice.online || !root.activeDevice.supportsMetrics)

            PanelSectionHeader {
              text: "AVAILABLE HOST INFO"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Flow {
              id: availableInfoFlow
              width: parent.width
              spacing: Style.space(8)

              Repeater {
                model: root.tailnetRows(root.activeDevice)

                MetricTile {
                  required property var modelData
                  width: (availableInfoFlow.width - Style.space(16)) / 3
                  metric: modelData
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            text: snapshot.generatedAt
              ? `Cached host data · updated ${new Date(snapshot.generatedAt).toLocaleTimeString()}${root.refreshing && root.fetchHost === root.activeHost ? " · refreshing in background…" : ""}`
              : ""
            visible: !root.pickerOpen && text !== "" && root.activeDevice && root.activeDevice.supportsMetrics
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignRight
          }

          // About line: the plugin's own identity, parked on the last row so it
          // is findable without competing with host telemetry for attention.
          Row {
            anchors.right: parent.right
            spacing: Style.space(6)

            Text {
              text: `${root.pluginName} ${root.pluginVersion}`
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              text: "·"
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            AboutLink {
              label: "GitHub"
              url: root.repoUrl
            }

            Text {
              text: "·"
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            AboutLink {
              label: "nixfred.com"
              url: root.authorUrl
            }
          }
        }

        Rectangle {
          id: hostDragGhost
          visible: root.draggedHost !== ""
          readonly property point pointer: monitoredFlow.mapToItem(
            keyCatcher, root.dragPointerX, root.dragPointerY)
          x: pointer.x - width / 2
          y: pointer.y - height / 2
          width: Math.max(root.dragGhostWidth, dragGhostContent.implicitWidth + Style.space(20))
          height: Math.max(root.dragGhostHeight, dragGhostContent.implicitHeight + Style.space(10))
          radius: height / 2
          color: Util.alpha(Color.accent, 0.32)
          border.width: 2
          border.color: Color.accent
          rotation: -2
          scale: visible ? 1.06 : 0.96
          z: 200

          Behavior on scale { NumberAnimation { duration: 80 } }

          Row {
            id: dragGhostContent
            anchors.centerIn: parent
            spacing: Style.space(5)

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(8)
              height: width
              radius: width / 2
              color: root.stateColor(root.hostIndicatorState(root.draggedHost))
            }

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              text: root.draggedHostName
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
          }
        }
      }
    }

  Process {
    id: statusProcess
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        root.processOutput += chunk
        if (root.processOutput.length > root.maxBackendOutputChars) {
          root.processOutput = ""
          root.processError = "server-status output exceeded limit"
          statusProcess.signal(15)
          statusKillTimer.start()
        }
      }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (root.processError.length < root.maxBackendErrorChars)
          root.processError += chunk
      }
    }
    onExited: function(exitCode) {
      statusKillTimer.stop()
      root.processError = root.processError.trim()
      if (root.processOutput !== "") root.storeSnapshot(root.fetchHost, root.processOutput)
      var completedHost = root.fetchHost
      Qt.callLater(function() {
        if (typeof root === "undefined" || !root || typeof root.finishStartupHost !== "function") return
        if (exitCode !== 0 || root.processOutput === "") {
          root.setHostFetchFailed(completedHost, true)
          if (completedHost === root.activeHost)
            root.lastError = root.processError || `server-status exited ${exitCode}`
        }
        root.finishStartupHost(completedHost)
        root.fetchHost = ""
        if (!root.startupSweepComplete && root.pendingHosts.length > 0)
          startupPaceTimer.restart()
        else
          root.pump()
      })
    }
  }

  Process {
    id: snapshotCachePermissionsProcess
    command: ["/usr/bin/chmod", "600", root.snapshotCachePath]
  }

  FileView {
    id: selectionFile
    path: root.selectionPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadSelection(text())
    onLoadFailed: root.loadSelection("")
    onFileChanged: reload()
  }

  FileView {
    id: themeColorsFile
    path: root.themeColorsPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.themeColorValues = ThemePalette.parseColorsToml(text())
    onLoadFailed: root.themeColorValues = ({})
  }

  FileView {
    id: snapshotCacheFile
    path: root.snapshotCachePath
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadSnapshotCache(text())
    onLoadFailed: root.loadSnapshotCache("")
  }

  Process {
    id: tailnetProcess
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        root.tailnetOutput += chunk
        if (root.tailnetOutput.length > root.maxBackendOutputChars) {
          root.tailnetOutput = ""
          root.tailnetProcessError = "tailscale discovery output exceeded limit"
          tailnetProcess.signal(15)
          tailnetKillTimer.start()
        }
      }
    }
    stderr: SplitParser {
      splitMarker: ""
      onRead: function(chunk) {
        if (root.tailnetProcessError.length < root.maxBackendErrorChars)
          root.tailnetProcessError += chunk
      }
    }
    onExited: function(exitCode) {
      tailnetKillTimer.stop()
      root.tailnetProcessError = root.tailnetProcessError.trim()
      if (root.tailnetOutput !== "") root.storeTailnet(root.tailnetOutput)
      root.tailnetRefreshing = false
      if (exitCode !== 0)
        root.tailnetError = root.tailnetProcessError || `tailscale discovery exited ${exitCode}`
      if (!root.tailnetInitialScanComplete) {
        root.tailnetInitialScanComplete = true
        root.maybeStartStartupSweep()
      }
    }
  }

  // Only the selected host receives frequent SSH telemetry while the panel is
  // open. Tailnet discovery and all-host sweeps run on independent cadences.
  Timer {
    interval: root.hostScanIntervalSec * 1000
    repeat: true
    running: root.opened
    onTriggered: root.refreshSelectedHost(true)
  }

  Timer {
    interval: root.tailnetScanIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refreshTailnet()
  }

  Timer {
    interval: root.allHostsScanIntervalSec * 1000
    repeat: true
    running: true
    onTriggered: root.refreshAllHosts()
  }

  Timer {
    id: copyReset
    interval: 1600
    onTriggered: root.copiedValue = ""
  }

  Timer {
    id: snapshotCacheWriteTimer
    interval: 500
    onTriggered: root.writeSnapshotCache()
  }

  Timer {
    id: snapshotCachePermissionsTimer
    interval: 1000
    onTriggered: if (!snapshotCachePermissionsProcess.running)
      snapshotCachePermissionsProcess.running = true
  }

  Timer {
    id: startupPaceTimer
    interval: 2000
    onTriggered: {
      stop()
      root.pump()
    }
  }

  Timer {
    id: statusKillTimer
    interval: 2000
    onTriggered: statusProcess.signal(9)
  }

  Timer {
    id: tailnetKillTimer
    interval: 2000
    onTriggered: tailnetProcess.signal(9)
  }

  component InfoField: Item {
    required property string label
    required property string value
    property color valueColor: root.foreground
    property bool clickable: false
    signal activated()
    implicitHeight: infoFieldContent.implicitHeight

    Column {
      id: infoFieldContent
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: Style.space(4)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: label
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: value
        color: valueColor
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        elide: Text.ElideRight
      }
    }

    MouseArea {
      anchors.fill: parent
      enabled: parent.clickable
      cursorShape: Qt.PointingHandCursor
      onClicked: parent.activated()
    }
  }

  component MetricTile: Rectangle {
    id: metricTile
    required property var metric
    property string hostAlias: root.activeHost
    property bool allowMute: false
    readonly property bool muted: allowMute && root.isWarningMuted(hostAlias, String(metric.id || ""))
    readonly property bool canToggleMute: allowMute && (muted || metric.state === "warn" || metric.state === "fail")
    // Muting changes alert policy only. The card keeps rendering the actual
    // state, value, detail, and capacity color so no host information is lost.
    readonly property string displayState: String(metric.state || "unknown")
    readonly property string tooltipText: root.displayMetricTooltip(metric)
    implicitHeight: Style.space(64)
    radius: Style.cornerRadius
    color: Util.alpha(root.foreground, 0.045)
    border.width: canToggleMute ? 1 : 0
    border.color: Util.alpha(root.stateColor(displayState), 0.55)

    Column {
      anchors.fill: parent
      anchors.margins: Style.space(8)
      spacing: Style.space(4)

      Row {
        width: parent.width
        spacing: Style.space(7)

        Rectangle {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(9)
          height: width
          radius: width / 2
          color: root.stateColor(metricTile.displayState)
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width - metricPercent.implicitWidth - muteAction.implicitWidth - Style.space(25)
          text: root.displayMetricLabel(metricTile.metric)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          id: metricPercent
          visible: metricTile.metric.value > 0
          text: Math.round(metricTile.metric.value * 100) + "%"
          color: root.stateColor(metricTile.displayState)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        Text {
          textFormat: Text.PlainText
          id: muteAction
          visible: metricTile.canToggleMute
          text: metricTile.muted ? "MUTED" : "MUTE"
          color: metricTile.muted ? root.dim : root.stateColor(metricTile.metric.state)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
        }
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        text: root.displayMetricDetail(metricTile.metric)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }

      Rectangle {
        width: parent.width
        visible: metricTile.metric.value > 0
        height: Style.space(3)
        radius: height / 2
        color: Util.alpha(root.foreground, 0.08)

        Rectangle {
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: parent.width * Math.min(1, metricTile.metric.value)
          radius: parent.radius
          color: root.stateColor(metricTile.displayState)
        }
      }
    }

    MouseArea {
      id: metricHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: metricTile.canToggleMute ? Qt.LeftButton : Qt.NoButton
      cursorShape: metricTile.canToggleMute ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: root.toggleWarningMute(metricTile.hostAlias, String(metricTile.metric.id || ""))

      PanelToolTip {
        visible: metricHover.containsMouse && metricTile.tooltipText !== ""
        text: metricTile.tooltipText
      }
    }
  }

  component AboutLink: Text {
    id: aboutLink
    required property string label
    required property string url

    text: label
    textFormat: Text.PlainText
    color: linkHover.containsMouse ? Color.accent : root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
    font.underline: linkHover.containsMouse

    MouseArea {
      id: linkHover
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.openUrl(aboutLink.url)

      PanelToolTip {
        visible: linkHover.containsMouse
        text: aboutLink.url
      }
    }
  }

  component ContainerTile: Rectangle {
    id: containerTile
    required property var container
    readonly property string healthState: root.containerState(container)
    readonly property string warningId: root.containerWarningId(container)
    readonly property bool muted: root.isWarningMuted(root.activeHost, warningId)
    readonly property bool canToggleMute: muted || healthState === "warn" || healthState === "fail"
    // Keep the real container health visible; muted means alerts/host rollup
    // are disabled, not that the underlying state changed.
    readonly property string displayState: healthState
    implicitHeight: Style.space(50)
    radius: Style.cornerRadius
    color: Util.alpha(root.foreground, 0.045)
    border.width: canToggleMute ? 1 : 0
    border.color: Util.alpha(root.stateColor(displayState), 0.55)

    RowLayout {
      anchors.fill: parent
      anchors.margins: Style.space(8)
      spacing: Style.space(7)

      Rectangle {
        Layout.preferredWidth: Style.space(10)
        Layout.preferredHeight: Style.space(10)
        radius: width / 2
        color: root.stateColor(containerTile.displayState)
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(3)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: root.displayContainerName(containerTile.container)
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
          elide: Text.ElideRight
        }

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: root.containerDetail(containerTile.container)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Text {
        textFormat: Text.PlainText
        visible: containerTile.canToggleMute || containerTile.container.memPercent !== null
        text: containerTile.muted ? "MUTED" : (containerTile.canToggleMute ? "MUTE" : Math.round(containerTile.container.memPercent) + "%")
        color: root.stateColor(containerTile.displayState)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }
    }

    MouseArea {
      anchors.fill: parent
      enabled: containerTile.canToggleMute
      cursorShape: Qt.PointingHandCursor
      onClicked: root.toggleWarningMute(root.activeHost, containerTile.warningId)
    }
  }

}
