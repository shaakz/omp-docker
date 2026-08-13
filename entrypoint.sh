#!/usr/bin/env bash
# PID 1 for the omp container.
#
#   as root : align the `omp` user with PUID/PGID so files written into the
#             /workspace bind mount are owned correctly on the host, then drop
#             privileges and re-exec this same script.
#   as omp  : write models.yml from the environment, start a detached tmux
#             server running the agent, and block.
set -euo pipefail

STATE_DIR="${OMP_STATE_DIR:-/home/omp/.omp}"
AGENT_DIR="${STATE_DIR}/agent"
SESSION="${OMP_TMUX_SESSION:-omp}"

log() { printf '[omp-entrypoint] %s\n' "$*" >&2; }

if [ "$(id -u)" = "0" ]; then
    PUID="${PUID:-1000}"
    PGID="${PGID:-1000}"

    if [ "$(id -g omp)" != "$PGID" ]; then
        log "setting omp gid -> ${PGID}"
        groupmod -o -g "$PGID" omp
    fi
    if [ "$(id -u omp)" != "$PUID" ]; then
        log "setting omp uid -> ${PUID}"
        usermod -o -u "$PUID" omp
    fi

    # Only ever chown what we own. Never recurse into /workspace: it is a host
    # bind mount and chowning it would be both slow and destructive.
    mkdir -p "$HOME/tmp" "$HOME/.cache/bun" "$AGENT_DIR"
    chown -R "$PUID:$PGID" "$HOME"
    chown "$PUID:$PGID" /workspace 2>/dev/null || true

    log "dropping to uid=${PUID} gid=${PGID}"
    exec setpriv --reuid="$PUID" --regid="$PGID" --init-groups -- "$0" "$@"
fi

mkdir -p "$HOME/tmp" "$HOME/.cache/bun" "$AGENT_DIR"

# Bind-mounted repos usually have foreign ownership relative to the container
# user; without this every git call fails the dubious-ownership check.
git config --global --add safe.directory '*' 2>/dev/null || true
[ -n "${GIT_AUTHOR_NAME:-}" ] && git config --global user.name "${GIT_AUTHOR_NAME}"
[ -n "${GIT_AUTHOR_EMAIL:-}" ] && git config --global user.email "${GIT_AUTHOR_EMAIL}"

# Route HTTPS git auth through gh. This is what `gh auth setup-git` writes, but
# it writes it to ~/.gitconfig, which lives in the image layer and is therefore
# lost on every recreate — so apply it here instead. Harmless before you log in:
# git simply gets no credential back.
mkdir -p "${GH_CONFIG_DIR:-$HOME/.omp/gh}"
if command -v gh >/dev/null 2>&1; then
    for host in github.com gist.github.com; do
        git config --global --replace-all "credential.https://${host}.helper" "!gh auth git-credential"
    done
    if gh auth status >/dev/null 2>&1; then
        log "gh: authenticated ($(gh api user --jq .login 2>/dev/null || echo 'unknown user')) — git push over HTTPS will work"
    else
        log "gh: not logged in — run 'omp-ctl shell' then 'gh auth login --web' (token persists in the state volume)"
    fi
fi

