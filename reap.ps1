<#
.SYNOPSIS
  Reaps leaked Claude Code node.exe MCP servers (and their cmd wrappers and
  orphaned subagent claude.exe) — anything with no living Claude session to own it.

.DESCRIPTION
  The leak:  Claude Code on Windows spawns every MCP server as
      claude.exe -> cmd.exe -> node.exe        (npx servers double: -> node -> node)
  Windows does NOT cascade-kill descendants when a parent dies. So when a session
  crashes / is hard-closed, or a Task subagent finishes but never exits, its node
  MCP servers keep running and keep their RAM. Over a day this reaches tens of GB.

  DEFAULT MODE — ownerless sweep (safe, unattended):
    A process is reapable iff walking its parent chain reaches NO live top-level
    claude.exe session — it belongs to a Claude tree whose root is gone. This can
    never touch a running session's servers. Ownerless node.exe is reaped only
    when its command line matches an MCP signature, so a user's OWN node apps
    (Vite, Electron, dev servers — also parentless of claude) are left alone.
    Use -All to drop that signature guard. This is what the hook + scheduled task
    run.

  ZOMBIE MODE — -Zombies (attended only, NOT for the scheduler):
    Reports idle MCP-owning subagent trees under a STILL-LIVE session — finished
    Task subagents that never exited. It EXCLUDES managed / resumable agent-mode
    sessions (FleetView, cowork, delegate: cmdline has --resume or
    local-agent-mode-sessions) because those are idle BETWEEN TURNS, not finished,
    and killing one throws away live work. "Idle in a short sample" is not proof of
    death on its own, so this mode is REPORT-ONLY unless you pass -Execute, and it
    kills only the node.exe/cmd.exe MCP servers in the tree plus the subagent's own
    claude.exe — never powershell/conhost or anything else. Review before -Execute.

.PARAMETER WhatIf     Default mode: show what would be reaped, kill nothing.
.PARAMETER All        Default mode: reap any ownerless node.exe, not just MCP-shaped.
.PARAMETER Zombies    Switch to attended zombie-subagent mode (report-only by default).
.PARAMETER Execute    With -Zombies: actually kill the reported trees.
.PARAMETER IdleSubagentHours  -Zombies age gate: only subagents at least this old (default 2).
.PARAMETER Quiet      Suppress the per-process table (still logs + prints summary).
#>
param(
    [switch] $WhatIf,
    [switch] $All,
    [switch] $Zombies,
    [switch] $Execute,
    [double] $IdleSubagentHours = 2,
    [switch] $Quiet
)

$ErrorActionPreference = 'Stop'

# Redact secrets out of a command line before it is logged or printed. Process
# cmdlines routinely carry API keys (--api-key=..., tokens) and Claude's
# --mcp-config blob embeds every server's env secrets. Never emit them.
function Hide-Secrets([string]$s) {
    if (-not $s) { return '' }
    $s = $s -replace '"', ''
    $s = $s -replace '(?i)--mcp-config.*$', '--mcp-config <redacted>'                       # drop the env-secret blob
    $s = $s -replace '(?i)(api[-_ ]?key|token|password|secret|auth\w*|bearer)(["\s:=]+)\S+', '$1$2<redacted>'
    $s = $s -replace '(rk_live|rk_test|sk_live|sk_test|sk-|ctx7sk-|gho_|ghp_|github_pat_|AIza|xoxb-)[A-Za-z0-9_\-]{6,}', '<redacted>'
    $s = $s.Trim()
    if ($s.Length -gt 120) { $s = $s.Substring(0, 120) }
    return $s
}

# --- snapshot every process once ------------------------------------------------
$procs = Get-CimInstance Win32_Process |
    Select-Object ProcessId, ParentProcessId, Name, CommandLine, CreationDate, WorkingSetSize
$map  = @{}
$kids = @{}
foreach ($p in $procs) {
    $pid_ = [int]$p.ProcessId
    $ppid = [int]$p.ParentProcessId
    $map[$pid_] = $p
    if (-not $kids.ContainsKey($ppid)) { $kids[$ppid] = New-Object System.Collections.Generic.List[int] }
    $kids[$ppid].Add($pid_)
}

