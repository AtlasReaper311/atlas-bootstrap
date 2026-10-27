# lib/portproxy.ps1
#
# Closes the documented gap: WSL2 gets a new IP on every reboot, and
# every netsh portproxy rule pointing at the old IP silently dies with
# it. This script refreshes the rules (delete-then-add, so it is
# idempotent and survives the IP change), opens a firewall rule for any
# port that is deliberately published, and with -RegisterTask registers
# ITSELF as a SYSTEM scheduled task that re-runs at startup and logon.
#
#   .\portproxy.ps1                 # refresh rules now
#   .\portproxy.ps1 -RegisterTask   # refresh now + install the boot task
#
# Ports are the estate's local service set; adding a service is one
# entry here (and a re-run), nothing else.
#
# LISTEN ADDRESSES ARE PER PORT, AND LOOPBACK IS THE DEFAULT.
# An entry is either "<port>", which listens on 127.0.0.1 and is reachable
# from this machine only, or "<port>:0.0.0.0", which publishes it on every
# address the machine has -- the LAN and the tailnet included.
#
# This used to hard-code 0.0.0.0 for every port, which published the whole
# set to the house network. Ollama (11434) has no authentication of any
# kind, so that rule left a password-free model server on the wi-fi. Thirty
# days of its logs contained no caller from outside this machine, so nothing
# was using it.
#
# Loopback is also the better default on a WSL2 host, not just the safer
# one. WSL forwards loopback publishes to Windows itself through wslrelay,
# so a loopback-only service is already reachable from Windows with no rule
# at all -- and a 0.0.0.0 rule here actively BREAKS that, because it binds
# the Windows port first so wslrelay never gets it, then forwards to the WSL
# VM's external address where a loopback-only container is not listening.
# That is how 8091 and 8092 came to be rules that answered nothing.
#
# To reach a service from another device, prefer Tailscale Serve over
# publishing the port. Serve proxies to 127.0.0.1, is tailnet-only, and adds
# TLS, so it gives remote access without opening anything to the house
# network. Open WebUI and Ollama are both reached that way on SPECULAR-CORE.

#Requires -RunAsAdministrator

param(
    [switch]$RegisterTask,
    # "<port>" = loopback only. "<port>:0.0.0.0" = published, opt in per port.
    #
    # A port belongs here only if its service binds a non-loopback address
    # INSIDE WSL, because that is what the rule forwards to. Measured on
    # 2026-10-27:
    #
    #   3000   0.0.0.0:3000     Open WebUI    rule works
    #   9000   0.0.0.0:9000     telemetry     rule works
    #   11434  *:11434          Ollama        rule works
    #   8093   127.0.0.1:8093   RAG kit       loopback-only -> rule forwards nowhere
    #   8091   127.0.0.1:8091   Ramone Memory loopback-only -> rule forwards nowhere
    #   8092   -                corpus moved to 18092
    #   8000/8080/8081          nothing listening at all
    #
    # The bottom four groups were removed. A rule for them is worse than
    # useless: it binds the Windows port, so wslrelay never mirrors the real
    # loopback publish, and then forwards to an address nothing is listening
    # on. 8091 and 8092 had been doing exactly that, and 8091 was why Ramone
    # Memory was unreachable from Windows.
    #
    # 9000 is the only published entry, and it has NOT been reviewed: it is a
    # real service and something on the network may rely on it. Narrow it to
    # loopback only after checking that.
    [string[]]$Ports = @('3000', '9000:0.0.0.0', '11434'),
    [string]$Distro = "Ubuntu"
)

$ErrorActionPreference = "Stop"
$TaskName = "Atlas WSL2 Portproxy Refresh"
$RuleName = "Atlas WSL2 Portproxy"
$LoopbackOnly = "127.0.0.1"