# ---------------------------------------------------------------------------
# Forgejo over SSH. Skipped entirely when FORGEJO_HOST is unset, so machines
# that don't use it are unaffected.
# ---------------------------------------------------------------------------
if [ -n "${FORGEJO_HOST:-}" ]; then
    SSH_DIR="${STATE_DIR}/ssh"
    KEY="${SSH_DIR}/id_ed25519"
    KNOWN_HOSTS="${SSH_DIR}/known_hosts"
    FORGEJO_SSH_PORT="${FORGEJO_SSH_PORT:-222}"
    mkdir -p "$SSH_DIR"; chmod 700 "$SSH_DIR"

    # 1) .env is the source of truth when it carries a key: rewrite every boot.
    # 2) else keep whatever is already in the volume.  3) else generate one.
    if [ -n "${FORGEJO_SSH_KEY_B64:-}" ]; then
        if printf '%s' "$FORGEJO_SSH_KEY_B64" | base64 -d > "${KEY}.tmp" 2>/dev/null && [ -s "${KEY}.tmp" ]; then
            mv "${KEY}.tmp" "$KEY"; chmod 600 "$KEY"
            ssh-keygen -y -f "$KEY" -P "" > "${KEY}.pub" 2>/dev/null || true
            log "ssh: key loaded from FORGEJO_SSH_KEY_B64"
        else
            rm -f "${KEY}.tmp"
            log "ssh: ERROR — FORGEJO_SSH_KEY_B64 is not valid base64; ignoring it"
            log "ssh:         produce it with: base64 -w0 ~/.ssh/id_ed25519"
        fi
    fi
    if [ ! -f "$KEY" ]; then
        ssh-keygen -t ed25519 -N "" -C "omp@$(hostname)" -f "$KEY" >/dev/null 2>&1
        chmod 600 "$KEY"
        log "ssh: generated a new key — add this to ${FORGEJO_WEB_URL:-Forgejo} /user/settings/keys:"
        log "ssh:   $(cat "${KEY}.pub")"
    fi

    # An encrypted key would block on a passphrase prompt that a headless agent
    # can never answer, so say so rather than letting git hang later.
    if ! ssh-keygen -y -P "" -f "$KEY" >/dev/null 2>&1; then
        log "ssh: WARNING — the key is passphrase-protected; git over SSH will hang with no TTY to prompt on."
        log "ssh:          use a key with no passphrase (ssh-keygen -p removes one)."
    fi

    # Written fresh each boot: $HOME is image-local, so this file does not
    # survive a redeploy the way the state volume does.
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    cat > "$HOME/.ssh/config" <<SSHCFG
Host forgejo ${FORGEJO_HOST}
    HostName ${FORGEJO_HOST}
    Port ${FORGEJO_SSH_PORT}
    User git
    IdentityFile ${KEY}
    IdentitiesOnly yes
    UserKnownHostsFile ${KNOWN_HOSTS}
    StrictHostKeyChecking accept-new
SSHCFG
    chmod 600 "$HOME/.ssh/config"

    # accept-new still trusts whatever answers first; seeding known_hosts from a
    # scan means it never has to. Non-fatal — the n150 may simply be down.
    touch "$KNOWN_HOSTS"
    if ! grep -q "\[${FORGEJO_HOST}\]:${FORGEJO_SSH_PORT}" "$KNOWN_HOSTS" 2>/dev/null; then
        if ssh-keyscan -T 5 -p "$FORGEJO_SSH_PORT" "$FORGEJO_HOST" >> "$KNOWN_HOSTS" 2>/dev/null \
           && grep -q "\[${FORGEJO_HOST}\]:${FORGEJO_SSH_PORT}" "$KNOWN_HOSTS"; then
            log "ssh: seeded known_hosts for ${FORGEJO_HOST}:${FORGEJO_SSH_PORT}"
        else
            log "ssh: WARNING — could not reach ${FORGEJO_HOST}:${FORGEJO_SSH_PORT} to seed known_hosts"
        fi
    fi

    log "ssh: $(ssh-keygen -lf "$KEY" 2>/dev/null || echo 'key unreadable') → git@${FORGEJO_HOST}:${FORGEJO_SSH_PORT}"
fi

# ---------------------------------------------------------------------------
# models.yml, templated from the environment on every boot so that changing the
# model is a .env edit + `docker compose up -d`, never an image rebuild.
#
# Written only when OMP_MODEL_BASE_URL is set, so the file can also be managed
# by hand inside the state volume if you prefer.
# ---------------------------------------------------------------------------
if [ -n "${OMP_MODEL_BASE_URL:-}" ] && [ -n "${OMP_MODEL_ID:-}" ]; then
    provider="${OMP_MODEL_PROVIDER:-lan}"
    cat > "${AGENT_DIR}/models.yml" <<YAML
