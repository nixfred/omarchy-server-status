# Tailscale Host Monitor for Omarchy

**A glanceable, selective monitor for your Tailscale network, living in the Omarchy bar.** If
you run a couple of VPSes, a homelab box, or a small Docker-based product,
this widget answers "is everything OK over there?" without opening a browser
dashboard or SSHing around: host load, memory, disk, network, and every
Docker container's health and resource usage — one click away, with desktop
notifications when something crosses a threshold. It complements (not
replaces) full monitoring stacks: no history, no server-side storage, just
the current truth on demand.

![Tailscale Host Monitor showing a privacy-masked selected host and an unreachable-host alert](preview.png)

The node picker discovers the tailnet with `tailscale status --json`. Only the
nodes you select appear in the monitor. Linux nodes receive deep telemetry via
**one read-only SSH round trip**; macOS, Windows, iOS, and Android nodes show the
Tailscale presence, address, DNS, device type, tags, and last-seen information
that is available for their platform. Offline nodes remain selectable.

Agentless by design: every Linux telemetry refresh is **one read-only SSH round trip** —
nothing is installed, written, or left running on your servers. Hosts
without Docker simply show host metrics; the containers column appears only
when containers exist.

```text
panel → bun backend → ssh <host> '<read-only script>' → JSON snapshot → panel
```

The remote script reads `/proc`, `free`, and `df` for host metrics, and
`docker ps / stats / inspect` for containers. `docker inspect` deliberately
uses a narrow format string: full inspect output would leak container
environment variables (secrets) into the snapshot.

## Features

- **Host metrics** — CPU load, memory, per-disk usage, network rate, uptime,
  with traffic-light thresholds (memory warns at 75%, red at 85%; disk warns
  at 70%, red at 80%; load per core warns at 0.7, red at 1.0)
- **Containers** — compact three-column cards show health, CPU%, memory versus its
  limit, restart count; unhealthy, restarting, or OOM-killed turns red
- **Multiple servers** — small chips switch between selected hosts; drag them
  to persist a new `monitoredHosts` order; the full bar icon and its status dot
  use green/yellow/red for the worst unmuted state across all selected hosts
- **Selected-host workspace** — the chosen host stays selected across shell
  reloads; status, last seen, Tailscale IP, device type, host metrics, and
  containers are arranged around that host instead of the discovery list
- **Direct actions** — click the selected host's Tailscale IP to copy it;
  warning cards expose a visible MUTE/MUTED toggle stored per host without
  hiding or recoloring the underlying data; SSH, btop, and settings close the
  monitor and launch on a newly focused workspace
- **Whole-host mute** — click **HOST ALERTS** in the focused-host status box to
  suppress that host's notifications and exclude its failures from the bar
  color; its live and cached information remains fully visible
- **Trustworthy startup sweep** — startup stays green while the nodes selected
  on the previous run are checked sequentially, with two seconds between SSH
  connections; warnings, red status, and notifications begin only after the
  complete selected set has been evaluated
- **No inner scrolling** — the popup follows its content height, switches to
  denser metric/container grids when necessary, and replaces the dashboard
  with the node manager while that manager is open
- **Persistent host cache** — the latest safe snapshot for every host is kept
  in `~/.cache/omarchy-server-status-snapshots.json`; cached cards appear
  immediately after a shell/plugin reload and remain visible during refresh
- **Selective tailnet discovery** — click to add or remove any Tailscale node;
  unselected devices stay out of the monitor dashboard
- **Type-aware nodes** — deep Linux telemetry where supported and honest
  Tailscale-only details for Macs, mobile devices, Windows, and offline nodes
- **Desktop notifications** — `notify-send` on threshold breaches, container
  failures, unreachable hosts, and recoveries
- **Zero server footprint** — works with any Linux host you can SSH into

## Requirements

- Omarchy Shell with third-party plugin support
- [Bun](https://bun.sh) 1.2 or newer on the desktop (only long-stable
  `Bun.spawn` / `bun test` APIs are used)
- Passwordless SSH to each server (key-based; the backend runs with
  `BatchMode=yes`, so password prompts fail closed)
- For container metrics, the remote account needs either `sudo -n docker`
  or membership in the `docker` group; host metrics work without either

## Install

```bash
omarchy plugin add https://github.com/nixfred/omarchy-server-status --enable --yes
```

Or from a local clone:

```bash
omarchy plugin validate ~/path/to/omarchy-server-status
omarchy plugin add file://$HOME/path/to/omarchy-server-status --enable --yes
```

## Remove

```bash
omarchy plugin remove ryuhzk.server-status
```

This unregisters the plugin and deletes its installed files. The selected-node
list remains in `~/.config/omarchy/server-status.json`; delete that file too if
you want a fully clean slate. Nothing was ever installed on the monitored
servers, so there is nothing to clean up remotely.

## Selecting nodes

1. Open the panel and click the small **+** beside the monitored-host chips.

