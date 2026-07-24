<#
.SYNOPSIS
  Wires node-session-reaper into the two places that keep node.exe under control:
    1. a Windows Scheduled Task that runs the ownerless sweep every 15 min
    2. a Claude Code SessionStart hook that sweeps the instant a session launches

.DESCRIPTION
  reap.ps1 is referenced by absolute path from wherever you cloned this repo. Both
  entry points run the SAFE default mode (ownerless only): they can never touch a
  live session's MCP servers. The attended -Zombies mode is deliberately NOT
  scheduled — see README.

  Idempotent. Safe to re-run. Needs no admin rights (killing your own processes
  and creating a per-user task are unprivileged).
#>

$ErrorActionPreference = 'Stop'

$reap     = Join-Path $PSScriptRoot 'reap.ps1'
$pwsh     = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
$settings = Join-Path $env:USERPROFILE '.claude\settings.json'
$taskName = 'ClaudeNodeReaper'
$interval = 15   # minutes

Write-Host "node-session-reaper installer" -ForegroundColor Cyan
Write-Host "  repo: $PSScriptRoot"

if (-not (Test-Path $reap)) { throw "reap.ps1 missing from $reap — repo is incomplete." }
if (-not $pwsh)             { throw "pwsh (PowerShell 7) not found on PATH — install it or edit this script." }

# --- 1. the scheduled task -------------------------------------------------------
# Runs in the interactive user session (must, to see and kill the user's node
# procs). RunLevel Limited — killing your own processes needs no admin rights.
$action  = New-ScheduledTaskAction -Execute $pwsh `
             -Argument "-NoProfile -WindowStyle Hidden -File `"$reap`" -Quiet"
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) `
             -RepetitionInterval (New-TimeSpan -Minutes $interval)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
             -LogonType Interactive -RunLevel Limited
$settingsObj = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
             -DontStopIfGoingOnBatteries -StartWhenAvailable `
             -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settingsObj `
    -Description "Reaps ownerless Claude Code node.exe MCP servers every $interval min. Source: $reap" `
    -Force | Out-Null
Write-Host "  task:     '$taskName' registered — ownerless sweep every $interval min" -ForegroundColor Green

# --- 2. the SessionStart hook ----------------------------------------------------
if (Test-Path $settings) {
    if (Select-String -Path $settings -SimpleMatch 'node-session-reaper' -Quiet) {
        Write-Host "  hook:     SessionStart hook present in settings.json" -ForegroundColor Green
    } else {
        Write-Host "  hook:     NOT found in settings.json. Add under a top-level `"hooks`" key:" -ForegroundColor Yellow
        Write-Host @"
    "SessionStart": [
      { "hooks": [ { "type": "command",
        "command": "\"$pwsh\" -NoProfile -File \"$reap\" -Quiet" } ] } ]
"@
    }
} else {
    Write-Host "  hook:     settings.json not found at $settings — skipped." -ForegroundColor Yellow
}

# --- 3. smoke test ---------------------------------------------------------------
Write-Host "  test:     dry-run of the ownerless sweep —" -ForegroundColor Cyan
& $pwsh -NoProfile -File $reap -WhatIf -Quiet

Write-Host ""
Write-Host "Done. The scheduled task is live now; the hook fires on your next Claude session." -ForegroundColor Cyan
Write-Host "Manual zombie cleanup (attended):  pwsh -File `"$reap`" -Zombies        (report)" -ForegroundColor DarkGray
Write-Host "                                   pwsh -File `"$reap`" -Zombies -Execute (kill)" -ForegroundColor DarkGray
