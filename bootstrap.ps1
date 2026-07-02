# bootstrap.ps1
#
# Windows side of the Atlas Systems environment. Fully idempotent:
# every section checks before it changes. By default it finishes by
# chaining into WSL2 and running bootstrap.sh there, so one elevated
# command takes a bare Windows machine to the working estate.
#
#   powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1
#   .\bootstrap.ps1 -Base "L:\Atlas-Systems"
#   .\bootstrap.ps1 -Only Portproxy
#   .\bootstrap.ps1 -SkipWsl
#
# Sections, in order: Preflight Toolchain Wrangler WslEnsure
# DockerDesktop Portproxy WslChain Health

#Requires -RunAsAdministrator

param(
    [string]$Base = "L:\Atlas-Systems",
    [ValidateSet("", "Preflight", "Toolchain", "Wrangler", "WslEnsure",
                 "DockerDesktop", "Portproxy", "WslChain", "Health")]
    [string]$Only = "",
    [switch]$SkipWsl,
    [switch]$ForceDockerDesktop,
    [string]$Distro = "Ubuntu"
)

$ErrorActionPreference = "Stop"

function Log($msg)  { Write-Host "[bootstrap] $msg" -ForegroundColor Yellow }
function Warn($msg) { Write-Host "[bootstrap] $msg" -ForegroundColor Red }

function Convert-ToWslPath([string]$WindowsPath) {
    # L:\Atlas-Systems -> /mnt/l/Atlas-Systems
    $drive = $WindowsPath.Substring(0, 1).ToLower()
    $rest = $WindowsPath.Substring(2).Replace("\", "/")
    return "/mnt/$drive$rest"
}

function Test-WingetPackage([string]$Id) {
    $out = winget list --id $Id --exact --accept-source-agreements 2>$null
    return ($LASTEXITCODE -eq 0 -and ($out | Select-String -SimpleMatch $Id))
}

function Install-WingetPackage([string]$Id, [string]$Label) {
    if (Test-WingetPackage $Id) {
        Log "  ${Label}: present"
        return
    }
    Log "  ${Label}: installing"
    winget install --id $Id --exact --silent `
        --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { Warn "  ${Label}: winget exited $LASTEXITCODE (continuing)" }
}

# --------------------------------------------------------------------- #
function Invoke-Preflight {
    Log "Preflight"
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "winget is missing. Install 'App Installer' from the Microsoft Store, then re-run."
    }
    if (-not (Test-Path $Base)) {
        New-Item -ItemType Directory -Force -Path $Base | Out-Null
    }
    Log "  base directory: $Base"
}

# --------------------------------------------------------------------- #
function Invoke-Toolchain {
    Log "Toolchain (winget, idempotent)"
    Install-WingetPackage "Git.Git"                    "git"
    Install-WingetPackage "GitHub.cli"                 "gh"
    Install-WingetPackage "OpenJS.NodeJS.LTS"          "node LTS"
    Install-WingetPackage "Python.Python.3.12"         "python 3.12"
    Install-WingetPackage "Cloudflare.cloudflared"     "cloudflared"
    Install-WingetPackage "Microsoft.WindowsTerminal"  "windows terminal"
}

# --------------------------------------------------------------------- #
function Invoke-Wrangler {
    Log "Wrangler (npm global)"
    $npm = Get-Command npm -ErrorAction SilentlyContinue
    if (-not $npm) {
        Warn "  npm not on PATH yet (fresh Node install); open a new elevated shell and re-run: .\bootstrap.ps1 -Only Wrangler"
        return
    }
    npm ls -g --depth=0 wrangler *> $null
    if ($LASTEXITCODE -ne 0) {
        Log "  installing wrangler"
        npm install -g wrangler | Out-Null
    } else {
        Log "  wrangler: present"
    }
}

# --------------------------------------------------------------------- #
function Invoke-WslEnsure {
    Log "WslEnsure"
    # wsl.exe management output is UTF-16 and can carry interleaved
    # nulls when captured; strip them or -contains never matches.
    $distros = wsl -l -q 2>$null | ForEach-Object { ($_ -replace "`0", "").Trim() } | Where-Object { $_ }
    if ($distros -contains $Distro) {
        Log "  ${Distro}: present"
        return
    }
    Log "  installing WSL2 + $Distro (a reboot is usually required after this)"
    wsl --install -d $Distro
    Warn "  Reboot, finish the Ubuntu first-run user setup, then re-run this script."
    exit 0
}

# --------------------------------------------------------------------- #
function Invoke-DockerDesktop {
    Log "DockerDesktop"
    # The estate standard is native Docker Engine inside WSL2 (installed
    # by bootstrap.sh). Docker Desktop on top of that fights it for the
    # WSL integration, so it is skipped when the Engine is detected.
    if (-not $ForceDockerDesktop) {
        wsl -d $Distro -- bash -lc "command -v docker" *> $null
        if ($LASTEXITCODE -eq 0) {
            Log "  native Engine detected in WSL2; Docker Desktop skipped (-ForceDockerDesktop to override)"
            return
        }
    }
    Install-WingetPackage "Docker.DockerDesktop" "docker desktop"
}

# --------------------------------------------------------------------- #
function Invoke-Portproxy {
    Log "Portproxy (rules now + boot task)"
    & (Join-Path $PSScriptRoot "lib\portproxy.ps1") -RegisterTask -Distro $Distro
}

# --------------------------------------------------------------------- #
function Invoke-WslChain {
    if ($SkipWsl) { Log "WslChain skipped (-SkipWsl)"; return }
    Log "WslChain (running bootstrap.sh inside $Distro)"
    $wslBase = Convert-ToWslPath $Base
    $wslRepo = Convert-ToWslPath $PSScriptRoot
    wsl -d $Distro -- bash -lc "cd '$wslRepo' && bash bootstrap.sh --base '$wslBase'"
    if ($LASTEXITCODE -ne 0) {
        Warn "  bootstrap.sh exited $LASTEXITCODE; re-run inside WSL with --only <section> (RUNBOOK.md)"
    }
}

# --------------------------------------------------------------------- #
function Invoke-Health {
    Log "Health (Windows side, through the portproxy)"
    & (Join-Path $PSScriptRoot "lib\health-check.ps1")
}

# --------------------------------------------------------------------- #
$sections = [ordered]@{
    "Preflight"     = { Invoke-Preflight }
    "Toolchain"     = { Invoke-Toolchain }
    "Wrangler"      = { Invoke-Wrangler }
    "WslEnsure"     = { Invoke-WslEnsure }
    "DockerDesktop" = { Invoke-DockerDesktop }
    "Portproxy"     = { Invoke-Portproxy }
    "WslChain"      = { Invoke-WslChain }
    "Health"        = { Invoke-Health }
}

if ($Only) {
    & $sections[$Only]
} else {
    foreach ($name in $sections.Keys) { & $sections[$name] }
    Log "done. New PATH entries (node, python, gh) need a fresh shell."
}
