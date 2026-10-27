# rag-estate

The private retrieval stack: Qdrant plus the three services that use it.

| service | host port | notes |
| --- | --- | --- |
| `qdrant` | none | private network only, TLS, API key required |
| `ramone-memory` | `8091` | gated on Qdrant being healthy |
| `atlas-corpus` | `18092` | container port is 8092 |
| `ollama-rag-kit` | `8093` | container port is 8000 |

## Bringing it up

**Two environment files are needed, and only one is passed as `--env-file`.**
`qdrant.env` has to be sourced into the environment first:

```sh
set -a
. /path/to/runtime-secrets/rag-estate/qdrant.env
set +a
docker compose \
  --env-file /path/to/runtime-secrets/rag-estate/runtime-live.env \
  -f compose.yaml up -d
```

Passing both as `--env-file` works too. What does **not** work is passing only
`runtime-live.env`, because the compose file declares the key as
`${QDRANT__SERVICE__API_KEY:?...}` and will refuse to start rather than run an
unauthenticated vector store. If you see

```
required variable QDRANT__SERVICE__API_KEY is missing a value
```

that is this, not a broken compose file.

See `runtime-live.env.example` and `qdrant.env.example` for the variable names.

### One generated file has to sit beside compose.yaml

`ollama-rag-kit` declares a **relative** `env_file` entry:

```yaml
      - path: model-endpoint.env
        required: true
```

Relative paths resolve against the compose file's own directory, so
`model-endpoint.env` must exist next to the deployed `compose.yaml` — not in the
secret directory with the others. It holds one variable, `OPENAI_BASE_URL`, and
it is **generated**, not hand-written: on SPECULAR-CORE the llama.cpp launcher
`L:\Models\llama-cuda\start-ramone-mtp-cuda.ps1` writes the current endpoint
into it each time it starts, which is how the RAG kit follows the model server
when the WSL IP changes.

Consequences worth knowing:

- `docker compose config` on a copy of this file in another directory fails with
  `env file .../model-endpoint.env not found`. That is the relative path, not a
  broken compose file.
- A rebuild must start the model server (which writes the file) before bringing
  this stack up, or create the file by hand first. See
  `model-endpoint.env.example`.

## Why the private subnet is pinned

`rag-private` pins `10.80.0.0/24` on purpose. Docker allocates from
`172.17.0.0/12` and, once that pool is exhausted, falls through to
`192.168.0.0/16` in `/20` slices.

On 2026-10-13 a rehearsal left seven unused networks behind. The 172 pool ran
out, and `rag-estate_private` was created on `192.168.0.0/20` — which swallows a
`192.168.0.0/24` house LAN, gateway included. The symptom was indirect and took
a while to pin down: from inside WSL and from Home Assistant the whole LAN
became unreachable, and the router's address resolved to WSL's own loopback.

`10.80.0.0/24` sits outside every pool Docker allocates from, so no future
network can be handed an overlapping range however many are left lying around.

`rag-publish` is deliberately **not** pinned. It does not overlap a typical
house LAN, and on SPECULAR-CORE a cloudflared container is attached to it
without being part of this compose project — so compose cannot remove or
recreate that network, and pinning a different subnet would make `up` fail. Pin
it only in a window where that container is detached on purpose.

## Host ports are loopback-only, on purpose

All three services publish to `127.0.0.1` rather than `0.0.0.0`. On a WSL2 host
that is the better default: WSL forwards loopback publishes to Windows itself
through `wslrelay`, so they are reachable from Windows without any extra rule.

Adding a `netsh portproxy` rule for one of these ports is counterproductive. The
rule binds `0.0.0.0:<port>` on Windows, which covers `127.0.0.1`, so `wslrelay`
never gets the port — and the rule then forwards to the WSL VM's external
address, where a loopback-only publish is not listening. The result is a port
that looks configured and answers nothing.

## Secrets

Nothing in this directory holds a credential. The compose file references
`${QDRANT__SERVICE__API_KEY}` and never a literal, and the two `.env.example`
files carry names and placeholders only. The live env files stay on the host at
mode 600 and are not tracked here.
