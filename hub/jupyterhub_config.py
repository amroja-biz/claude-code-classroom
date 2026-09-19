"""JupyterHub for the AI Agents lab.

The hub runs in a container and spawns one sibling container per student via the
mounted Docker socket. Students authenticate with a code handed out on paper;
there are no accounts, no passwords, and no persistence between cohorts.
"""

import json
import os

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

# Containers are disposable; the named volume is not removed with them, so a
# container that dies mid-workshop (OOM kill, crash) comes back with the
# student's work intact. Both die with the instance at teardown.
c.DockerSpawner.remove = True
c.DockerSpawner.volumes = {"lab-student-{username}": "/home/jovyan"}

# The cap that makes a shared box safe: one runaway agent gets OOM-killed in its
# own cgroup instead of driving the host into memory-reclaim livelock.
c.DockerSpawner.mem_limit = os.environ.get("LAB_MEM_LIMIT", "2G")

c.DockerSpawner.notebook_dir = "/home/jovyan"
c.DockerSpawner.debug = True

# The jupyter/docker-stacks base image ships a HEALTHCHECK that probes the server
# at its own root. Under JupyterHub the server is mounted at /user/<name>/, so
# that probe always fails and every healthy student container shows as
# "unhealthy" in `docker ps` — alarming and wrong. The hub does its own liveness
# checking, so turn the container-level one off.
c.DockerSpawner.extra_create_kwargs = {"healthcheck": {"Test": ["NONE"]}}

# The shared workshop key, passed through to every student container.
_api_key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
_student_env = {
    # Which curriculum seed-home copies into the student's home. All curricula
    # are baked into the image, so changing this between cohorts needs only a
    # hub restart -- no image or AMI rebuild.
    "LAB_CURRICULUM": os.environ.get("LAB_CURRICULUM", "").strip(),
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
