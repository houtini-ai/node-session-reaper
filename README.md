# node-session-reaper

Stops leaked **Claude Code** `node.exe` MCP servers from eating your machine — on
Windows, where killing the parent doesn't kill the children.

If you run Claude Code with a stack of MCP servers, you've probably watched
`node.exe` climb into the tens of GB over a day until the machine crawls. This is a
small, safe PowerShell reaper plus a scheduled task and a session hook that keep it
in check. It only ever kills servers that **no live Claude session owns** — it can't
touch a session you're using.

## Why node.exe piles up

Claude Code on Windows spawns every MCP server as a subprocess chain:

```
claude.exe ─▶ cmd.exe ─▶ node.exe          (npx servers double: ─▶ node ─▶ node)
```

Windows does **not** cascade-kill descendants when a parent dies. So:

1. **Closed sessions leave corpses.** A session that crashes or is hard-closed
   leaves its whole set of node MCP servers running, forever, holding their RAM.
2. **Finished Task subagents don't always exit.** A subagent that used MCP tools
   can linger with its full server set attached.
3. **Every session loads the *whole* MCP set.** ~15 servers × the npx double-spawn
   ≈ **~32 node procs / ~3 GB per session**. If you run several sessions (or an
   agent fleet), that multiplies fast — most of it *legitimate*, not leaked.

The reaper fixes #1 and #2 safely and automatically. #3 isn't a leak — the lever
there is loading fewer MCP servers per session, not killing anything.

## The safety rule

A process is **reapable only if it has no living owner.** The default sweep builds
the set of every process descending from a *live top-level* `claude.exe` session and
reaps only what's **outside** it — so it can never touch a running session's servers.
Ownerless `node.exe` is reaped only when its command line matches an MCP signature,
so your own node apps (Vite, Electron, dev servers) are left alone.

> **Idle ≠ dead.** An MCP server is idle ~99% of the time but still needed. The
> reaper keys on *ownership*, not idleness.

## Install

Requires **PowerShell 7** (`pwsh`). No admin rights needed.

```powershell
git clone https://github.com/houtini-ai/node-session-reaper
pwsh -File .\node-session-reaper\install.ps1
```

That registers:

| Entry point | What | Why |
|-------------|------|-----|
| Scheduled task `ClaudeNodeReaper` | ownerless sweep every 15 min | reclaims within 15 min of a session closing, even if you don't reopen Claude |
| SessionStart hook | ownerless sweep on launch | instant sweep of yesterday's corpses when you start a session |

The installer prints the exact `SessionStart` block to add to
`~\.claude\settings.json` if it isn't already there. It's idempotent — safe to
re-run.

## Manual use

```powershell
# safe ownerless sweep
pwsh -File reap.ps1 -WhatIf        # dry-run: show what would die
pwsh -File reap.ps1                # do it
pwsh -File reap.ps1 -All           # also reap ownerless node that ISN'T MCP-shaped

# idle finished Task subagents under a still-live session (attended only)
pwsh -File reap.ps1 -Zombies              # report candidates
pwsh -File reap.ps1 -Zombies -Execute     # kill them
pwsh -File reap.ps1 -Zombies -IdleSubagentHours 4   # only subagents ≥4h old
```

### Why `-Zombies` is attended and never scheduled

Killing a subagent *while its parent session is still open* needs judgement: "idle
right now" is a poor signal because a live subagent is idle between bursts too. An
early auto-version of this wanted to kill **118 processes** — including live workers,
`powershell.exe`, and `conhost.exe`. So `-Zombies` is fenced:

- **never a managed/resumable agent-mode session** — anything whose command line
  carries `--resume` or `local-agent-mode-sessions` (FleetView / cowork / delegate
  sessions) is skipped. Those are idle *between turns*, not finished; their state is
  on disk and you may resume them. On a multi-session box this exclusion means
  `-Zombies` usually finds nothing — which is correct;
- only subagents that actually **own node servers** (the RAM hogs);
- only those **≥ `IdleSubagentHours`** old (default 2);
- confirmed idle by a **CPU-rate** sample (a finished tree idles ≈ 0.17 ms/proc/s vs
  a working subagent ≈ 1.5 ms/proc/s), not an absolute threshold;
- it reaps only the tree's `node.exe`/`cmd.exe` + the subagent's own `claude.exe` —
  never anything else;
- **report-only** unless you add `-Execute`.

## Does killing a server break anything?

No — for anything the reaper touches. MCP servers aren't services; **Claude Code is
the only thing that starts them**, at session start and per-subagent. The reaper only
removes servers with no live session to need them; the next session or subagent spins
up a fresh set on demand. Live sessions and active subagents are never touched.

## Logs

Every real kill appends to `logs\node-reaper.log` — timestamp, count, RAM freed, and
every PID reaped. **Command lines are redacted** before logging or printing (API
keys, tokens, and Claude's `--mcp-config` env blob are stripped), so the log is safe
to keep and share.

## Uninstall

```powershell
Unregister-ScheduledTask -TaskName ClaudeNodeReaper -Confirm:$false
```

Then remove the `SessionStart` block from `~\.claude\settings.json`.

## Scope & caveats

- **Windows + PowerShell 7 only.** The whole point is Windows' lack of descendant
  cascade-kill; on macOS/Linux, Claude Code's own process-group teardown makes this
  mostly unnecessary.
- The reaper reads process ancestry from a single `Win32_Process` snapshot. Its
  worst-case failure mode is *under*-reaping (leaving a corpse for the next run),
  never a bad kill.

## License

MIT © Richard Baxter — see [LICENSE](LICENSE). Part of [houtini.ai](https://houtini.ai).
