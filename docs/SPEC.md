# Claude Code Classroom — Specification

Status: **platform verified locally; AWS lifecycle implemented, under test on real AWS**
Date: 2026-09-18
Target AWS account: set in `workshop.conf` (see `workshop.conf.example`)

---

## 1. Purpose

A disposable, browser-based workshop environment for teaching people to work with
AI agents. Each cohort gets a URL and a login code. Students land in a browser
terminal with Claude Code already running and a lesson workspace already seeded.
When the class ends, the whole environment is destroyed.

This is a re-architecture of [`geneontology/go-jupyter`](https://github.com/geneontology/go-jupyter),
which solves the same UX problem but assumes a long-lived, pet EC2 instance with
persistent user homes. Everything here is ephemeral by design.

---

## 2. Design principles

1. **Nothing persists between cohorts.** Student work is disposable. There is no
   backup, no migration path, and no recovery story — because there is nothing
   worth recovering.
2. **Idle cost is effectively zero.** Between workshops the AWS account holds one
   AMI and one hosted zone. Target: under $15/year at rest.
3. **One box, base primitives only.** No ALB, no NAT Gateway, no ECS/EKS, no EFS,
   no Cognito, no Bedrock. EC2 + Docker + Caddy.
4. **Bake, don't boot-install.** Spin-up launches a pre-built AMI in 2–3 minutes.
   Installing Node, Claude Code and Python at boot takes 8–10 minutes and has four
   upstream services that can be down on workshop morning.
5. **The AMI is a cache, not the source of truth.** It must be reproducible from
   this repo at any time.
6. **Instructor-operable.** Three commands, no AWS console required.

### Non-goals

- Persisting or exporting student work
- Multi-region, HA, or surviving instance failure without a rebuild
- Per-student AWS credentials or per-student cost attribution
- Jupyter notebooks (JupyterLab is here for the terminal and file browser)
- More than ~60 concurrent students

---

## 3. Architecture

```
   student browser
         │  https://<hostname>            (stable, Route53)
         ▼
 ┌──────────── EC2 r7i.2xlarge — from baked AMI, terminated after class ────────┐
 │                                                                              │
 │   Caddy :443  ──── auto Let's Encrypt (HTTP-01) ────►  JupyterHub :8000      │
 │                                                          │                   │
 │                                        CodeAuthenticator │ (login codes)     │
 │                                           DockerSpawner  │                   │
 │                                                          ▼                   │
 │   ┌──────────────┐  ┌──────────────┐        ┌──────────────┐                │
 │   │ student01    │  │ student02    │  ...   │ studentNN    │                │
 │   │ JupyterLab   │  │              │        │              │                │
 │   │ Claude Code  │  │              │        │              │                │
 │   │ mem_limit 2g │  │              │        │              │                │
 │   └──────────────┘  └──────────────┘        └──────────────┘                │
 │        all from one image; named volumes on local disk; removed on stop      │
 └──────────────────────────────────────────────────────────────────────────────┘

 Persistent between workshops:   1 AMI  +  1 Route53 hosted zone   ≈ $1.10/mo
 Per workshop (6 h, 30 seats):                                     ≈ $3
```

### Why these choices

| Decision | Reason |
|---|---|
| One EC2, many containers | Within the r7i family the cost per GiB-hour is the same at every size, so splitting across instances saves nothing on compute and multiplies fixed overhead and ops. |
| `r7i` not `t3` | Burstable credits deplete when a whole cohort runs an exercise simultaneously. r7i is also cheaper per GiB than t3. |
| Containers, not Unix accounts | `mem_limit` caps each student via cgroups, and `memswap_limit` denies them swap. The reference repo needs an 8 GB swapfile because one runaway agent can livelock a shared box; here swap is a 4 GiB net for the *host's* processes only. |
| Keep JupyterHub | DockerSpawner + a custom Authenticator is ~30 lines of config. Replacing it means writing ~300 lines of session, lifecycle and proxy code you then own. |
| First-party Claude API, not Bedrock | Bedrock disables the WebSearch tool and adds inference-profile and model-pinning complexity for no benefit at this scale. |
| Own Route53 zone, not sslip.io | Verified 2026-09-18: sslip.io and nip.io resolve DNS correctly but both serve **expired TLS certificates** on their own sites. A free service that cannot keep its own cert valid does not belong on the critical path of a workshop. $0.50/mo removes the dependency. |

---

## 4. User experience

### 4.1 Student

**Before class** they receive one card:

```
   https://<hostname>
   your code:  blue-otter-42
```

**In class:**

1. Open the URL. Browser shows a single-field login page asking for the code.
2. Enter the code. JupyterHub spawns their container — **~10 seconds** measured,
   with the image already local.
3. Land in JupyterLab at `/lab`, with a terminal already open and Claude Code
   already running and authenticated. No `/login`, no API-key prompt, no trust
   dialog, no onboarding tour.
4. Work through lessons in their home directory. A file browser and editor sit
   alongside the terminal for reading what the agent produced.

**Expectations set explicitly** in the welcome banner:

> Everything in this environment is deleted when the class ends.
> Nothing here is saved. Copy out anything you want to keep.

**Requirements:** a browser. No install, no account, no AWS identity, no GitHub
account, no SSH key.

### 4.2 Instructor

```
./workshop build                 # ~10 min, day before  — rebuild the AMI
./workshop up --students 30      # ~3 min,  morning of  — prints URL + code table
./workshop down                  # ~1 min,  after       — terminate everything
./workshop status                # what exists right now, and what it costs
```

`up` prints a table ready to paste into a handout:

```
  URL:  https://<hostname>

  student01   blue-otter-42
  student02   green-marmot-17
  ...
```

**Cadence:** build the day before, not the morning of. Claude Code ships
frequently; you want students on a current version *and* a day of slack if an
upstream package broke.

---

## 5. Component specification

### 5.1 Base AMI

- Built from Canonical Ubuntu 24.04 LTS (Noble), amd64, `hvm-ssd-gp3`,
  owner `099720109477`. Resolved at build time, never hard-coded.
- Installs: **Docker Engine and Caddy only.** The hub itself runs as a container
  via `docker-compose.yml`, so the AMI needs no Python and no JupyterHub install,
  and the local dev harness and the on-box deployment are literally the same
  compose file. The student image is built into the AMI so spawn is instant.
  (Revised during build — the original plan installed the JupyterHub stack
  natively on the box, which would have made local testing unrepresentative.)
- Root volume: 100 GB gp3, encrypted, `DeleteOnTermination = true`.
- Produced by `./workshop build`, which launches a temp instance, provisions it,
  calls `create-image`, and terminates the temp instance.
- The provisioning script lives in this repo. The AMI is disposable.

### 5.2 Student container image

| Item | Version |
|---|---|
| Base | `quay.io/jupyter/minimal-notebook` (or Ubuntu 24.04 + JupyterLab) |
| Node.js | 22.x LTS |
| Claude Code | `@anthropic-ai/claude-code` — **latest at build time** (2.1.276 as of 2026-09-18) |
| JupyterLab | 4.6.x |
| Python | 3.14.x |

Baked into the image (not seeded at spawn time, unlike the reference repo):

- Lesson content and `.claude/skills/`
- `.claude.json` with onboarding suppressed, trust dialog pre-accepted, and the
  injected API key pre-approved by its last 20 characters. **This is load-bearing** —
  without it students hit "Detected a custom API key… use it?" and anyone who
  escapes that prompt is stranded at Claude Code's `/login` with a valid key in
  their environment.
- `.claude/settings.json`: `skipDangerousModePermissionPrompt`, tips and survey off.
- A `.bashrc` that prints the welcome banner and launches Claude Code, with a
  documented key to drop to a plain shell instead.

### 5.3 JupyterHub configuration

```python
# Authentication — codes handed out on paper, mapped to seat names.
class CodeAuthenticator(Authenticator):
    async def authenticate(self, handler, data):
        codes = json.load(open('/etc/jupyterhub/codes.json'))
        return codes.get(data['password'].strip())

# Spawning
c.JupyterHub.spawner_class = 'dockerspawner.DockerSpawner'
c.DockerSpawner.image      = 'lab-student:latest'
c.DockerSpawner.mem_limit  = '2G'
c.DockerSpawner.remove     = True
c.DockerSpawner.volumes    = {'student-{username}': '/home/jovyan'}
c.JupyterHub.hub_ip        = '0.0.0.0'
c.Spawner.default_url      = '/lab'
```

- `codes.json` is generated fresh by `./workshop up` and written to the instance.
  New cohort means new codes; previous codes stop working with no revocation step.
- A custom login template renders a single "Enter your code" field instead of the
  stock username + password form.
- Named volumes live on the instance's local disk. They survive a container
  restart *within* a workshop — so an OOM-killed container does not cost a student
  their morning — and die with the instance.

> **Version risk — RESOLVED 2026-09-18.** JupyterHub 6.0.1 and DockerSpawner
> 14.0.0 work together, and the `quay.io/jupyter/minimal-notebook` base image
> ships JupyterHub 6.0.1 itself, so hub and single-user server versions match
> exactly with no pinning gymnastics. Verified by a full login-and-spawn run.
>
> One API change does bite: **JupyterHub 5.0+ stopped implicitly allowing users
> that authenticate successfully.** Without `c.Authenticator.allow_all = True` a
> valid code authenticates and is then denied at the authorization step.

### 5.4 TLS and DNS

- Caddyfile is two lines: the hostname, and `reverse_proxy 127.0.0.1:8000`.
- Certificates via Let's Encrypt HTTP-01, fully automatic. No ACM, no wildcard
  cert, no S3 bundle, no cert-fetch IAM policy.
- A Route53 hosted zone in the sandbox account, delegated from a domain already
  owned in account the parent-zone account. NS delegation is set up **once** and never
  touched again.
- `./workshop up` updates the A record to the new public IP. No EIP is held
  between workshops.
- **Development must use the Let's Encrypt staging endpoint**
  (`acme_ca https://acme-staging-v02.api.letsencrypt.org/directory`). Iterating on
  `up` against a fixed hostname will otherwise hit LE's 5-duplicate-certificates-
  per-week limit and lock out the real cert mid-debug. A few real workshops a year
  is nowhere near any limit.

### 5.5 Curricula

Material changes every cohort, so it is treated as configuration rather than a
fixed asset. A curriculum is a directory under `curricula/`:

    curricula/<name>/
      welcome.txt    (optional)  rendered in the student's banner
      skills/        (optional)  -> ~/.claude/skills/
      *                          -> ~/   (lessons/, CLAUDE.md, data/, ...)

**Curricula are bind-mounted read-only into each student container at
/opt/lab/curricula; `$LAB_CURRICULUM` selects one at spawn time.** `workshop up`
delivers them to the instance; `workshop build` does not put them in the AMI.

> **Revised 2026-09-19.** They *were* baked into the image. The original
> rationale — switching cohorts is a flag, and "only authoring new material
> requires a rebuild, which is fine because the build happens the day before" —
> defended the wrong case. Authoring is iterative and is the thing that actually
> changes; the toolchain is not. Coupling a fast-changing artifact to a
> slow-changing one meant a one-line lesson fix cost a 20-minute AMI rebake and
> could not be done on the morning of a workshop at all. Nothing was gained in
> exchange: `workshop build` scp's the working tree (§6), so the AMI never pinned
> curricula to anything reviewable, and the instance is destroyed at `down`, so
> there is no long-lived box for mutable content to drift on.

The mount path is resolved by the **host** Docker daemon, not by the hub's own
filesystem — the hub is itself a container spawning siblings through the socket —
so it is passed in as an absolute host path via `LAB_CURRICULA_HOST_DIR`. Unset,
the spawn still succeeds and degrades to base files with a loud log, because a
content problem should not become an outage.

An unknown name falls back to the alphabetically-first curriculum and logs a
warning. The fallback is deliberate: silently teaching the wrong material is
worse than a loud degraded start, and an empty lab is worse than both.

Covered by `scripts/test-curriculum.sh` (seeding, cross-contamination, fallback,
marker) and `scripts/test-e2e.sh` (the full Makefile -> compose -> hub ->
spawner -> seed path).

### 5.6 Secrets

- One shared Anthropic API key (first-party Claude API), supplied out-of-band as a
  file path, never committed, never in a tracked file.
- Delivered to containers as an environment variable by the spawner.
- No key in the AMI, no key in git, no key in any state file.
- `codes.json` is generated at spin-up and never committed.

---

## 6. Lifecycle

### `./workshop build` (~10 min, run the day before)

Implemented in `scripts/workshop` + `scripts/provision.sh`.

1. Resolve the latest Ubuntu 24.04 AMI (owner 099720109477, `hvm-ssd-gp3`).
2. Launch a temporary r7i.xlarge — bigger than the workshop needs, because this
   step is CPU/network bound and only runs for minutes.
3. Upload the lab sources as a tarball over scp. Deliberately **not** a git
   clone: no deploy key, no private-repo problem, and the AMI reflects the
   working tree rather than whatever was last pushed.
4. Provision: Docker (official repo), Caddy, then build both images on the box.
5. Stop the instance, `create-image`, `wait image-available`, tag it.
6. Terminate the temp instance — via an `EXIT` trap, so a failure part-way
   through does not leak a running instance.
7. Prune old AMIs, keeping the last 2 — **`deregister-image` AND
   `delete-snapshot`**. Deregistering alone leaves the backing snapshot billing
   forever.

Caddy is installed and `systemctl enable`d but left stopped during the build:
DNS does not point at the temporary instance, so an ACME attempt there would
fail and back off. `up` restarts it once the A record is in place.

### `./workshop up --students N` (~3 min)

1. Generate N codes; build `codes.json`.
2. `run-instances` from the newest AMI; `wait instance-running`.
3. Read the public IP; update the Route53 A record.
4. Wait for SSH, then write `codes.json` and the API key to the instance. The
   key is read from the keychain and never echoed, logged, or written to the
   repo.
5. Start the hub with this cohort's `LAB_CURRICULUM` and `LAB_MEM_LIMIT`, then
   restart Caddy so it requests its certificate immediately rather than waiting
   out an ACME backoff.
6. Wait for HTTPS to answer, then print the URL and the code table.

`--staging` switches Caddy to the Let's Encrypt staging endpoint. Use it while
iterating: production allows only 5 duplicate certificates per week per
hostname, and a debugging loop will exhaust that.

### `./workshop down` (~1 min)

1. `terminate-instances`. The root volume is `DeleteOnTermination`, so it goes too.
2. Remove the Route53 A record.

There is no snapshot step, no volume to detach, and no wait-for-completion race —
because nothing is being preserved.

---

## 7. Cost model

Indicative figures from the AWS Pricing API on 2026-09-18, us-east-1.
Prices vary by region and over time; consult AWS pricing for your region.

**At rest (between workshops)**

| Item | Cost |
|---|---|
| AMI snapshot (~15 GB used, compressed) | ~$0.60/mo |
| Route53 hosted zone | $0.50/mo |
| **Total** | **~$1.10/mo (~$13/yr)** |

**Per workshop (6 hours, 30 students)**

| Item | Cost |
|---|---|
| r7i.2xlarge, 6 h | ~$3 |
| gp3 root + public IPv4, 6 h | pennies |
| **Total** | **~$3** |

Ten workshops a year ≈ **$46 all-in**.

### Traps that would break this model

- **Fast Snapshot Restore: never enable it.** $0.75 per DSU-hour per snapshot per
  AZ — roughly $540 if left on for a month, about 12× the entire annual budget.
- **Snapshot Archive tier: not applicable.** 75% cheaper storage, but a 90-day
  minimum and a 24–72 hour restore.
- **Prune AMIs every build**, and delete the backing snapshot, not just the image.

---

## 8. Capacity and sizing

Budget **2 GB per student** (Claude Code on Node is the driver) plus ~4 GB for the
host. Evidence: the reference repo notes that "several users each running Claude
Code (Node) + JupyterLab can exhaust the 8 GB of RAM" on a t3.large.

Instance type is **derived, never configured**: `workshop up --students N`
picks the smallest r7i that fits `N x --mem + 4 GiB` of host overhead. Within the
r7i family the cost per GiB-hour is the same at every size, so there is no cost
advantage to any size and the only question is what fits. Dollar figures below
are indicative (us-east-1, 2026-09-18); consult AWS pricing for your region.

| Instance | RAM | Max students @ 2 GiB | 6-hour cost |
|---|---|---|---|
| r7i.large | 16 GiB | 6 | under $1 |
| r7i.xlarge | 32 GiB | 14 | ~$2 |
| r7i.2xlarge | 64 GiB | 30 | ~$3 |
| r7i.4xlarge | 128 GiB | 62 | ~$6 |
| r7i.8xlarge | 256 GiB | 126 | ~$13 |
| r7i.12xlarge | 384 GiB | 190 | ~$19 |

Past 190 seats nothing fits and `workshop up` refuses rather than silently
truncating: run multiple independent stacks and encode the box in the login code
(`box2-amber-otter-07`). Do not introduce an orchestrator.

---

## 9. Security posture

Stated plainly, because it is a deliberate trade and not an oversight:

- Claude Code runs with `--dangerously-skip-permissions` so non-technical students
  are not blocked by per-action confirmation prompts.
- One shared API key serves the whole cohort; there is no per-student attribution.
- Login codes are shared secrets in a JSON file, delivered over HTTPS.
- Containers are isolated from each other by Docker, but a container escape
  compromises the host.

This is appropriate for a **time-boxed workshop on a disposable host with
known participants**, and for nothing else. The host exists for hours and is then
destroyed, which is the primary control.

---

## 10. Failure modes

| Failure | Impact | Mitigation |
|---|---|---|
| Instance dies mid-workshop | Whole class down | Rebuild from AMI, ~3 min. Accepted risk. |
| A student exhausts memory | That container OOM-killed only | `mem_limit = 2G`, and `memswap_limit = mem_limit` so it cannot swap its way into thrashing the box |
| The host itself runs short | Class stops | Sizing provisions for 50% of the per-seat cap plus 4 GiB host, compares against usable rather than nominal memory, and requires 10% slack on top; a 4 GiB host swapfile backs it, and `workshop status` reports live headroom |
| More students spawn than the box was sized for | Class stops | `active_server_limit = --students`; the extra login is refused, the running cohort is unaffected |
| Instance type does not match the AMI's architecture | `run-instances` fails with an unrelated-looking error | `up` compares both and refuses before any DNS or billing |
| Let's Encrypt rate limit | No valid cert | Staging endpoint during development |
| AMI is stale | Old Claude Code | `build` the day before each workshop |
| Route53 record not updated | URL points at a dead IP | `up` verifies HTTPS answers before printing the URL |
| Upstream package outage during `build` | Build fails | Previous AMI still launchable; build a day early |

---

## 11. Open questions

1. ~~**Lesson content.**~~ **RESOLVED** — curriculum is per-cohort configuration,
   not a fixed asset. See section 5.6. Two sample curricula ship for testing;
   real material is authored per class.
2. ~~**Hostname.**~~ **RESOLVED** — the deployment's `LAB_DOMAIN`, delegated from a parent zone
   the operator controls to a hosted zone this stack creates. Verified
   resolving end to end on 2026-09-18.
3. ~~**Default cohort size.**~~ **RESOLVED — the question was wrong.** There is
   no default. `--students` is a required parameter and the instance type is
   derived from it (`scripts/lib-size.sh`); `--mem` makes per-seat memory a
   parameter too. A default would only have been a number to remember to
   override. Enforced by `scripts/test-size.sh`, which fails if a hardcoded
   cohort size reappears.
4. **Anthropic API key** — confirm a Console key with credits, and the spend
   ceiling expected per workshop. Still open.

---

## 12. Relationship to `go-jupyter`

Carried over: the JupyterHub + DockerSpawner UX pattern, the `.claude.json`
pre-approval trick, the welcome-banner shell, per-user isolation.

**Removed:** the S3 wildcard-cert bundle and its IAM policy, the AWS CLI install
on the box, `wildcard_cert_s3_uri` / `cert_domain`, MultiAuthenticator, GitHub
OAuth, PAM `local_users`, `useradd` in `pre_spawn_hook`, `prevent_destroy`, the
8 GB swapfile as a load-bearing control, the systemd skills-sync timer, and
`go-jupyter-migrate`.

**Added:** a Dockerfile, ~10 lines of authenticator, ~6 lines of spawner config,
and three shell scripts.

The result is a smaller system with a lower idle cost and no data-loss failure
mode — because there is no data to lose.

---

## 13. Build notes — traps found while implementing

Discovered 2026-09-18 while building and verifying the platform locally. Each of
these cost real debugging time and none is obvious from the documentation.

**Never cross-build the student image.** Claude Code 2.x ships as a Bun
standalone binary. Bun's JS engine crashes under QEMU user-mode emulation with
`ASSERTION FAILED: MemoryExhaustion` -> `qemu: uncaught target signal 6`. On
Apple Silicon an amd64 student image spawns and serves JupyterLab correctly but
Claude Code will not start, which looks like a Claude Code bug and is not one.

Every build is therefore native: `make dev-build` on the host for local testing,
and `provision.sh` on the EC2 build instance for the AMI. A `prod-build` target
existed briefly to cross-build amd64 locally; it was removed 2026-09-19 because
nothing invoked it and its output could not be run on the machine that produced
it. The consequence to keep in mind is that on Apple Silicon local testing
exercises an arm64 image while the AMI is amd64 — a limit of local testing, not
a flag to set.

**Never set shell options in a `before-notebook.d` hook.** jupyter/docker-stacks
*sources* those scripts into `start.sh`. A `set -euo pipefail` leaks `set -u`
into the parent, which then dies on its own unset `JUPYTER_DOCKER_STACKS_QUIET`.
The symptom is a container that starts, never serves, and is silently removed by
`remove = True` before you can inspect it. The hook is now a one-line wrapper
that invokes the real script as a subprocess.

**Home seeding cannot happen at image build time.** DockerSpawner mounts a named
volume over `/home/jovyan`, shadowing anything baked at that path. Content lives
in `/opt/lab/` and is copied in at container start, guarded by a `.lab-seeded`
marker so a container restarting mid-workshop keeps the student's work.

**Disable the base image's HEALTHCHECK on spawned containers.** docker-stacks
probes the server at its own root, but under JupyterHub it is mounted at
`/user/<name>/`, so every healthy student container reports `(unhealthy)` in
`docker ps`. Set via `c.DockerSpawner.extra_create_kwargs`.

**The login template cannot `extends "login.html"`.** Jinja resolves the parent
through the same loader and finds itself. The override is a trimmed copy of the
version-matched stock template; re-check it when bumping the jupyterhub pin.

### Measured, not estimated

- Spawn time, native arch, image already local: **~10 seconds** to JupyterLab
  serving (spec assumed 2-5s; still well inside acceptable).
- `mem_limit` verified applied: 2147483648 bytes exactly.
- Versions as built: Claude Code 2.1.276, JupyterHub 6.0.1 (hub and single-user),
  JupyterLab 4.6.3, notebook 7.6.2.

---

## 14. Deferred: split boot and data volumes

**Considered 2026-09-18, not adopted. Recorded with its trigger.**

Today the instance has one volume: OS, Docker images and student workspaces all
on the root disk, sized `12 GiB + 1 GiB/student`.

The alternative is two: a small fixed root (~20 GiB, baked into the AMI, holding
OS and images) plus a per-cohort data volume for class data and student
workspaces, created at launch with `DeleteOnTermination=true` and mounted at
`/var/lib/docker/volumes`.

**What it would buy**

- The AMI floor problem disappears rather than being guarded around. An instance
  cannot have a root volume smaller than its AMI's snapshot, which currently
  couples image size to cohort size; splitting decouples them permanently.
- Class-specific data stops bloating an artifact every *future* workshop
  inherits. This is the real argument.
- Curriculum changes would no longer force an AMI rebuild.

**What it would cost**

The naive version -- create, attach, discover, mkfs and mount from `workshop up`
-- puts new failure modes in the one command that runs with an audience waiting.
But that version is not the one to build: `run-instances --block-device-mappings`
can create and destroy the volume in one extra line, and the format-and-mount
logic belongs in a systemd unit baked into the AMI, ordered `Before=docker.service`.
Then `up` is unchanged and breakage surfaces at build time instead. Roughly 30
lines.

The genuinely fiddly part is that Docker keeps images in
`/var/lib/docker/overlay2` (wanted on root) and named volumes in
`/var/lib/docker/volumes` (wanted on data), and `data-root` moves both. The split
therefore depends on mounting over that one path before dockerd starts -- which
fails quietly if boot ordering is wrong.

**What it would not buy:** persistence. Nothing survives teardown by design, so
the usual detach-and-reattach argument does not apply. Cost is identical.

**Trigger to revisit:** the first curriculum shipping real data -- a corpus,
datasets, model weights, anything past a few hundred MB. Before that, prefer the
cheaper 80%: fetch large class data from S3 at `up` time rather than baking it,
which avoids the volume, mount and Docker-ordering work entirely.
