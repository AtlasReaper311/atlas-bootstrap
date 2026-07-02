# lib/health-check.ps1
#
# Windows-side verification: probes every service in services.json
# through localhost, which means through the portproxy rules, so a
# green table here proves both the services AND the proxy layer. Any
# HTTP answer counts as UP (an auth-gated 401 is a living service);
# only connection failure or timeout is DOWN.
#
# Written for Windows PowerShell 5.1 (no -SkipHttpErrorCheck), so it
# runs on a machine bootstrap has not finished with yet.
#
#   powershell -ExecutionPolicy Bypass -File .\lib\health-check.ps1

$ErrorActionPreference = "Stop"
$lib = $PSScriptRoot
$failed = $false

$services = (Get-Content (Join-Path $lib "services.json") -Raw | ConvertFrom-Json).services

Write-Host ("{0,-22} {1,-8} {2}" -f "SERVICE", "STATE", "DETAIL")
Write-Host ("{0,-22} {1,-8} {2}" -f "-------", "-----", "------")

foreach ($service in $services) {
    $state = "DOWN"
    $detail = $service.health
    try {
        $response = Invoke-WebRequest -Uri $service.health -UseBasicParsing -TimeoutSec 5
        $state = "UP"
        $detail = "$($service.health) (HTTP $($response.StatusCode))"
    } catch {
        if ($_.Exception.Response) {
            # The service answered with an error status: it is alive.
            $state = "UP"
            $code = [int]$_.Exception.Response.StatusCode
            $detail = "$($service.health) (HTTP $code)"
        } else {
            $failed = $true
        }
    }
    $colour = if ($state -eq "UP") { "Green" } else { "Red" }
    Write-Host ("{0,-22} " -f $service.name) -NoNewline
    Write-Host ("{0,-8} " -f $state) -ForegroundColor $colour -NoNewline
    Write-Host $detail
}

if ($failed) {
    Write-Host "`nSomething is down. RUNBOOK.md maps each service to its fix." -ForegroundColor Red
    exit 1
}
Write-Host "`nAll services answering through the portproxy." -ForegroundColor Green
