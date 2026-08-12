# omp — standalone container

Runs the `omp` coding agent in a container, with one host directory bind-mounted
at `/workspace`.

`omp`'s approval mode defaults to `yolo` — it reads, writes, and executes with no
confirmation prompts. **The container is the isolation boundary.** The only host
path it can reach is `WORKSPACE_DIR`; no docker socket is mounted and no ports
are published.

## Quick start

```sh
cp .env.example .env      # set WORKSPACE_DIR, model, OMP_HOSTNAME
docker compose up -d
docker compose exec -u omp omp tmux attach -t omp
```

Detach with `ctrl-b d` — the agent keeps running. Reattach any time.

`docker compose` only finds the stack when run from this directory. To drive it
from anywhere, use `omp-ctl` (symlink it onto your PATH once per machine):

```sh
ln -s "$PWD/omp-ctl" ~/.local/bin/omp-ctl

omp-ctl attach          # attach to the TUI
omp-ctl collab          # print a join link
omp-ctl status          # link + participants
omp-ctl up | down | restart | logs | shell | ps
```

## How it fits together

| Piece | Why |
|---|---|
| `oven/bun:1.3.14-slim` + `bun install -g @oh-my-pi/pi-coding-agent` | The repo's own Dockerfile compiles `pi-natives` with Rust + bazelisk. Unnecessary: npm ships prebuilt N-API addons, so the build is ~20s and the build context is 2 files. |
| tmux as PID 1's payload | A dropped `exec`/ssh detaches instead of killing a run in progress. Window `agent` runs omp, window `shell` is a plain shell. |
| `omp-state` named volume | Sessions, `agent.db`, history, settings. Machine-local by design: it holds SQLite DBs and unix sockets, so never share it over NFS. |
| `models.yml` generated at boot | Templated from `.env` by `entrypoint.sh`, so changing model or endpoint is a `.env` edit + `docker compose up -d`, never a rebuild. |
| `PUID`/`PGID` remap | Files the agent writes into `/workspace` come out owned by you on the host, not root. |

Use `-u omp` with `docker compose exec`. The entrypoint starts as root to do the
uid remap and then drops privileges, so a bare `exec` lands you as root and
anything you create in `/workspace` would be root-owned.

## Model backend

Currently points at the LAN vLLM endpoint (`OMP_MODEL_BASE_URL`), which is
keyless — `auth: none`, no secret anywhere in the stack. `OMP_MODEL_CONTEXT`
comes from the endpoint's own `max_model_len`.

To point at something else, edit `.env`:

- another OpenAI-compatible endpoint → change `OMP_MODEL_BASE_URL` / `OMP_MODEL_ID`
- an Ollama / llama.cpp / LM Studio box → set `OLLAMA_BASE_URL`,
  `LLAMA_CPP_BASE_URL`, or `LM_STUDIO_BASE_URL`. omp auto-registers these three
  as keyless providers and discovers their models at runtime; no `models.yml`
  entry needed.
- a hosted provider → uncomment `ANTHROPIC_API_KEY` (or run `/login` in the TUI;
  credentials land in `agent.db` inside the persisted volume).

## Remote sessions (drive it from another machine)

`/collab` makes an **outbound** `wss://` connection to a content-blind relay —
no ports to publish, works through NAT.

Get a link without attaching:

```sh
docker compose exec -u omp omp omp-collab          # full control
docker compose exec -u omp omp omp-collab view     # read-only
docker compose exec -u omp omp omp-collab status   # link + participants
docker compose exec -u omp omp omp-collab stop
```

Or type `/collab` directly in the TUI, which also renders a QR code.

**The link is the credential** — the part after the dot is a 32-byte AES-256-GCM
room key plus a 16-byte write token, held only in the host process's memory. So:
anyone with a full link can prompt the agent (which has unrestricted tool access
to `/workspace`), and **every container restart invalidates the link** — re-run
`omp-collab` after one. Use `view` for read-only sharing.

On the other machine:

```sh
brew install can1357/tap/omp     # or: curl -fsSL https://omp.sh/install | sh
omp join "<link>"
```

…or just open `https://my.omp.sh/#<link>` in a browser, with nothing installed.

Two constraints: `omp join` requires a TTY on both ends, and host and guest must
speak the same collab protocol version — so keep `OMP_VERSION` the same on both.

Alternative path, no relay: `ssh <host> -t 'docker exec -u omp -it omp tmux attach -t omp'`.

## Replicating across machines

`docker-compose.yml` is identical on every host; only `.env` differs. Per machine,
set `WORKSPACE_DIR`, `PUID`/`PGID`, and a distinct `OMP_HOSTNAME` (it identifies
the machine in collab sessions).

To build without cloning the repo, swap the build context for the git form:

```yaml
build:
  context: https://github.com/<you>/oh-my-pi.git#<branch>:docker/omp-standalone
```

This works because the image pulls omp from npm — nothing from the repo tree is
needed to build it, and `.dockerignore` keeps the context to `Dockerfile` +
`entrypoint.sh`.

Note this directory lives inside an upstream checkout (`can1357/oh-my-pi`), so
keep it on your own branch or fork to survive `git pull`.

Since `/collab` is outbound-only, joining from your Mac is identical regardless
of which machine is running the stack — deploy to all of them and start the one
you want.

## Troubleshooting

| Symptom | Check |
|---|---|
| Container restarts / won't boot | `docker compose logs omp`; add `PI_DEBUG_STARTUP=1` for synchronous phase markers that survive a hard hang |
| `Failed to load pi_natives native addon` | `docker compose exec -u omp omp omp --smoke-test` should print `smoke-test: ok` |
| No models listed | From inside: `docker compose exec -u omp omp curl -s $OMP_MODEL_BASE_URL/models` |
| Root-owned files in `~/workspace` | You used `exec` without `-u omp` |
| TUI stuck on the setup wizard | `OMP_SKIP_SETUP=1` in `.env` |
