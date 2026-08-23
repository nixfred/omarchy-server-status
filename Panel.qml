import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root

  moduleName: "ryuhzk.server-status"
  ipcTarget: "ryuhzk.server-status"

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

  readonly property string sshHosts: String(setting("sshHosts", ""))
  // Colon-separated subset of sshHosts that still shows in the panel but never
  // fires desktop notifications (e.g. a box that is expected to flap).
  readonly property var mutedHosts: String(setting("muteHosts", "")).split(":").map(function(entry) {
    return entry.trim()
  }).filter(function(entry) { return entry !== "" })
  readonly property int refreshIntervalSec: boundedInt(setting("refreshIntervalSec", 30), 10, 3600)
  readonly property int panelWidth: boundedInt(setting("panelWidth", 1000), 320, 1200)
  readonly property string backendPath: decodeURIComponent(
    String(Qt.resolvedUrl("backend/server-status.ts")).replace(/^file:\/\//, ""))

  readonly property var hostList: sshHosts.split(":").map(function(entry) {
    return entry.trim()
  }).filter(function(entry) { return entry !== "" })
  readonly property var snapshot: snapshotsByHost[activeHost] || ({ host: null, containers: [], error: "" })
  readonly property var hostInfo: snapshot.host || null
  readonly property var containers: snapshot.containers instanceof Array ? snapshot.containers : []
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: {
    activeHost = hostList.length > 0 ? hostList[0] : ""
  }

  function boundedInt(value, minimum, maximum) {
    var parsed = parseInt(String(value), 10)
    if (!isFinite(parsed)) parsed = minimum
    return Math.max(minimum, Math.min(maximum, parsed))
  }

  function stateColor(state) {
    if (state === "pass") return "#69c58a"
    if (state === "running") return Color.accent
    if (state === "warn") return "#e5b45d"
    if (state === "fail") return root.urgent
    return root.dim
  }

  function stateGlyph(state) {
    if (state === "pass") return "✓"
    if (state === "running") return "↻"
    if (state === "warn") return "!"
    if (state === "fail") return "×"
    if (state === "idle") return "·"
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

  function hostRows(info, previous, elapsedSec) {
    if (!info) return []
    var rows = []
    var loadPerCore = info.cpuCount > 0 ? info.load1 / info.cpuCount : 0
    rows.push({
      id: "cpu",
      label: "CPU load",
      state: levelFor(loadPerCore, 0.7, 1.0),
      detail: info.load1.toFixed(2) + " / " + info.load5.toFixed(2) + " / " + info.load15.toFixed(2)
        + " · " + info.cpuCount + " cores",
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
      rows.push({
        id: "disk-" + disk.mount,
        label: "Disk " + disk.mount,
        state: levelFor(frac, 0.7, 0.8),
        detail: formatBytes(disk.usedBytes) + " / " + formatBytes(disk.totalBytes),
        value: frac
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

  function containerState(container) {
    if (container.oomKilled) return "fail"
    if (container.state === "running") {
      if (container.health === "unhealthy") return "fail"
      if (container.health === "starting") return "running"
      return "pass"
    }
    if (container.state === "restarting") return "fail"
    if (container.state === "exited" || container.state === "dead") return "warn"
    return "unknown"
  }

  function containerDetail(container) {
    var parts = []
    if (container.cpuPercent !== null) parts.push("cpu " + container.cpuPercent.toFixed(1) + "%")
    if (container.memPercent !== null)
      parts.push("mem " + formatBytes(container.memUsageBytes) + " (" + container.memPercent.toFixed(0) + "%)")
    if (container.restarts > 0) parts.push(container.restarts + " restarts")
    if (container.health !== "none") parts.push(container.health)
    else parts.push(container.state)
    return parts.join(" · ")
  }

  function summaryFor(hostAlias) {
    var snap = snapshotsByHost[hostAlias]
    if (!snap) return "unknown"
    if (snap.error) return "unknown"
    var worst = "pass"
    var rows = hostRows(snap.host, null, 0)
    for (var index = 0; index < rows.length; index += 1) {
      if (rows[index].state === "fail") return "fail"
      if (rows[index].state === "warn") worst = "warn"
    }
    var list = snap.containers instanceof Array ? snap.containers : []
    for (var c = 0; c < list.length; c += 1) {
      var state = containerState(list[c])
      if (state === "fail") return "fail"
      if (state === "warn") worst = "warn"
    }
    return worst
  }

  function worstState() {
    var order = ["fail", "warn", "unknown", "pass"]
    var worst = "unknown"
    var rank = order.length
    var sawAny = false
    for (var index = 0; index < hostList.length; index += 1) {
      if (!snapshotsByHost[hostList[index]]) continue
      sawAny = true
      var state = summaryFor(hostList[index])
      var current = order.indexOf(state)
      if (current >= 0 && current < rank) { rank = current; worst = order[current] }
    }
    return sawAny ? worst : "unknown"
  }

  function selectHost(hostAlias) {
    if (activeHost === hostAlias) return
    activeHost = hostAlias
    if (!snapshotsByHost[hostAlias]) refresh()
  }

  function refresh() { enqueue([activeHost]) }
  function refreshAll() { enqueue(hostList) }

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
    if (statusProcess.running) return
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
      var previous = snapshotsByHost[hostAlias]
      maybeNotify(hostAlias, previous, parsed)
      var previousMap = Object.assign({}, previousByHost)
      if (previous) previousMap[hostAlias] = previous
      previousByHost = previousMap
      var merged = Object.assign({}, snapshotsByHost)
      merged[hostAlias] = parsed
      snapshotsByHost = merged
      if (hostAlias === activeHost) lastError = parsed.error || ""
    } catch (error) {
      if (hostAlias === activeHost)
        lastError = "Could not read server status: " + String(error)
    }
  }

  function maybeNotify(hostAlias, previous, next) {
    if (mutedHosts.indexOf(hostAlias) >= 0) return
    if (!previous) return
    var prevSummary = summaryForSnapshot(previous)
    var nextSummary = summaryForSnapshot(next)
    if (prevSummary === nextSummary) return
    var title = ""
    var urgency = "normal"
    if (nextSummary === "fail") {
      title = "Server alert · " + hostAlias
      urgency = "critical"
    } else if (nextSummary === "warn" && prevSummary === "pass") {
      title = "Server warning · " + hostAlias
    } else if (nextSummary === "pass" && (prevSummary === "fail" || prevSummary === "warn")) {
      title = "Server recovered · " + hostAlias
    } else if (nextSummary === "unknown" && prevSummary !== "unknown") {
      title = "Server unreachable · " + hostAlias
      urgency = "critical"
    } else {
      return
    }
    var body = describeProblems(next) || String(next.error || "All metrics back within thresholds")
    var key = hostAlias + "|" + nextSummary + "|" + body
    if (notifiedKeyByHost[hostAlias] === key) return
    var keys = Object.assign({}, notifiedKeyByHost)
    keys[hostAlias] = key
    notifiedKeyByHost = keys
    Quickshell.execDetached(["notify-send", "-a", "Server Status", "-u", urgency, title, body])
  }

  function summaryForSnapshot(snap) {
    if (!snap || snap.error) return "unknown"
    var worst = "pass"
    var rows = hostRows(snap.host, null, 0)
    for (var index = 0; index < rows.length; index += 1) {
      if (rows[index].state === "fail") return "fail"
      if (rows[index].state === "warn") worst = "warn"
    }
    var list = snap.containers instanceof Array ? snap.containers : []
    for (var c = 0; c < list.length; c += 1) {
      var state = containerState(list[c])
      if (state === "fail") return "fail"
      if (state === "warn") worst = "warn"
    }
    return worst
  }

  function describeProblems(snap) {
    if (!snap) return ""
    var problems = []
    var rows = hostRows(snap.host, null, 0)
    for (var index = 0; index < rows.length; index += 1) {
      if (rows[index].state === "fail" || rows[index].state === "warn")
        problems.push(rows[index].label + " " + Math.round(rows[index].value * 100) + "%")
    }
    var list = snap.containers instanceof Array ? snap.containers : []
    for (var c = 0; c < list.length; c += 1) {
      var state = containerState(list[c])
      if (state === "fail" || state === "warn")
        problems.push(list[c].name + ": " + (list[c].health !== "none" ? list[c].health : list[c].state))
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

  function openTerminal() {
    if (activeHost === "") return
    Quickshell.execDetached(["uwsm-app", "--", "xdg-terminal-exec", "--", "ssh", "-t", activeHost])
  }

  function openBtop() {
    if (activeHost === "") return
    Quickshell.execDetached(["uwsm-app", "--", "xdg-terminal-exec", "--", "ssh", "-t", activeHost, "btop || htop || top"])
  }

  function openSettings() {
    Quickshell.execDetached(["omarchy-launch-editor", Quickshell.env("HOME") + "/.config/omarchy/shell.json"])
  }

  onOpenedChanged: if (opened) refresh()
  // Settings can land after component creation; whenever the derived host
  // list changes, repair the active selection and refetch.
  onHostListChanged: {
    if (hostList.indexOf(activeHost) < 0) activeHost = hostList.length > 0 ? hostList[0] : ""
    Qt.callLater(refreshAll)
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    tooltipText: `${root.activeHost || "Server Status"} · ${root.summaryFor(root.activeHost)}`
    iconComponent: Component {
      Item {
        Text {
          anchors.centerIn: parent
          text: "󰒋"
          color: root.stateColor(root.summaryFor(root.activeHost) === "pass" ? "pass" : root.summaryFor(root.activeHost))
          font.family: root.fontFamily
          font.pixelSize: Style.bar.iconFont
        }

        Rectangle {
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          width: Style.space(5)
          height: width
          radius: width / 2
          color: root.stateColor(root.worstState())
        }
      }
    }
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) root.refreshAll()
      else if (buttonCode === Qt.RightButton) root.openTerminal()
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
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight, Style.space(680))

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

      Flickable {
        anchors.fill: parent
        contentWidth: width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: contentColumn
          width: parent.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: root.hostInfo ? root.hostInfo.hostname : (root.activeHost || "Server Status")
            meta: root.activeHost + " · " + root.summaryFor(root.activeHost)
            detail: root.hostInfo ? root.formatUptime(root.hostInfo.uptimeSeconds) : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Item {
                implicitWidth: Style.font.display
                implicitHeight: Style.font.display

                Text {
                  anchors.centerIn: parent
                  text: "󰒋"
                  color: root.stateColor(root.summaryFor(root.activeHost))
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }
            }
          }

          Flow {
            width: parent.width
            spacing: Style.space(6)
            visible: root.hostList.length > 1

            Repeater {
              model: root.hostList

              Rectangle {
                required property var modelData
                readonly property bool active: modelData === root.activeHost
                width: chipLabel.implicitWidth + Style.space(20)
                height: chipLabel.implicitHeight + Style.space(10)
                radius: height / 2
                color: active
                  ? Util.alpha(root.stateColor(root.summaryFor(modelData)), 0.22)
                  : Util.alpha(root.foreground, 0.07)
                border.width: active ? 1 : 0
                border.color: root.stateColor(root.summaryFor(modelData))

                Row {
                  id: chipLabel
                  anchors.centerIn: parent
                  spacing: Style.space(5)

                  Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(7)
                    height: width
                    radius: width / 2
                    color: root.stateColor(root.summaryFor(parent.parent.modelData))
                  }

                  Text {
                    text: parent.parent.modelData
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.selectHost(parent.modelData)
                }
              }
            }
          }

          Text {
            width: parent.width
            text: root.hostList.length === 0
              ? "No servers configured. Add colon-separated ssh host aliases from ~/.ssh/config in this widget's settings (sshHosts), e.g. web-1:db-1."
              : root.lastError
            visible: text !== ""
            color: root.hostList.length === 0 ? root.dim : root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Row {
            spacing: Style.space(8)

            PanelActionButton {
              iconText: root.refreshing ? "󰑓" : "󰑐"
              tooltipText: root.refreshing ? "Refreshing" : "Refresh (r), all hosts (R)"
              foreground: root.foreground
              enabled: !root.refreshing
              onClicked: root.refresh()
            }

            PanelActionButton {
              iconText: "󰆍"
              tooltipText: "SSH terminal (T)"
              foreground: root.foreground
              onClicked: root.openTerminal()
            }

            PanelActionButton {
              iconText: "󰄨"
              tooltipText: "btop over SSH (B)"
              foreground: root.foreground
              onClicked: root.openBtop()
            }

            PanelActionButton {
              iconText: "󰒓"
              tooltipText: "Edit settings in shell.json (E)"
              foreground: root.foreground
              onClicked: root.openSettings()
            }
          }

          PanelSeparator { foreground: root.foreground }

          Row {
            id: metricColumns
            width: parent.width
            spacing: Style.space(16)
            readonly property bool twoColumns: root.containers.length > 0
            readonly property real columnWidth: twoColumns ? (width - spacing) / 2 : width

            Column {
              width: metricColumns.columnWidth
              spacing: Style.space(4)

              PanelSectionHeader {
                text: "HOST"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: root.hostRows(root.hostInfo, root.previousByHost[root.activeHost], root.elapsedSince(root.activeHost))

                MetricRow {
                  required property var modelData
                  width: parent.width
                  metric: modelData
                }
              }
            }

            Column {
              width: metricColumns.columnWidth
              spacing: Style.space(4)
              visible: metricColumns.twoColumns

              PanelSectionHeader {
                text: `CONTAINERS · ${root.containers.length}`
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Repeater {
                model: root.containers

                MetricRow {
                  required property var modelData
                  width: parent.width
                  metric: ({
                    id: "container-" + modelData.name,
                    label: modelData.name,
                    state: root.containerState(modelData),
                    detail: root.containerDetail(modelData),
                    value: modelData.memPercent !== null ? modelData.memPercent / 100 : 0
                  })
                }
              }
            }
          }

          Text {
            width: parent.width
            text: snapshot.generatedAt ? `Updated ${new Date(snapshot.generatedAt).toLocaleTimeString()}` : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignRight
          }
        }
      }
    }
  }

  Process {
    id: statusProcess
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.processOutput = String(text || "")
        if (root.processOutput !== "") root.storeSnapshot(root.fetchHost, root.processOutput)
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.processError = String(text || "").trim()
    }
    onExited: function(exitCode) {
      Qt.callLater(function() {
        if (exitCode !== 0 && root.fetchHost === root.activeHost)
          root.lastError = root.processError || `server-status exited ${exitCode}`
        root.fetchHost = ""
        root.pump()
      })
    }
  }

  // Focused host refresh while the panel is open.
  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: root.opened
    onTriggered: root.refresh()
  }

  // Slow background sweep across every host to keep the bar dot, chips, and
  // notifications alive without constant SSH traffic while closed.
  Timer {
    interval: Math.max(300, root.refreshIntervalSec * 10) * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refreshAll()
  }

  component MetricRow: Item {
    id: metricRow

    required property var metric
    implicitHeight: metricContent.implicitHeight + Style.spacing.rowPaddingX

    RowLayout {
      id: metricContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(10)

      Rectangle {
        Layout.preferredWidth: Style.space(20)
        Layout.preferredHeight: Style.space(20)
        radius: width / 2
        color: Util.alpha(root.stateColor(metricRow.metric.state), 0.18)

        Text {
          anchors.centerIn: parent
          text: root.stateGlyph(metricRow.metric.state)
          color: root.stateColor(metricRow.metric.state)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(3)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          Text {
            Layout.fillWidth: true
            text: String(metricRow.metric.label || "")
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
          }

          Text {
            visible: metricRow.metric.value > 0
            text: Math.round(metricRow.metric.value * 100) + "%"
            color: root.stateColor(metricRow.metric.state)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }
        }

        Rectangle {
          Layout.fillWidth: true
          visible: metricRow.metric.value > 0
          height: Style.space(4)
          radius: height / 2
          color: Util.alpha(root.foreground, 0.08)

          Rectangle {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: parent.width * Math.min(1, metricRow.metric.value)
            radius: parent.radius
            color: root.stateColor(metricRow.metric.state)
          }
        }

        Text {
          Layout.fillWidth: true
          text: String(metricRow.metric.detail || "")
          visible: text !== ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
      }
    }
  }
}
