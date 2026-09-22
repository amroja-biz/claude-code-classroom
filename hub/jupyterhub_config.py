"""JupyterHub for Claude Code Classroom.

The hub runs in a container and spawns one sibling container per student via the
mounted Docker socket. Students authenticate with a code handed out on paper;
there are no accounts, no passwords, and no persistence between cohorts.
"""

import json
import os
import sys

from jupyterhub.auth import Authenticator

c = get_config()  # noqa: F821  (injected by jupyterhub)

CODES_FILE = os.environ.get("LAB_CODES_FILE", "/etc/jupyterhub/codes.json")


# ---------------------------------------------------------------------------
# Authentication — a code maps to a seat name.
# ---------------------------------------------------------------------------
class CodeAuthenticator(Authenticator):
    """Single-field login. The code IS the credential.

    Codes are regenerated for every cohort by `workshop up`, so last workshop's
    codes stop working with no revocation step.
    """

    async def authenticate(self, handler, data):
        code = (data.get("password") or "").strip()
        if not code:
            return None
        try:
            with open(CODES_FILE) as f:
                codes = json.load(f)
        except (OSError, ValueError):
            self.log.exception("could not read codes file %s", CODES_FILE)
            return None
        return codes.get(code)


c.JupyterHub.authenticator_class = CodeAuthenticator

# JupyterHub 5.0 stopped implicitly allowing every user that authenticates:
# without an explicit allow rule, authenticate() succeeds and the user is then
# denied at the authorization step. Our authenticate() already gates on a valid
# code, so that check is the allow rule.
c.Authenticator.allow_all = True

c.JupyterHub.template_paths = ["/srv/jupyterhub/templates"]


# ---------------------------------------------------------------------------
# Spawning — one container per student.
# ---------------------------------------------------------------------------
c.JupyterHub.spawner_class = "dockerspawner.DockerSpawner"

c.DockerSpawner.image = os.environ.get("LAB_STUDENT_IMAGE", "lab-student:latest")
c.DockerSpawner.network_name = os.environ.get("DOCKER_NETWORK_NAME", "lab-net")
c.DockerSpawner.use_internal_ip = True

# Containers are disposable; the student's home is not removed with them, so a
# container that dies mid-workshop (OOM kill, crash) comes back with the
# student's work intact. Both die with the instance at teardown.
c.DockerSpawner.remove = True

# Home is a per-seat filesystem, not a shared directory and not a named volume.
#
# Disk was the last resource a single student could exhaust for the whole class:
# memory, CPU and PIDs are capped per container, but every named volume drew on
# one shared filesystem with nothing stopping one `pip install` of something
# enormous -- or one runaway log -- from filling it for all 30 seats at once.
# Docker cannot cap a named volume: --storage-opt applies to the container's
# writable layer, not to volumes, and only on backends most hosts do not run.
#
# scripts/seat-storage.sh gives each seat its own loop-mounted ext4 image, so
# the limit is the filesystem's own size and overrun is an ordinary ENOSPC that
# reaches exactly one student. See that script for why not project quotas.
#
# LAB_SEAT_HOME_DIR is a HOST path: this hub runs in a container and spawns
# siblings through the Docker socket, so the daemon resolves it outside this
# container's filesystem view.
_seat_home_dir = os.environ.get("LAB_SEAT_HOME_DIR", "").strip()
if _seat_home_dir:
    c.DockerSpawner.volumes = {
        _seat_home_dir.rstrip("/") + "/{username}": "/home/jovyan",
    }
else:
    # Local development without seat storage prepared. Named volumes still give
    # persistence across respawns; they give no disk containment, which is why
    # this is the fallback and not the default.
    print(
        "[lab] WARNING: LAB_SEAT_HOME_DIR is not set; falling back to named "
        "volumes. Student homes share one filesystem with NO per-seat disk "
        "limit -- one student can fill the disk for the whole class.",
        file=sys.stderr,
    )
    c.DockerSpawner.volumes = {"lab-student-{username}": "/home/jovyan"}

# Course material is mounted, not baked into the image, so fixing a lesson is a
# respawn rather than an image rebuild plus an AMI rebake.
#
# This hub runs in a container and spawns siblings through the Docker socket, so
# the daemon resolves this path on the HOST -- it is not this container's view of
# the filesystem, and must be passed in as an absolute host path.
# Read-only: one student editing shared material must not change it for the cohort.
#
# One curriculum per class, always mounted at the same place. Which one is
# decided on the trainer's machine by `workshop up --curriculum <dir>`; the
# container never chooses.
_curriculum_host_dir = os.environ.get("LAB_CURRICULUM_HOST_DIR", "").strip()
if _curriculum_host_dir:
    c.DockerSpawner.volumes[_curriculum_host_dir] = {
        "bind": "/opt/lab/curriculum",
        "mode": "ro",
    }
else:
    # Not fatal: seed-home seeds base files and logs loudly. Failing the spawn
    # instead would turn a content problem into an outage.
    print(
        "[lab] WARNING: LAB_CURRICULUM_HOST_DIR is not set; "
        "students will get base files only",
        file=sys.stderr,
    )

# --- Containment -------------------------------------------------------------
#
# One student must not be able to end the class for everyone else. Every
# exhaustible resource a container can reach needs a ceiling, because the only
# thing standing between a student's prompt and the host is these limits:
# Claude Code runs with --dangerously-skip-permissions, so no confirmation
# stops a command that turns out to be ruinous.
#
# Each limit below is a CEILING, not a reservation. Seats are deliberately
# oversubscribed against the box -- 30 seats cannot all peg every ceiling at
# once, and sizing does not assume they can. Treating a ceiling as a
# reservation is what produced the zero-headroom sizing bug; see
# scripts/lib-size.sh.

