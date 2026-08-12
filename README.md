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

## omp-ctl

`docker compose` only finds the stack from the stack directory. `omp-ctl` drives
the container from anywhere — install it standalone, no clone needed (handy when
the stack itself is deployed by Dockhand or another manager):

```sh
mkdir -p ~/.local/bin
curl -fsSL -o ~/.local/bin/omp-ctl \
  https://raw.githubusercontent.com/shaakz/omp-docker/main/omp-ctl
chmod +x ~/.local/bin/omp-ctl
```

On Debian/Ubuntu `~/.local/bin` is added to PATH by `~/.profile` only if it
existed at login, so after creating it either log out and back in or run
`export PATH="$HOME/.local/bin:$PATH"` for the current shell.

```sh
omp-ctl attach          # attach to the TUI (ctrl-b d to detach)
omp-ctl collab          # print a join link (add "view" for read-only)
omp-ctl status          # link + participants
omp-ctl shell | logs | restart | stop | start | ps
omp-ctl up | down       # these two need the compose file
```

Everything except `up`/`down` talks to the running container by name, so no
checkout and no particular working directory is required. `up`/`down` look for
`docker-compose.yml` in `$OMP_STACK_DIR`, next to the script, the current
directory, `~/omp-docker`, then `/data/stacks/omp-standalone` and
`/opt/stacks/omp-standalone`. If you renamed the container, set `OMP_NAME`.

There is no host-side install for `omp-collab` — it lives inside the image and
`omp-ctl` invokes it there.

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

## Git / GitHub access

omp has no git auth of its own — it shells out to `git` and `gh`, and when auth
fails it just says "run `gh auth login`". The image ships `gh` and wires the
HTTPS credential helper to it on every boot, so you only need to log in once per
machine:

```sh
omp-ctl shell
gh auth login --web     # prints a one-time code; approve it in a browser
exit
```

The token is written to `$GH_CONFIG_DIR` = `/home/omp/.omp/gh`, which lives in
the state volume, so it survives rebuilds and redeploys. (`gh auth setup-git`
is not needed — the entrypoint applies the same credential-helper config each
boot, because `~/.gitconfig` is in the image layer and would otherwise be lost.)

After that, the agent can `git clone`/`pull`/`push` over HTTPS and use `gh pr
create` on its own. `omp-ctl logs` reports auth state on every start:

```
[omp-entrypoint] gh: authenticated (shaakz) — git push over HTTPS will work
[omp-entrypoint] gh: not logged in — run 'omp-ctl shell' then 'gh auth login --web'
```

**Scope warning.** The agent runs in yolo mode with `bash`, so it can read this
token (`gh auth token`) and act as you on **every repo the grant covers** — a
normal `gh` OAuth login is account-wide. If you want the agent limited to
specific repositories, skip the browser login and set `GH_TOKEN` in `.env` to a
fine-grained PAT scoped to just those repos with an expiry; the same credential
helper picks it up. Deploy keys are narrower still, but rule out the GitHub API.

## Replicating across machines

A new machine needs **two files and nothing else** — no clone, no registry:

```sh
mkdir omp && cd omp
curl -fsSL -O https://raw.githubusercontent.com/shaakz/omp-docker/main/docker-compose.yml
curl -fsSL https://raw.githubusercontent.com/shaakz/omp-docker/main/.env.example -o .env
$EDITOR .env          # WORKSPACE_DIR, PUID/PGID, OMP_HOSTNAME, model endpoint
docker compose up -d
```

`build.context` defaults to this public repo, so docker clones it at build time.
On a machine where you edit these files locally, set `OMP_BUILD_CONTEXT=.` in
`.env` to build from the working copy instead.

For **Dockhand**: paste `docker-compose.yml` as the stack and supply the same
variables as the stack's environment. No build context to ship, no registry
credentials to configure.

Per machine, change only: `WORKSPACE_DIR`, `PUID`/`PGID`, `TZ`, `OMP_HOSTNAME`
(identifies the host in collab sessions), and the model endpoint.

Notes:

- The project name is pinned via `name:` in the compose file, so the `omp-state`
  volume does not depend on the directory you cloned into — the checkout can be
  moved or renamed without orphaning sessions.
- Builds work on x86_64 and arm64: omp and its native addon both ship prebuilt
  per-platform npm packages, so the image is architecture-agnostic.
- Since `/collab` is outbound-only, joining from another machine is identical
  regardless of which host runs the stack. Deploy everywhere, start the one you
  want.

## Troubleshooting

| Symptom | Check |
|---|---|
| Container restarts / won't boot | `docker compose logs omp`; add `PI_DEBUG_STARTUP=1` for synchronous phase markers that survive a hard hang |
| `Failed to load pi_natives native addon` | `docker compose exec -u omp omp omp --smoke-test` should print `smoke-test: ok` |
| No models listed | From inside: `docker compose exec -u omp omp curl -s $OMP_MODEL_BASE_URL/models` |
| Root-owned files in `~/workspace` | You used `exec` without `-u omp` |
| TUI stuck on the setup wizard | `OMP_SKIP_SETUP=1` in `.env` |