function Get-Subtree([int]$root) {
    $out  = New-Object System.Collections.Generic.List[int]
    $seen = New-Object System.Collections.Generic.HashSet[int]
    $stack = New-Object System.Collections.Generic.Stack[int]
    $stack.Push($root)
    while ($stack.Count) {
        $c = $stack.Pop()
        if (-not $seen.Add($c)) { continue }
        $out.Add($c)
        if ($kids.ContainsKey($c)) { foreach ($ch in $kids[$c]) { $stack.Push($ch) } }
    }
    return $out
}

# --- protected set = every descendant of a LIVE top-level claude session --------
# top-level = an alive claude.exe whose parent is NOT claude.exe (a subagent's is).
# Failure mode of this rule is under-reaping (safe), never a bad kill: a live
# session and all its subagents/servers are always inside a protected tree.
$roots = $procs | Where-Object {
    $_.Name -eq 'claude.exe' -and $map[[int]$_.ParentProcessId].Name -ne 'claude.exe'
}
$protected = New-Object System.Collections.Generic.HashSet[int]
foreach ($r in $roots) { foreach ($id in (Get-Subtree ([int]$r.ProcessId))) { [void]$protected.Add($id) } }

# guard: never kill the reaper itself or anything above it, no matter the mode
$guard = New-Object System.Collections.Generic.HashSet[int]
$cur = [int]$PID
while ($cur -and $map.ContainsKey($cur)) { [void]$guard.Add($cur); $cur = [int]$map[$cur].ParentProcessId }

# --- MCP command-line signature -------------------------------------------------
# Marks node/cmd that are Claude-spawned MCP servers. Deliberately narrow so it
# cannot match a user's own dev server (those cmdlines carry none of these).
$sig = '(?i)\\MCP\\|/mcp/|npm-cache\\_npx|npx-cli\.js|@modelcontextprotocol|mcp-server|-mcp\b|chrome-devtools|\\dist\\index\.js|\\build\\cli\.js'

$reap    = @{}   # pid -> proc, deduped
$reasons = @{}   # pid -> why

# ================================================================================
if (-not $Zombies) {
    # ---------- DEFAULT: ownerless MCP node, cmd wrapper, orphaned subagent claude
    foreach ($p in $procs) {
        $id = [int]$p.ProcessId
        if ($protected.Contains($id) -or $guard.Contains($id)) { continue }
        switch ($p.Name) {
            'node.exe'   { if ($All -or ($p.CommandLine -and $p.CommandLine -match $sig)) { $reap[$id]=$p; $reasons[$id]='ownerless-node' } }
            'cmd.exe'    { if ($p.CommandLine -and $p.CommandLine -match $sig)             { $reap[$id]=$p; $reasons[$id]='ownerless-wrapper' } }
            'claude.exe' {                                                                   $reap[$id]=$p; $reasons[$id]='orphaned-subagent' }
        }
    }
}
else {
    # ---------- ZOMBIE: idle MCP-owning subagent trees under a live session --------
    $now = Get-Date
    $subs = $procs | Where-Object {
        $_.Name -eq 'claude.exe' -and
        $map[[int]$_.ParentProcessId].Name -eq 'claude.exe' -and         # a real subagent
        (($now - $_.CreationDate).TotalHours -ge $IdleSubagentHours) -and # old enough
        $protected.Contains([int]$_.ProcessId) -and                       # under a live root
        -not $guard.Contains([int]$_.ProcessId) -and
        # NEVER a managed / resumable agent-mode session (FleetView, cowork, delegate).
        # Those are idle BETWEEN TURNS, not finished — their state is on disk and the
        # user may resume them. Only genuinely ephemeral Task subagents are fair game.
        ($_.CommandLine -notmatch 'local-agent-mode-sessions|--resume')
    }
    # keep only subagents that actually OWN node MCP servers (the RAM hogs);
    # skip lightweight zero-node subagents entirely.
    $subtrees = @{}
    foreach ($s in $subs) {
        $st = Get-Subtree ([int]$s.ProcessId)
        $ownsNode = $false
        foreach ($id in $st) { if ($map[$id].Name -eq 'node.exe') { $ownsNode = $true; break } }
        if ($ownsNode) { $subtrees[[int]$s.ProcessId] = $st }
    }
    if ($subtrees.Count) {
        function TreeCpuMs($ids) {
            $sum = 0.0
            foreach ($id in $ids) { try { $sum += (Get-Process -Id $id -ErrorAction Stop).TotalProcessorTime.TotalMilliseconds } catch {} }
            return $sum
        }
        $sampleSec = 4
        $t1 = @{}; foreach ($k in $subtrees.Keys) { $t1[$k] = TreeCpuMs $subtrees[$k] }
        Start-Sleep -Seconds $sampleSec
        foreach ($k in $subtrees.Keys) {
            $delta = (TreeCpuMs $subtrees[$k]) - $t1[$k]
            # rate per process per second — size-independent. Measured: a finished
            # zombie tree idles at ~0.17 ms/proc/s; a working subagent ~1.5 ms/proc/s.
            $rate = $delta / [math]::Max(1,$subtrees[$k].Count) / $sampleSec
            if ($rate -lt 0.5) {   # idle
                foreach ($id in $subtrees[$k]) {
                    if ($guard.Contains($id)) { continue }
                    $n = $map[$id].Name
                    if ($n -eq 'node.exe' -or $n -eq 'cmd.exe' -or $id -eq $k) {   # servers, wrappers, the subagent itself
                        if ($n -eq 'node.exe' -and -not $All -and -not ($map[$id].CommandLine -and $map[$id].CommandLine -match $sig)) { continue }
                        $reap[$id] = $map[$id]; $reasons[$id] = 'zombie-subagent'
                    }
                }
            }
        }
    }
}

