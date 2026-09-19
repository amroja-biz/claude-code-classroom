# Student workspace: JupyterLab + Claude Code, one container per student.
#
# BUILD CONTEXT IS THE REPO ROOT, not this directory:
#
#   docker build -f student-image/Dockerfile -t lab-student:latest .
#
# Always built natively: locally by `make dev-build`, and on the EC2 build
# instance by `workshop build`. Never cross-built. Claude Code ships as a Bun
# binary that crashes under QEMU emulation, so an emulated image is useless. See
# README.
FROM quay.io/jupyter/minimal-notebook:latest

# Pin at build time for reproducibility; defaults to whatever is current.
ARG CLAUDE_CODE_VERSION=latest

USER root

# Node.js 22.x (Claude Code runs on Node).
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
 && apt-get install -y --no-install-recommends nodejs \
 && apt-get clean \
 && find /var/lib/apt/lists -mindepth 1 -delete

RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
 && npm cache clean --force

# Students can't write to /usr/lib/node_modules, and a mid-workshop update is
# never what you want.
RUN mkdir -p /etc/claude-code \
 && printf '{"autoUpdatesDisabled": true}\n' > /etc/claude-code/managed-settings.json

# Content lives OUTSIDE /home/jovyan on purpose: DockerSpawner mounts a named
# volume there at spawn time, which would shadow anything baked into that path.
# seed-home copies it in at container start instead.
#
# Curricula are deliberately NOT baked in. The spawner bind-mounts them
# read-only at /opt/lab/curricula, so editing a lesson costs a respawn rather
# than an image rebuild and a 20-minute AMI rebake. Course material changes far
# more often than the toolchain does, and tying the two to one artifact meant a
# typo in lesson 3 could not be fixed on the morning of a workshop.
# $LAB_CURRICULUM still selects among whatever is mounted, at spawn time.
COPY student-image/skel/ /opt/lab/skel/

# docker-stacks SOURCES every .sh in before-notebook.d into start.sh, so the hook
# is a one-line wrapper that runs the real script as a subprocess. Keeping
# `set -euo pipefail` out of the sourced file matters: `set -u` leaking into
# start.sh kills it on its own unset JUPYTER_DOCKER_STACKS_QUIET, and the
# container then never starts the single-user server.
COPY student-image/seed-home.sh            /usr/local/bin/lab-seed-home
COPY student-image/before-notebook-hook.sh /usr/local/bin/before-notebook.d/10-seed-home.sh
RUN chmod +x /usr/local/bin/lab-seed-home

USER ${NB_UID}