2. Click any online or offline node to toggle it. The selection is stored in
   `~/.config/omarchy/server-status.json` and does not reload the shell.

3. For deep Linux telemetry, make sure the selected node accepts key-based SSH.
   A matching alias in `~/.ssh/config` can provide a custom user or identity:

   ```ssh-config
   Host web-1
       HostName 203.0.113.10
       User ops
       IdentityFile ~/.ssh/id_ed25519
       IdentitiesOnly yes
   ```

Switch between selected nodes with the chips at the top of the panel, or press
`1`–`9`. The chosen host is stored with the selection and remains focused across
shell/plugin reloads until you choose another one. The bar dot always shows the
worst state across the selected nodes.

Host snapshots are cached in memory and on disk. Switching to a host whose
snapshot is newer than the selected-host scan cadence reuses that snapshot
without another SSH request. When a snapshot is stale, the cached card remains
onscreen while one background request replaces it atomically. Manual refresh
always forces a fresh sample. The cache contains only the already-sanitized
snapshot, is restricted to the current user (`0600`), and never stores
container environment variables or SSH credentials.

Drag a monitored-host chip over another chip and release to change its position.
The chip follows the pointer as a raised drag ghost, while the destination
shows an insertion bar and expands slightly. The new order is written immediately to the `monitoredHosts` array in
`~/.config/omarchy/server-status.json` and is used after every reload.

Click the Tailscale IP in the selected-host box to copy it with `wl-copy`.
When a host metric or container is warning/failing, its card shows **MUTE**.
Clicking the card records that warning ID under the selected host's
`mutedWarnings` entry and removes it only from host-color and notification
rollups. The card keeps its actual value, detail, health state, and warning
color while showing **MUTED**. Click it again to restore alerting.

For a host-wide maintenance window, click **HOST ALERTS** in the selected-host
status box. A muted host stays in the dashboard with all of its real data, but
does not send notifications or contribute yellow/red to the bar icon. Click
the field again to re-enable alerting. Host-wide mutes are stored in the
`mutedHosts` array in `~/.config/omarchy/server-status.json`.

Scanning is split into three independent schedules. By default, the selected
host receives one read-only SSH telemetry request every 30 seconds while the
panel is open. `tailscale status --json` reads presence from the local Tailscale
daemon every 5 minutes; it does not ping or SSH every tailnet node. Selected
Linux hosts receive a background SSH sweep every 5 minutes for status dots and
notifications. At startup the previously selected Linux hosts are placed in a
single SSH queue, processed one at a time with a two-second pause between
connections. The monitor remains green and suppresses startup alerts until the
entire selected set has been checked.

Each schedule has fixed presets and a Custom option with a seconds field in the
plugin settings. The current effective cadences are also printed in the
selected-host status box. Manual refresh (`r`) refreshes the selected host and
Tailscale presence immediately; `R` also requests every selected Linux host.

## Shortcuts

| Key   | Action                          |
| ----- | ------------------------------- |
| `r`   | Refresh the focused host        |
| `R`   | Refresh every host              |
| `T`   | Open an SSH terminal            |
| `B`   | Open btop/htop/top over SSH     |
| `E`   | Edit the monitored-node selection file |
| `1–9` | Switch host                     |
| `Esc` | Close the panel                 |

Bar icon: green means every selected host is healthy, yellow means a warning
or telemetry is still unknown, and red means a critical condition or offline
node. Middle-click refreshes all hosts. Right-click closes the monitor and
opens an SSH terminal to the focused host on a new workspace.

## Settings

| Key                     | Default      | Description |
| ----------------------- | ------------ | ----------- |
| `sshHosts`              | *(empty)*    | Legacy seed used on first run; use the in-panel picker afterward |
| `hostScanPreset`        | `30 seconds` | Selected-host SSH cadence while open |
| `customHostScanSec`     | `30`         | Seconds used when selected-host cadence is Custom |
| `tailnetScanPreset`     | `5 minutes`  | Local Tailscale daemon discovery cadence |
| `customTailnetScanSec`  | `300`        | Seconds used when Tailscale cadence is Custom |
| `customAllHostsScanSec` | `300`        | Seconds used when all-host cadence is Custom |
| `panelWidth`            | `1000`       | Popup width in layout units |
| `privacyMode`           | `false`      | Mask identifying details for screenshots and screen sharing |

Privacy mode changes presentation only. Collection, selection, health state,
copy/SSH targets, and cached snapshots continue to use the real node data.

## Diagnosing

Run the collector outside Omarchy to inspect the raw snapshot:

```bash
bun run backend/server-status.ts status --host <ssh-alias>
```

## Development

```bash
bun run check              # tests + build
omarchy plugin validate .
```

## Security notes

- The remote script is read-only; the plugin never mutates server state.
- Snapshots exclude container environment variables by design.
- Use a dedicated, restricted SSH identity if you want the panel's key to be
  unable to do anything beyond reading status.

## License

[MIT](./LICENSE)
