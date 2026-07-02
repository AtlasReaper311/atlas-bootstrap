<div align="center">
  <img src="https://raw.githubusercontent.com/AtlasReaper311/AtlasReaper311/main/atlas-icon-dark-256.png" width="88" alt="Atlas Systems"/>
</div>

# atlas-bootstrap

```
┌─────────────────────────────────────────────┐
│  ATLAS SYSTEMS // atlas-bootstrap           │
│  a machine is cattle: one command from      │
│  bare windows to the working estate         │
└─────────────────────────────────────────────┘
```

![PowerShell](https://img.shields.io/badge/windows-powershell-f5a623?style=flat-square&labelColor=0a0a0f)
![Bash](https://img.shields.io/badge/wsl2-bash-4ade80?style=flat-square&labelColor=0a0a0f)
![Idempotent](https://img.shields.io/badge/re--runs-converge-aaa9a0?style=flat-square&labelColor=0a0a0f)
![Cost](https://img.shields.io/badge/cost-%C2%A30-aaa9a0?style=flat-square&labelColor=0a0a0f)

Complete environment reconstruction for SPECULAR-CORE, or its successor, or a loaner in a hotel room. One elevated command on bare Windows installs the toolchain, ensures WSL2, fixes the portproxy drift for good, then chains into Ubuntu to install Docker Engine, Node, Ollama (bound `0.0.0.0` via drop-in), clones the estate, seeds `.env` files, pulls the models, starts the services, and proves the lot with a health table. Everything is idempotent: re-runs converge, they never duplicate.

```
bootstrap.ps1 ── toolchain · WSL2 · portproxy(+boot task) ──▶ bootstrap.sh
                                                              apt · docker · node
                                                              ollama(0.0.0.0) · clone
                                                              .env seed · models
                                                              compose up · health ✓
```

## Prerequisites

- Windows 10/11 with winget ("App Installer") and an elevated PowerShell
- A GitHub account with access to the estate; `gh auth login` runs once inside WSL
- ~30GB free for models (`qwen2.5:32b` is the long pole); `--skip-models` defers it

## Setup

Get the repo onto the machine (zip download works on a truly bare box), then:

```powershell
cd L:\Atlas-Systems\atlas-bootstrap
powershell -ExecutionPolicy Bypass -File .\bootstrap.ps1
```

Fresh machines pause twice by design: once after WSL2 installs (reboot, create the Ubuntu user, re-run; everything done so far no-ops) and once when `gh` wants `gh auth login`. After the run, fill the seeded secrets from Proton Pass (RUNBOOK, "Seeding secrets") and finish:

```bash
bash bootstrap.sh --only start_services
bash bootstrap.sh --only health_check
```

WSL-only usage works too: `bash bootstrap.sh --base /mnt/l/Atlas-Systems`.

## Usage

```powershell
.\bootstrap.ps1 -Only Portproxy        # refresh port rules + boot task
.\bootstrap.ps1 -SkipWsl               # Windows side only
```

```bash
bash bootstrap.sh --only clone_repos   # any single section
bash bootstrap.sh --skip-models        # fast bring-up, pull later
bash lib/health-check.sh               # the proof, on demand
```

Every section, every failure mode, and every recovery move is in [RUNBOOK.md](RUNBOOK.md).

## What gets installed

| Layer | Windows | WSL2 Ubuntu |
|---|---|---|
| VCS + CLI | git, gh | git, gh, jq |
| Runtimes | Node LTS, Python 3.12 | Node 22, Python 3.12 |
| Edge tooling | wrangler, cloudflared | wrangler, cloudflared (CLI only) |
| Containers | skipped when native Engine exists | Docker Engine + compose plugin |
| Models | (host is WSL) | Ollama + llama3.1:8b, qwen2.5:32b, nomic-embed-text |
| Glue | portproxy rules + SYSTEM boot task | systemd drop-in: `OLLAMA_HOST=0.0.0.0` |

## Design notes

**The portproxy gap is closed, not patched.** WSL2 re-addresses on every reboot; the old `ATLAS_BOOTSTRAP.bat` refreshed rules only when remembered. `lib/portproxy.ps1` refreshes delete-then-add (idempotent against the drift) and registers itself as a SYSTEM task at startup and logon, so the fix survives the next reboot without anyone remembering anything.

**Docker Desktop yields to the Engine.** The estate runs native Docker Engine inside WSL2; Desktop's WSL integration fights it. The section detects the Engine and skips Desktop, `-ForceDockerDesktop` for machines that genuinely want it.

**Secrets are seeded, never invented.** `.env.example` becomes `.env` with defaults; the run then names exactly which keys need Proton Pass values. atlas-corpus refusing to start on an empty `CORPUS_SECRET` is its fail-closed design working, and the health table makes that visible instead of silent.

**Config over code.** Repos, services, health endpoints, and models live in `lib/*.json`; the next service is a JSON entry and a re-run, not a script edit.

## How it fits into Atlas Systems

This is the estate's recovery position. It clones every repo including [`ramone-memory`](https://github.com/AtlasReaper311/ramone-memory) and [`atlas-corpus`](https://github.com/AtlasReaper311/atlas-corpus) and starts their stacks, keeps [`specular-telemetry`](https://github.com/AtlasReaper311/specular-telemetry) and [`atlas-corpus`](https://github.com/AtlasReaper311/atlas-corpus) reachable through the portproxy it now owns, and encodes the Ollama binding that [`ollama-rag-kit`](https://github.com/AtlasReaper311/ollama-rag-kit) and everything above it depend on.

An environment that exists only as the current state of one machine is a liability with an uptime; writing it as code is what turns hardware loss from a crisis into an afternoon.

---

Part of [atlas-systems.uk](https://atlas-systems.uk)