# Memory: one runaway agent gets OOM-killed in its own cgroup instead of
# driving the host into memory-reclaim livelock.
_mem_limit = os.environ.get("LAB_MEM_LIMIT", "2G")
c.DockerSpawner.mem_limit = _mem_limit

# CPU: without this, one agent told to "build it faster" takes every core and
# every other student's terminal stops responding. That failure is worse than a
# crash, because nothing on screen says what is wrong -- the room just goes
# slow, mid-lesson, and the instructor has no way to tell who caused it.
#
# dockerspawner turns this into cpu_quota = cpu_limit * cpu_period (100ms), a
# hard CFS quota rather than a relative weight. Relative weights (cpu_shares)
# would be useless here: when every student carries the same weight, equal
# weights are the same as no limit at all.
#
# Default: a quarter of the box, so a student can still run a real build at
# sensible speed while three quarters stays available to the other 29. Measured
# on the reference exercise -- a 292-package npm install saturates about one
# core, four parallel tsc runs saturate four.
#
# os.cpu_count() reports the HOST's CPUs from inside this container, which is
# what we want: the ceiling should scale with the box `workshop up` chose.
_cpu_limit = os.environ.get("LAB_CPU_LIMIT", "").strip()
c.DockerSpawner.cpu_limit = (
    float(_cpu_limit) if _cpu_limit else max(1.0, (os.cpu_count() or 4) / 4)
)

# A hard limit on how many students can be running at once, so the box cannot be
# oversubscribed past what `workshop up --students N` sized it for. Normally
# codes == seats == this number, but a hand-edited or reused codes.json would
# otherwise let more containers start than there is memory for -- and the
# failure would land mid-class.
_max_servers = os.environ.get("LAB_MAX_SERVERS", "").strip()
if _max_servers.isdigit() and int(_max_servers) > 0:
    c.JupyterHub.active_server_limit = int(_max_servers)

c.DockerSpawner.notebook_dir = "/home/jovyan"
c.DockerSpawner.debug = True

# The jupyter/docker-stacks base image ships a HEALTHCHECK that probes the server
# at its own root. Under JupyterHub the server is mounted at /user/<name>/, so
# that probe always fails and every healthy student container shows as
# "unhealthy" in `docker ps` — alarming and wrong. The hub does its own liveness
# checking, so turn the container-level one off.
c.DockerSpawner.extra_create_kwargs = {"healthcheck": {"Test": ["NONE"]}}

# memswap_limit == mem_limit means "no swap for this container".
#
# The box has a small swapfile so the host's own processes -- dockerd, this hub,
# Caddy -- have somewhere to go under pressure instead of meeting the OOM
# killer. Student containers must not be able to reach it: swap is what turns a
# runaway agent into a box-wide thrash, which is exactly the failure the mem_limit
# exists to prevent. Without this, Docker lets a container use up to 2x its
# memory limit in swap.
#
# pids_limit caps the container's process count. This is the fastest way one
# student can take the whole box down and it is not covered by any of the
# limits above: a fork bomb exhausts the host's shared process table in
# seconds, and what dies is dockerd and this hub, not the student who caused
# it. Memory and CPU ceilings do not help -- thousands of tiny processes cost
# little of either.
#
# Default 512 against a measured peak of 78 (four parallel tsc runs; a
# 292-package npm install peaks at 21). That is ~6x headroom for a heavier
# exercise while still stopping a fork bomb in milliseconds.
# An unset variable and a variable set to "" must behave identically: compose
# passes "${LAB_PIDS_LIMIT:-}" through as an empty string, and int("") would
# raise here -- taking the hub down at the moment a student tries to log in.
_pids_limit = os.environ.get("LAB_PIDS_LIMIT", "").strip() or "512"
c.DockerSpawner.extra_host_config = {
    "memswap_limit": _mem_limit,
    "pids_limit": int(_pids_limit),
}

# The shared workshop key, passed through to every student container.
_api_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
_student_env = {
    "DISABLE_AUTOUPDATER": "1",
    "DISABLE_TELEMETRY": "1",
    "DISABLE_NON_ESSENTIAL_MODEL_CALLS": "1",
    # Which variables matter, and why, comes from geneontology/go-jupyter.
    # Reduces scrollbar reset artifacts in the xterm.js terminal JupyterLab uses.
    "CLAUDE_CODE_NO_FLICKER": "1",
}
if _api_key:
    _student_env["ANTHROPIC_API_KEY"] = _api_key
c.DockerSpawner.environment = _student_env

# Pulling an image or cold-starting Node can exceed the 30s default.
c.Spawner.start_timeout = 180
c.Spawner.http_timeout = 120
c.Spawner.default_url = "/lab"


# ---------------------------------------------------------------------------
# Networking. The hub binds on all interfaces inside its container; spawned
# containers dial it back by container name on the shared Docker network.
# ---------------------------------------------------------------------------
c.JupyterHub.hub_ip = "0.0.0.0"
c.JupyterHub.hub_connect_ip = os.environ.get("HUB_CONNECT_IP", "lab-hub")
c.JupyterHub.bind_url = "http://:8000"

c.JupyterHub.cleanup_servers = True
c.JupyterHub.shutdown_on_logout = True
