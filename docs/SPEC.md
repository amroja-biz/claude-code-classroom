# Claude Code Classroom — Specification

Status: **verified locally, including containment; never yet executed end to end on real AWS**
Date: 2026-09-20
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

> These are build rules — *how* this is put together. What the platform is
> **for**, and which goal wins when two conflict, is in
> [`PRINCIPLES.md`](../PRINCIPLES.md), which **outranks this document**. When a
> rule below produces an outcome that violates a principle there, the rule is
> wrong. That is not hypothetical: "pick the smallest box the cohort fits in"
> was a rule here, and it was optimizing the wrong variable.


1. **Nothing persists between cohorts.** Student work is disposable. There is no
   backup, no migration path, and no recovery story — because there is nothing
   worth recovering.
2. **Idle cost is effectively zero.** Between workshops the AWS account holds one
   AMI and one hosted zone. Target: under $15/year at rest.
3. **One box, base primitives only.** No ALB, no NAT Gateway, no ECS/EKS, no EFS,
   no Cognito, no Bedrock. EC2 + Docker + Caddy.
4. **Bake, don't boot-install.** Spin-up launches a pre-built AMI and has a class
   ready in about 5 minutes.
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
 │   │ mem  2g      │  │              │        │              │                │
 │   │ cpu  box/4   │  │              │        │              │                │
 │   │ pids 512     │  │              │        │              │                │
 │   │ disk own fs  │  │              │        │              │                │
 │   └──────────────┘  └──────────────┘        └──────────────┘                │
 │      all from one image; each home its own filesystem; removed on stop       │
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
./workshop up --students 30      # ~5 min,  morning of  — prints URL + code table
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
- `.claude/settings.json`: `skipDangerousModePermissionPrompt`, tips and survey off,
  and a status line crediting the platform.
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
c.DockerSpawner.remove     = True
c.JupyterHub.hub_ip        = '0.0.0.0'
c.Spawner.default_url      = '/lab'