# Generated by omp-entrypoint on container start. Edits are overwritten.
# Source of truth is the .env next to docker-compose.yml.
providers:
  ${provider}:
    baseUrl: ${OMP_MODEL_BASE_URL}
    api: ${OMP_MODEL_API:-openai-completions}
    auth: none
    models:
      - id: ${OMP_MODEL_ID}
        name: ${OMP_MODEL_NAME:-${OMP_MODEL_ID}}
        reasoning: ${OMP_MODEL_REASONING:-false}
        input: [text]
        contextWindow: ${OMP_MODEL_CONTEXT:-131072}
        maxTokens: ${OMP_MODEL_MAX_TOKENS:-32768}
        cost:
          input: 0
          output: 0
          cacheRead: 0
          cacheWrite: 0
YAML
    log "wrote ${AGENT_DIR}/models.yml (${provider}/${OMP_MODEL_ID})"

    # OMP_MODEL_ID is sent verbatim as the request's `model` field, so it has to
    # match what the server advertises exactly — a near-miss (dropping an
    # org/ prefix, say) only shows up as a 404 mid-conversation, long after
    # startup looked healthy. Check it here instead, non-fatally: the endpoint
    # may legitimately not be up yet.
    served="$(curl -fsS --max-time 5 "${OMP_MODEL_BASE_URL%/}/models" 2>/dev/null \
        | tr ',' '\n' | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | sed 's/.*"\([^"]*\)"$/\1/' || true)"
    if [ -z "$served" ]; then
        log "WARNING: could not list models at ${OMP_MODEL_BASE_URL} — endpoint down or unreachable from this container?"
    elif ! grep -qxF "$OMP_MODEL_ID" <<<"$served"; then
        log "WARNING: OMP_MODEL_ID='${OMP_MODEL_ID}' is not served by ${OMP_MODEL_BASE_URL}."
        log "         requests will fail with 404. ids actually served:"
        while IFS= read -r id; do log "           ${id}"; done <<<"$served"
    else
        log "model '${OMP_MODEL_ID}' confirmed served by ${OMP_MODEL_BASE_URL}"
    fi
fi

# ---------------------------------------------------------------------------
# tmux. The agent runs inside a detached session so that a dropped `docker exec`
# or ssh connection detaches instead of killing a run in progress.
# ---------------------------------------------------------------------------
if tmux has-session -t "$SESSION" 2>/dev/null; then
    log "tmux session '${SESSION}' already running"
else
    # Default the selector to <provider>/<id> rather than making you repeat the
    # model id in a second variable — writing OMP_MODEL by hand invites a
    # mismatch with OMP_MODEL_ID, or a missing provider prefix.
    model="${OMP_MODEL:-}"
    if [ -z "$model" ] && [ -n "${OMP_MODEL_ID:-}" ]; then
        model="${OMP_MODEL_PROVIDER:-lan}/${OMP_MODEL_ID}"
    fi

    omp_cmd=(omp)
    [ -n "$model" ] && omp_cmd+=(--model "$model")
    # shellcheck disable=SC2206
    [ -n "${OMP_ARGS:-}" ] && omp_cmd+=(${OMP_ARGS})

    log "starting tmux session '${SESSION}': ${omp_cmd[*]}"
    tmux new-session -d -s "$SESSION" -n agent -c /workspace "${omp_cmd[@]}"
    # Leave a dead pane readable instead of collapsing the session (and with it
    # the container) the moment the agent exits.
    tmux set-option -t "$SESSION" remain-on-exit on
    tmux set-option -t "$SESSION" history-limit 50000
    tmux set-option -t "$SESSION" mouse on
    tmux new-window -t "$SESSION" -n shell -c /workspace
    tmux select-window -t "${SESSION}:agent"
fi

log "ready — attach with: docker compose exec ${OMP_NAME:-omp} tmux attach -t ${SESSION}"

# Block as PID 1. If the tmux server dies the client returns and the container
# exits, which is what `restart: unless-stopped` should react to.
exec tmux wait-for omp-shutdown