# --- 0. Parse the port set --------------------------------------------------
$spec = foreach ($entry in $Ports) {
    $bits = "$entry".Split(":", 2)
    $port = 0
    if (-not [int]::TryParse($bits[0].Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw "Bad port entry '$entry'. Use '<port>' or '<port>:0.0.0.0'."
    }
    $listen = if ($bits.Count -eq 2 -and $bits[1].Trim()) { $bits[1].Trim() } else { $LoopbackOnly }
    if ($listen -notmatch "^\d+\.\d+\.\d+\.\d+$") {
        throw "Bad listen address '$listen' in entry '$entry'."
    }
    [pscustomobject]@{ Port = $port; Listen = $listen }
}

# --- 1. Current WSL2 IP -----------------------------------------------------
# Asking for the IP also boots the distro if it is down, which is
# exactly what a startup task needs.
$raw = wsl -d $Distro -- hostname -I 2>$null
# wsl.exe output can carry interleaved UTF-16 nulls when captured;
# strip them before parsing or the regex match below fails silently.
$wslIp = (($raw | Out-String) -replace "`0", "").Trim().Split(" ")[0]
if (-not $wslIp -or $wslIp -notmatch "^\d+\.\d+\.\d+\.\d+$") {
    throw "Could not read the WSL2 IP from distro '$Distro'. Is it installed? (wsl -l -v)"
}
Write-Host "portproxy // WSL2 ($Distro) is at $wslIp" -ForegroundColor Yellow

# --- 2. Refresh the rules ---------------------------------------------------
# Delete-then-add per port: no stale rule survives, re-runs are safe.
#
# Both candidate listen addresses are deleted first, not just the one being
# added. Without that, a port that used to be published would keep its old
# 0.0.0.0 rule and the loopback rule would never take effect -- so a re-run
# would silently fail to narrow anything.
foreach ($s in $spec) {
    foreach ($old in @("0.0.0.0", $LoopbackOnly)) {
        netsh interface portproxy delete v4tov4 listenport=$($s.Port) listenaddress=$old 2>$null | Out-Null
    }
    netsh interface portproxy add v4tov4 `
        listenport=$($s.Port) listenaddress=$($s.Listen) `
        connectport=$($s.Port) connectaddress=$wslIp | Out-Null

    $note = if ($s.Listen -eq $LoopbackOnly) { "this machine only" } else { "PUBLISHED on $($s.Listen)" }
    Write-Host ("  {0,-6} {1,-15} -> {2}:{0}   {3}" -f $s.Port, $s.Listen, $wslIp, $note)
}

# --- 3. Firewall rule, for published ports only -----------------------------
# A loopback listener needs no inbound rule, so the rule covers only the
# ports deliberately published. The previous version opened one rule across
# the whole set, which meant narrowing a listener left its firewall hole
# behind.
$published = @($spec | Where-Object { $_.Listen -ne $LoopbackOnly } | Select-Object -ExpandProperty Port)

$existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
if ($existing) { Remove-NetFirewallRule -DisplayName $RuleName }

if ($published.Count -gt 0) {
    New-NetFirewallRule -DisplayName $RuleName `
        -Direction Inbound -Action Allow -Protocol TCP `
        -LocalPort $published | Out-Null
    Write-Host "  firewall rule refreshed for published ports: $($published -join ', ')"
} else {
    Write-Host "  no published ports, so no firewall rule is needed"
}

# --- 4. Optionally register the boot task ----------------------------------------
if ($RegisterTask) {
    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    # Startup covers reboots; logon covers fast-startup resumes where
    # the startup trigger can be skipped but WSL still re-addresses.
    $triggers = @(
        (New-ScheduledTaskTrigger -AtStartup),
        (New-ScheduledTaskTrigger -AtLogOn)
    )
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable
    Register-ScheduledTask -TaskName $TaskName `
        -Action $action -Trigger $triggers -Principal $principal -Settings $settings | Out-Null
    Write-Host "  boot task registered: $TaskName" -ForegroundColor Green
}

Write-Host "portproxy // done" -ForegroundColor Green
