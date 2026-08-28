#!/usr/bin/env bun

import { collectSnapshot } from "./collect";
import { collectTailnetSnapshot } from "./tailnet";

function usage(): string {
  return `Usage: server-status <status|tailnet> [--host <ssh-host>] [--compact]

Collect host and Docker metrics from a remote server over one read-only
SSH round trip, or discover every node from the local Tailscale network.
Nothing is installed or written on any node.`;
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  let command = "status";
  let sshHost = "";
  let compact = false;

  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index];
    if (argument === "status" || argument === "tailnet") command = argument;
    else if (argument === "help" || argument === "--help" || argument === "-h") command = "help";
    else if (argument === "--compact") compact = true;
    else if (argument === "--host") {
      const value = args[index + 1];
      if (!value) {
        console.error("--host requires an ssh host alias");
        process.exitCode = 2;
        return;
      }
      sshHost = value;
      index += 1;
    } else {
      console.error(`Unknown argument: ${argument}`);
      console.error(usage());
      process.exitCode = 2;
      return;
    }
  }

  if (command === "help") {
    console.log(usage());
    return;
  }
  if (command === "tailnet") {
    const snapshot = await collectTailnetSnapshot();
    console.log(JSON.stringify(snapshot, null, compact ? 0 : 2));
    return;
  }
  if (sshHost === "") {
    console.error("--host is required");
    console.error(usage());
    process.exitCode = 2;
    return;
  }

  const snapshot = await collectSnapshot(sshHost);
  console.log(JSON.stringify(snapshot, null, compact ? 0 : 2));
}

await main();
