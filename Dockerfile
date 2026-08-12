# oh-my-pi (`omp`) — standalone container.
#
# omp is installed from npm rather than built from this repo's source: the
# root Dockerfile's `natives-builder` stage compiles pi-natives with Rust +
# bazelisk, which is unnecessary because @oh-my-pi/pi-natives ships prebuilt
# N-API addons per platform. That keeps the build ~2 minutes and the build
# context to this directory only, which is what makes a git-URL build context
# practical on the other machines.
FROM oven/bun:1.3.14-slim

ARG OMP_VERSION=17.2.15

# git      — utils/git.ts guards on $which("git") then spawns it
# tmux     — long-lived TUI that survives a dropped exec/ssh connection
# util-linux — setpriv, to drop root without pulling in gosu
# python3  — the python REPL tool (set PI_PY=0 to skip it)
# No ripgrep/jq/sd/sg: grep is the Rust addon (tools/grep.ts imports from
# @oh-my-pi/pi-natives) and the native shell bundles jaq.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl git less openssh-client procps \
        python3 python3-venv tini tmux util-linux \
    && rm -rf /var/lib/apt/lists/*

# Install omp image-wide and root-owned, so wiping the state volume can never
# break the installation.
# /usr/sbin and /sbin must stay on PATH: the entrypoint runs usermod/groupmod
# as root before dropping privileges.
ENV BUN_INSTALL=/opt/bun \
    PATH=/opt/bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN bun install -g "@oh-my-pi/pi-coding-agent@${OMP_VERSION}" \
    && omp --version

# HOME must NOT be /workspace: cli/startup-cwd.ts silently relocates the
# project dir to a temp dir when cwd == $HOME, which would leave the agent
# working somewhere invisible from the host.
ENV HOME=/home/omp \
    TMPDIR=/home/omp/tmp \
    BUN_INSTALL_CACHE_DIR=/home/omp/.cache/bun \
    PI_BASH_NO_LOGIN=1 \
    OMP_STATE_DIR=/home/omp/.omp

# procmgr.ts runs `bash -l -c` by default; there is no login profile here,
# hence PI_BASH_NO_LOGIN above. bun chmod/chowns its cache root, so
# BUN_INSTALL_CACHE_DIR has to be private and writable.

# The base image already ships a `bun` user at uid/gid 1000. Rename it instead
# of adding a second user at the same id — avoids a uid clash and avoids
# needing the `passwd` package (usermod/groupmod are already present).
RUN groupmod -n omp bun \
    && usermod -l omp -d /home/omp -m -s /bin/bash bun \
    && mkdir -p /home/omp/tmp /home/omp/.cache/bun /home/omp/.omp/agent /workspace \
    && chown -R omp:omp /home/omp /workspace

COPY entrypoint.sh /usr/local/bin/omp-entrypoint
COPY omp-collab /usr/local/bin/omp-collab
RUN chmod +x /usr/local/bin/omp-entrypoint /usr/local/bin/omp-collab

WORKDIR /workspace

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/omp-entrypoint"]
