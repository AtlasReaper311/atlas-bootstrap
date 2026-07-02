# lib/portproxy.ps1
#
# Closes the documented gap: WSL2 gets a new IP on every reboot, and
# every netsh portproxy rule pointing at the old IP silently dies with
# it. This script refreshes the rules (delete-then-add, so it is
# idempotent and survives the IP change), opens one firewall rule for
# the set, and with -RegisterTask registers ITSELF as a SYSTEM
# scheduled task that re-runs at startup and logon.
#
#   .\portproxy.ps1                 # refresh rules now
#   .\portproxy.ps1 -RegisterTask   # refresh now + install the boot task
#
# Ports are the estate's local service set; adding a service is one
# entry here (and a re-run), nothing else.

#Requires -RunAsAdministrator

param(
    [switch]$RegisterTask,
    [int[]]$Ports = @(8000, 8080, 8081, 8091, 8092, 9000, 11434),
    [string]$Distro = "Ubuntu"
)

$ErrorActionPreference = "Stop"
$TaskName = "Atlas WSL2 Portproxy Refresh"
$RuleName = "Atlas WSL2 Portproxy"

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

# --- 2. Refresh the rules -----------------------------------------------------
# Delete-then-add per port: no stale rule survives, re-runs are safe.
foreach ($port in $Ports) {
    netsh interface portproxy delete v4tov4 listenport=$port listenaddress=0.0.0.0 2>$null | Out-Null
    netsh interface portproxy add v4tov4 listenport=$port listenaddress=0.0.0.0 connectport=$port connectaddress=$wslIp | Out-Null
    Write-Host ("  {0,-6} -> {1}:{0}" -f $port, $wslIp)
}

# --- 3. One firewall rule for the whole set -------------------------------------
$existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
if ($existing) { Remove-NetFirewallRule -DisplayName $RuleName }
New-NetFirewallRule -DisplayName $RuleName `
    -Direction Inbound -Action Allow -Protocol TCP `
    -LocalPort $Ports | Out-Null
Write-Host "  firewall rule refreshed: $RuleName"

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