# Containment — see §5.3.1. Every exhaustible resource has a ceiling.
c.DockerSpawner.mem_limit  = '2G'                       # memory
c.DockerSpawner.cpu_limit  = max(1.0, os.cpu_count()/4) # hard CFS quota
c.DockerSpawner.extra_host_config = {
    'memswap_limit': '2G',                              # no swap escape
    'pids_limit': 512,                                  # no fork bomb
}
# Home is a per-seat filesystem, so disk is capped too.
c.DockerSpawner.volumes    = {'/srv/lab/home/{username}': '/home/jovyan'}
```

- `codes.json` is generated fresh by `./workshop up` and written to the instance.
  New cohort means new codes; previous codes stop working with no revocation step.
- A custom login template renders a single "Enter your code" field instead of the
  stock username + password form.
- Student homes live on the instance's local disk and survive a container
  restart *within* a workshop — so an OOM-killed container does not cost a
  student their morning — and die with the instance.

### 5.3.1 Containment

Claude Code runs with `--dangerously-skip-permissions`. Nothing between a
student's prompt and the host asks "are you sure", so these ceilings are the
only thing that does. All four are asserted against the kernel's own numbers by
`scripts/test-containment.sh`.

| Axis | Ceiling | Why it is not optional |
|---|---|---|
| Memory | `mem_limit` 2 GiB, `memswap_limit` equal | Without the swap denial, Docker lets a container use 2x its limit in swap and thrash the box |
| CPU | `cpu_limit`, default ¼ of the box | One agent told to "build it faster" takes every core; the room goes slow with nothing on screen saying why |
| PIDs | `pids_limit` 512 (measured peak 78) | A fork bomb exhausts the host's shared process table in seconds, killing dockerd and the hub rather than the student |
| Disk | per-seat loop-mounted ext4 image | Docker cannot cap a named volume — `--storage-opt` applies to the writable layer, not volumes |

Each is a **ceiling, not a reservation**. Seats are deliberately oversubscribed
against them; sizing does not assume every seat pegs every ceiling at once, and
`workshop size` prints the oversubscription factor rather than leaving it
unstated.

**Why per-seat filesystems and not project quotas.** Quotas are thinner and more
standard. They were rejected because they cannot be tested anywhere but a real
instance: Docker Desktop's kernel is built without `CONFIG_QUOTA`/`CONFIG_QFMT_V2`,
so `mount -o prjquota` fails outright. A loop-mounted filesystem needs no quota
subsystem — its size *is* the limit, enforced by ordinary `ENOSPC` — and behaves
identically on a laptop and on the box. The cost is that seat space is
preallocated rather than shared; `lab_disk_gib` already budgets exactly that.

The image must be created with `mkfs.ext4 -E nodiscard`. mke2fs discards by
default, which on a file punches holes straight through the blocks `fallocate`
reserved (measured: 268435456 bytes before, 339968 after). The image goes
sparse, every seat overcommits the same free space, and the containment
silently stops being real.

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
- **The certificate outlives the instance.** Caddy's data directory --
  certificate, key, ACME account -- is synced to a private, versioned S3
  bucket in the durable stack (`CertBucket`). On the box, a systemd drop-in
  restores it before Caddy starts (`ExecStartPre=+/opt/lab/cert-sync.sh
  restore`), a timer saves it every five minutes, and `up` and `down` each
  save once more. The instance role can list, get and put in that bucket,
  and nothing else; the bucket is retained on stack delete because
  CloudFormation cannot remove a non-empty one.
- Let's Encrypt renews on its own schedule (Caddy asks at roughly two thirds
  of the 90-day lifetime, or when ARI says so). A renewal during a class is
  saved by the timer. A certificate that expired between classes is simply
  requested again, once.
- `--staging` still exists for platform development, and its certificates
  are kept in the same bucket under a separate issuer directory, so the two
  never collide.

> **Revised 2026-09-22.** The rule used to be "development must use staging",
> with the real certificate requested fresh at every `up`. Let's Encrypt's
> limit of 5 new certificates per exact hostname per week is global, hard, and
> has no override -- verified against their rate-limits page that day -- and a
> teacher rehearsing, fixing a lesson and rehearsing again hit it with a class
> the next morning. A rule that says "remember to pass a flag" is not
> automation. Keeping the certificate makes every issuance after the first a
> renewal, which the limit does not count.

### 5.5 Curricula

Material changes every cohort, so it is treated as configuration rather than a
fixed asset. A curriculum is a directory, anywhere on the trainer's machine:

    <curriculum>/
      lessons/       (required)  -> ~/lessons
      welcome.txt    (optional)  rendered in the student's banner
      skills/        (optional)  -> ~/.claude/skills/
      *                          -> ~/   (CLAUDE.md, data/, ...)

`workshop up --curriculum <path>` validates that layout locally and refuses
with the expected shape if it does not match, then ships that one directory's
contents to `/opt/lab/curriculum` on the instance. A bare name is looked up in
this repo's `curricula/`, which holds two examples.

**A class has one curriculum, and it is always at /opt/lab/curriculum -- on
the instance and, bind-mounted read-only, inside every student container.**
The choice is made once, on the trainer's machine; nothing on the instance or
in the container selects among alternatives. `workshop build` does not put it
in the AMI.

> **Revised 2026-09-22.** `--curriculum` used to take a bare name looked up in
> `$LAB_CURRICULA_DIR`, a parent directory whose entire tree was shipped to
> `/opt/lab/curricula`, and `$LAB_CURRICULUM` picked one inside the container
> at spawn time. A trainer who passed a path -- the obvious thing to do -- got
> a class that started cleanly and taught the alphabetically-first example
> instead, with the only warning in a container log. Selection was solving a
> problem nobody had: a class teaches one thing. The env var, the name lookup
> on the instance and the fallback are gone; the flag takes the directory, the
> check happens before anything costs money, and the mount path is a constant.

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
so it is passed in as an absolute host path via `LAB_CURRICULUM_HOST_DIR`. Unset,
the spawn still succeeds and degrades to base files with a loud log, because a
content problem should not become an outage.

With nothing mounted at `/opt/lab/curriculum`, seeding logs an error and
lays down base files only. Loud rather than fatal: a content problem should not
become an outage, but nobody should mistake the result for a lab.

Covered by `scripts/test-curriculum.sh` (seeding, cross-contamination, fallback,
marker), `scripts/test-e2e.sh` (the full Makefile -> compose -> hub ->
spawner -> seed path), and `scripts/test-containment.sh` (§5.3.1 — every
ceiling asserted against the kernel's own numbers, then attacked).

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

### `./workshop up --students N` (~5 min)

1. Generate N codes; build `codes.json`.
2. `run-instances` from the newest AMI; `wait instance-running`.
3. Read the public IP; update the Route53 A record.
4. Wait for SSH, then start reading every image file in the background. The
   root volume is restored from a snapshot and each block is slow the first
   time it is read (`claude --version` measured 24.7s cold, 1.3s after), so
   without this the first student to log in pays for the whole box. About 3
   minutes on a fresh r7i.large, overlapping the steps below.
5. Write `codes.json` to the instance. The API key is fetched on the instance
   from Parameter Store under its IAM role, and never crosses the ssh session.
6. Start the hub with this cohort's `LAB_MEM_LIMIT`, pointing it at
   `/opt/lab/curriculum`, then
   restart Caddy so it requests its certificate immediately rather than waiting
   out an ACME backoff.
7. Wait for HTTPS to answer and for the disk warm-up to finish, then print the
   URL and the code table.

`--staging` switches Caddy to the Let's Encrypt staging endpoint. Only
needed when iterating on the certificate path itself: the certificate is kept
between workshops (§5.4), so ordinary `up`/`down` cycles no longer count
against Let's Encrypt's limit.

### `./workshop down` (~1 min)

Saves Caddy's certificate to the durable bucket first, best-effort, then:

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

| Instance | RAM | Max students @ 1024 MiB measured peak | 6-hour cost |
|---|---|---|---|
| r7i.large | 16 GiB | 9 | under $1 |
| r7i.xlarge | 32 GiB | 23 | ~$2 |
| r7i.2xlarge | 64 GiB | 50 | ~$3 |
| r7i.4xlarge | 128 GiB | 106 | ~$6 |
| r7i.8xlarge | 256 GiB | 216 | ~$13 |
| r7i.12xlarge | 384 GiB | 326 | ~$19 |

Generated from `scripts/lib-size.sh`, not maintained by hand — the previous
version of this table survived two formula changes while staying on the page.
Columns are capacity at the **measured** per-seat peak, cleared with 10% slack
against usable (not nominal) memory. Raising `--mem` without supplying your own
`LAB_PEAK_MIB` measurement makes sizing fall back to planning at the cap, so
these numbers shrink accordingly.

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
| Instance dies mid-workshop | Whole class down | Rebuild from AMI, ~5 min. Accepted risk. |
| A student exhausts memory | That container OOM-killed only | `mem_limit = 2G`, and `memswap_limit = mem_limit` so it cannot swap its way into thrashing the box |
| A student pegs every core | That container throttled only | `cpu_limit`, a hard CFS quota defaulting to a quarter of the box. Verified: held to 3.04 cores against a 3.00 ceiling while spinning on 12 |
| A student fork-bombs | That container refused more processes | `pids_limit = 512` against a measured peak of 78. Verified: fork refused at 507 of 700, hub still serving logins |
| A student fills the disk | That student's own seat fills | Per-seat loop-mounted filesystem. Verified: a seat filled to 100% cost the shared filesystem 0.0 GiB and another seat stayed writable |
| The host itself runs short | Class stops | Sizing provisions for every seat at its **measured** peak simultaneously plus 4 GiB host, compares against usable rather than nominal memory, and requires 10% slack on top; a 4 GiB host swapfile backs it, and `workshop status` reports live headroom |
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

**`mkfs.ext4` discards by default and makes a preallocated image sparse.** See
§5.3.1. Measured 268435456 bytes of reserved blocks before `mkfs`, 339968
after. Every seat then overcommits the same free space while every command
still reports success.

**On a developer laptop, dockerd lives in its own mount namespace.** A loop
mount made in the VM's init namespace is invisible to the daemon, so the
bind-mount silently resolves to the underlying directory instead: the student
container comes up with the whole VM disk at `/home/jovyan` and no limit,
reporting success throughout. Verified: PID 1 at `mnt:[4026531841]`, dockerd at
`mnt:[4026532553]`. `scripts/dev-seats.sh` enters dockerd's namespace for this
reason; on the box there is no such split and the shim is unnecessary.

**`docker exec` cannot get a PID while the container's process table is full.**
The containment test's fork probe left 506 processes sleeping, and the next
test silently failed to start — reporting a pass, because "no CPU load" looked
like "the ceiling held". Tests now wait for the table to drain, and every
assertion carries a floor so a test that generates no load fails instead.

**The pids controller lets migrated tasks charge past the limit.** `pids.peak`
can legitimately sit slightly above `pids.max` (observed 517 against 512), so
asserting `peak <= max` fails a cap that is working correctly. Assert that
process creation was *refused* instead.

### Measured, not estimated

- Spawn time, native arch, image already local: **~10 seconds** to JupyterLab
  serving (spec assumed 2-5s; still well inside acceptable).
- `mem_limit` verified applied: 2147483648 bytes exactly.
- Per-seat peak memory, whole container, cgroup v2 `memory.peak`: idle lab
  **154 MiB**; Claude Code open and idle **301 MiB**; reasoning without
  executing **482 MiB**; executing a toolchain install and build **1036 MiB**.
  Anon (unreclaimable) stayed at 246 MiB throughout. Sampling at 2s intervals
  missed the true peak by 22% (846 vs 1036) — read `memory.peak`, not `docker stats`.
- Per-seat disk for one 292-package npm install and build: **252 MiB**.
- Peak process count: **21** for that install, **78** with four parallel `tsc` runs.
- Versions as built: Claude Code 2.1.276, JupyterHub 6.0.1 (hub and single-user),
  JupyterLab 4.6.3, notebook 7.6.2.

---

## 14. Deferred: split boot and data volumes

**Considered 2026-09-18, not adopted. Recorded with its trigger.**

> **Updated 2026-09-20.** Student workspaces are now per-seat filesystem images
> under `/srv/lab`, not named volumes under `/var/lib/docker/volumes` (§5.3.1),
> so a split data volume would now target `/srv/lab` instead. That change does
> not resolve this item: the images still sit on the root disk, so the AMI
> floor problem and the cohort-size coupling below are both unchanged. If
> anything the case is slightly stronger, since seat images are preallocated
> and therefore occupy their full size from the moment `up` runs.

Today the instance has one volume: OS, Docker images and student workspaces all
on the root disk, sized `15 GiB + 5 GiB/student`.

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
