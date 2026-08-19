# Omarchy Server Status

**A glanceable ops panel for your servers, living in the Omarchy bar.** If
you run a couple of VPSes, a homelab box, or a small Docker-based product,
this widget answers "is everything OK over there?" without opening a browser
dashboard or SSHing around: host load, memory, disk, network, and every
Docker container's health and resource usage — one click away, with desktop
notifications when something crosses a threshold. It complements (not
replaces) full monitoring stacks: no history, no server-side storage, just
the current truth on demand.

Agentless by design: every refresh is **one read-only SSH round trip** —
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
- **Containers** — one row per container: health, CPU%, memory versus its
  limit, restart count; unhealthy, restarting, or OOM-killed turns red
- **Multiple servers** — chips to switch between hosts, worst state on the
  bar dot
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
omarchy plugin add https://github.com/ryuhzk/omarchy-server-status --enable --yes
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

This unregisters the plugin and deletes its installed files. Your per-widget
settings (the `sshHosts` list and thresholds) live in
`~/.config/omarchy/shell.json`; remove the widget's entry there if you want a
fully clean slate. Nothing was ever installed on the monitored servers, so
there is nothing to clean up remotely.

## Adding servers

1. Give each server an alias in `~/.ssh/config` with key authentication:

   ```ssh-config
   Host web-1
       HostName 203.0.113.10
       User ops
       IdentityFile ~/.ssh/id_ed25519
       IdentitiesOnly yes
   ```

2. Open the widget's settings in the bar and set **SSH hosts** to a
   colon-separated list of aliases:

   ```text
   web-1:db-1:home-nas
   ```

3. Switch between servers with the chips at the top of the panel, or press
   `1`–`9`. The bar dot always shows the worst state across every host.

The focused host refreshes at `refreshIntervalSec` while the panel is open;
all hosts are swept on a slow background cycle (10× the interval, at least
5 minutes) to keep the bar dot, chips, and notifications alive without
constant SSH traffic.

## Shortcuts

| Key   | Action                          |
| ----- | ------------------------------- |
| `r`   | Refresh the focused host        |
| `R`   | Refresh every host              |
| `T`   | Open an SSH terminal            |
| `B`   | Open btop/htop/top over SSH     |
| `E`   | Edit settings (shell.json) in your editor |
| `1–9` | Switch host                     |
| `Esc` | Close the panel                 |

Bar icon: middle-click refreshes all hosts, right-click opens an SSH
terminal to the focused host.

## Settings

| Key                  | Default | Description                                    |
| -------------------- | ------- | ---------------------------------------------- |
| `sshHosts`           | *(empty)* | Colon-separated ssh host aliases to monitor  |
| `refreshIntervalSec` | `30`    | Focused-host refresh while the panel is open   |
| `panelWidth`         | `1000`   | Popup width in layout units                    |

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
