# RUNBOOK

What the bootstrap does, in order, what each section changes, what to do when a section fails, and how to run any section alone. Both entry scripts are idempotent: the recovery move for almost everything is fix the cause, re-run the section.

## The shape

```
bootstrap.ps1 (Windows, elevated)
  Preflight -> Toolchain -> Wrangler -> WslEnsure -> DockerDesktop
  -> Portproxy (+ boot task) -> WslChain ─┐
                                          ▼
                          bootstrap.sh (WSL2 Ubuntu)
  preflight -> apt_packages -> docker_engine -> node_toolchain
  -> cloudflared_cli -> ollama_setup -> clone_repos -> seed_envs
  -> pull_models -> start_services -> health_check
```

Run one section in isolation:

```powershell
.\bootstrap.ps1 -Only Portproxy
```

```bash
bash bootstrap.sh --only clone_repos
```

## Windows sections

**Preflight.** Verifies winget and creates the base directory (default `L:\Atlas-Systems`). Fails only when winget is absent: install "App Installer" from the Microsoft Store.

**Toolchain.** winget installs, each skipped when present: git, gh, Node LTS, Python 3.12, cloudflared, Windows Terminal. A single package erroring warns and continues; re-run `-Only Toolchain` after fixing (usually a source agreement prompt or a pending reboot).

**Wrangler.** `npm install -g wrangler`. On a machine where Node was installed seconds ago, npm is not on this shell's PATH yet; the section says so. Open a new elevated shell, `-Only Wrangler`.

**WslEnsure.** Installs WSL2 + Ubuntu when missing, then deliberately exits: the install usually wants a reboot and always wants the Ubuntu first-run user creation. Reboot, create the user, re-run the whole script; every earlier section no-ops.

**DockerDesktop.** Skipped when native Docker Engine is detected inside WSL2, because the estate standard is the Engine and Docker Desktop's WSL integration fights it. `-ForceDockerDesktop` overrides.

**Portproxy.** Runs `lib\portproxy.ps1 -RegisterTask`: refreshes the port rules against the current WSL2 IP (delete-then-add), refreshes the one firewall rule, registers the SYSTEM task "Atlas WSL2 Portproxy Refresh" (at startup and at logon). This supersedes the old `ATLAS_BOOTSTRAP.bat` and closes its documented gap. If a service is unreachable from Windows after a reboot, this section is the first suspect: `-Only Portproxy` and retest.

**WslChain.** Translates the base path (`L:\...` to `/mnt/l/...`) and runs `bootstrap.sh` inside Ubuntu. A non-zero exit tells you which WSL section to re-run.

**Health.** `lib\health-check.ps1` probes every service through localhost, which is through the portproxy, so a green table proves the services and the proxy at once.

## WSL sections

**preflight.** Confirms systemd (WSL needs `systemd=true` in `/etc/wsl.conf`, then `wsl --shutdown`), takes sudo, creates the base dir.

**apt_packages.** git, curl, jq, unzip, python3 + venv + pip, and the gh CLI from GitHub's apt repo.

**docker_engine.** Native Engine from Docker's apt repo, enabled via systemd, user added to the docker group. Group membership lands on next login; this run transparently uses sudo. If `docker ps` fails tomorrow: log out and in, or `newgrp docker`.

**node_toolchain.** Node 22 LTS from NodeSource plus global wrangler.

**cloudflared_cli.** CLI only, from Cloudflare's apt repo. The tunnel service itself stays on Windows; nothing here touches it.

**ollama_setup.** Installs Ollama when missing and, always, writes the systemd drop-in binding `OLLAMA_HOST=0.0.0.0`, restarts, and waits for `/api/tags`. The drop-in survives Ollama upgrades; editing the unit file does not, which is why this is a drop-in. Failure: `journalctl -u ollama -n 50`.

**clone_repos.** `gh repo clone` for everything in `lib/repos.json` into the base dir; existing clones get `git pull --ff-only`. A pull that cannot fast-forward means local work: the repo is left untouched and warned about. Private repos without access warn and continue. Requires `gh auth login` once.

**seed_envs.** Copies `.env.example` to `.env` wherever `.env` is missing, then lists what it seeded. Secrets are never invented; see below.

**pull_models.** `ollama pull` for `lib/models.json`, skipping models already present. `qwen2.5:32b` is the long pole (~20GB); `--skip-models` defers the whole section for a fast bring-up.

**start_services.** `docker compose up -d` in each non-external service path from `lib/services.json`. Missing compose file warns and skips. atlas-corpus refusing to start means its fail-closed `CORPUS_SECRET` is still empty: that is the design working.

**health_check.** `lib/health-check.sh`; table plus non-zero exit when anything is down.

## Seeding secrets

`seed_envs` copies defaults; these need real values from Proton Pass before their services run:

| File | Key | Source |
|---|---|---|
| `atlas-corpus/.env` | `CORPUS_SECRET` | Proton Pass "atlas-corpus CORPUS_SECRET" |
| `atlas-corpus/.env` | `GITHUB_TOKEN` | Fine-grained PAT, public repo read |
| `ollama-rag-kit/.env` | `ATLAS_SECRET` | Proton Pass |

Then `bash bootstrap.sh --only start_services` and `--only health_check`.

## What this deliberately does not do

Cloudflare tunnel configuration (hostnames live in `C:\ProgramData\cloudflared\config.yml`, owned by the existing Windows service), wrangler login and Worker deploys (interactive auth, owned by each Worker repo's caller workflow), Home Assistant configuration (owned by ramone-voice-trigger's `ha-config/`), and Windows-side Docker (unless forced). Reconstruction is scoped to the machine; identity and edge stay where they already live.