# --- report + act ---------------------------------------------------------------
$logDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
$log    = Join-Path $logDir 'node-reaper.log'
$stamp  = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

$targets = $reap.Values |
    Select-Object @{n='PID';e={[int]$_.ProcessId}}, Name,
        @{n='RAM_MB';e={[math]::Round($_.WorkingSetSize/1MB)}},
        @{n='Why';e={$reasons[[int]$_.ProcessId]}},
        @{n='Cmd';e={ Hide-Secrets $_.CommandLine }} |
    Sort-Object RAM_MB -Descending

$freedMb = if ($targets) { [math]::Round((($reap.Values | Measure-Object WorkingSetSize -Sum).Sum)/1MB) } else { 0 }

# decide whether this invocation actually kills
$willKill = if ($Zombies) { [bool]$Execute } else { -not $WhatIf }
$mode     = if ($Zombies) { if ($Execute) {'ZOMBIE-KILL'} else {'ZOMBIE-REPORT'} } else { if ($WhatIf) {'WHATIF'} else {'REAP'} }

if (-not $Quiet -and $targets) { $targets | Format-Table -AutoSize | Out-String | Write-Host }

if ($targets) {
    $killed = 0
    if ($willKill) {
        # kill leaves (node/cmd) before claude parents
        foreach ($t in ($targets | Sort-Object @{e={$_.Name -eq 'claude.exe'}})) {
            try { Stop-Process -Id $t.PID -Force -ErrorAction Stop; $killed++ } catch {}
        }
    }
    $summary = "[$stamp] $mode  procs=$($targets.Count)  freed~${freedMb}MB  killed=$killed  all=$($All.IsPresent)"
    if ($willKill) {
        Add-Content -Path $log -Value $summary
        foreach ($t in $targets) { Add-Content -Path $log -Value ("    {0,-6} {1,-11} {2,5}MB {3,-18} {4}" -f $t.PID,$t.Name,$t.RAM_MB,$t.Why,$t.Cmd) }
    }
    $color = if ($willKill) {'Green'} else {'Yellow'}
    Write-Host $summary -ForegroundColor $color
    if ($Zombies -and -not $Execute) { Write-Host "  report only — re-run with -Zombies -Execute to kill these." -ForegroundColor Yellow }
} else {
    $what = if ($Zombies) {'no idle MCP-owning zombie subagents'} else {'no ownerless MCP processes'}
    Write-Host "[$stamp] nothing to reap ($what)." -ForegroundColor DarkGray
}
