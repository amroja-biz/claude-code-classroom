# aws-lab-creator-ai-agents

A disposable, browser-based workshop environment for teaching people to work
with AI agents. Students open a URL, enter a code from their handout, and land
in a browser terminal with Claude Code already running. When the class ends, the
environment is destroyed.

One EC2 instance, Docker, and Caddy. No ALB, NAT Gateway, ECS, EKS, EFS or
Cognito. Idle cost between workshops is roughly $1/month, and a six-hour
workshop for 30 students is a few dollars — indicative us-east-1 figures; check
AWS pricing for your region.

Design rationale, cost model and deferred decisions: [`docs/SPEC.md`](docs/SPEC.md).

---

## IMPORTANT: read before deploying

**1. Claude Code runs with `--dangerously-skip-permissions`.** Every student's
agent can read, write and execute without confirmation prompts. This is
appropriate for a time-boxed workshop on a disposable host with participants you
know. It is not appropriate for untrusted participants, for anything
long-lived, or for a host with access to data or networks you care about.
Containers isolate students from each other; a container escape compromises the
host. The host exists for hours and is then destroyed — that is the primary
control, and it only works if you actually destroy it.

**2. One Anthropic API key is shared by the whole cohort, with no spend cap.**
Every student's usage bills to the same key, and nothing here limits
consumption. Use a **dedicated key with a spend limit set in the Anthropic
Console**, not your main key. Per-student attribution does not exist.

Model usage, not infrastructure, is what a workshop costs. A comparable
published run ([geneontology/go-jupyter](https://github.com/geneontology/go-jupyter),
~40 participants, 4 hours) spent **$8 on EC2 and $380 on model API calls** —
roughly 50x. Every infrastructure figure in this README is real and also nearly
irrelevant to your total. Set the spend limit before you hand out codes.

---

## Requirements

- An AWS account with a VPC containing at least one public subnet
- A Route53 domain whose subdomain you can delegate
- `aws` CLI v2, configured
- Docker (for local development)
- An Anthropic API key

## Install

```bash
git clone <this repo> && cd aws-lab-creator-ai-agents
cp workshop.conf.example workshop.conf
$EDITOR workshop.conf
```

`workshop.conf` is gitignored and holds everything account-specific:

| Setting | Meaning |
|---|---|
| `LAB_DOMAIN` | Hostname students visit, e.g. `labs.example.com` |
| `LAB_HOSTED_ZONE_ID` | Your existing Route53 zone in this account; empty creates a delegated one |
| `LAB_AWS_PROFILE` / `LAB_AWS_REGION` | Profile and region for every AWS call |
| `LAB_VPC_ID` | VPC for the security group |
| `LAB_SUBNET_ID` | Optional; a public subnet is auto-selected if empty |
| `LAB_SSH_PUBLIC_KEY` | Key installed on the instance |
| `LAB_STACK` / `LAB_TAG` | Change both to run several independent labs in one account |
| `LAB_CURRICULA_DIR` | Where curricula are read from; may point outside this repo |
| `LAB_SSM_PARAM` | SSM Parameter Store path holding the API key (recommended) |
| `LAB_API_KEY_CMD` | Fallback: a command that prints the API key |

## Configure AWS

Deploy the durable resources — hosted zone, security group, IAM role, key pair.
These persist between workshops and cost about $0.50/month.

**If your domain is already a Route53 zone in this account** — the normal case —
pass its zone ID. The stack writes the workshop A record into that zone and
creates nothing else DNS-related. No delegation, no second zone.

```bash
aws route53 list-hosted-zones --query 'HostedZones[].{Name:Name,Id:Id}' --output table

aws cloudformation deploy \
  --template-file infra/durable.yaml \
  --stack-name "$LAB_STACK" \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
      DomainName="$LAB_DOMAIN" \
      ExistingHostedZoneId="$LAB_HOSTED_ZONE_ID" \
      VpcId="$LAB_VPC_ID" \
      SshPublicKey="$(cat ~/.ssh/id_ed25519.pub)"
```

<details>
<summary><b>If instead you want a separate zone for the subdomain</b></summary>

Leave `ExistingHostedZoneId` empty and the stack creates a hosted zone for
`LAB_DOMAIN`. You then delegate to it once, by adding its nameservers as an `NS`
record in the parent zone. This is the path to use when the parent domain lives
in a **different AWS account**, or when you want the lab's DNS isolated from
your main zone.

```bash
aws cloudformation describe-stacks --stack-name "$LAB_STACK" \
  --query 'Stacks[0].Outputs[?OutputKey==`NameServers`].OutputValue' --output text
# add those four as an NS record for LAB_DOMAIN in the parent zone, then:
dig +short NS "$LAB_DOMAIN"    # confirm delegation before continuing
```

The extra zone costs $0.50/month.
</details>

### Store the API key

```bash
aws ssm put-parameter \
  --name /ai-agents-lab/anthropic-api-key \
  --type SecureString \
  --value 'sk-ant-...'
```

Set `LAB_SSM_PARAM` to that path and pass `SsmParameterName` to the stack. The
instance then fetches the key under its own IAM role at startup: the key never
sits on your machine and never crosses the SSH session. Rotating it is the same
command with `--overwrite`; no rebuild, no redeploy.

If `LAB_SSM_PARAM` is empty, the key is resolved locally instead, in this order:
`LAB_API_KEY_CMD`, `$ANTHROPIC_API_KEY`, then the macOS keychain entry
`ANTHROPIC_API_KEY`.

**Why Parameter Store and not Secrets Manager.** Secrets Manager costs $0.40 per
secret per month. Standard-tier SecureString parameters are free. Secrets
Manager's distinguishing feature is automated rotation, which does not apply
here — AWS has no rotation mechanism for an Anthropic API key, so it is rotated
by hand in the Anthropic Console either way. This deployment targets near-zero
idle cost between courses, and $0.40/month for an unusable feature is roughly a
third of the entire idle budget.

Students can read the key from their own container environment regardless of how
it is stored; Claude Code requires it there. Parameter Store changes where the
key is held and who has to handle it, not who can read it at runtime. The spend
limit is the control that matters.

## Run a workshop

```bash
./scripts/workshop build                                      # day before, ~20 min
./scripts/workshop up --students 30 --curriculum intro-agents # ~3 min
./scripts/workshop down                                       # after class
./scripts/workshop status                                     # what exists
```

`up` prints the URL and a code table to paste into a handout. Codes are
regenerated every time, so the previous cohort's codes stop working with no
revocation step.

`build` bakes an AMI: a temporary instance installs Docker and Caddy, builds both
images, is snapshotted, then terminated. Old AMIs are pruned, deregistering
**and** deleting their snapshots. Run it the day before, not the morning of —
Claude Code ships frequently, and a broken upstream should surface with a day of
slack.

`down` terminates the instance and removes the A record. The root volume is
`DeleteOnTermination`. **Nothing is preserved**, including student work.

### While iterating, use `--staging`

```bash
./scripts/workshop up --students 2 --curriculum intro-agents --staging
```

Let's Encrypt allows 5 duplicate certificates per week per hostname. A debugging
loop exhausts that and locks out the real certificate for days. `--staging` uses
the LE staging endpoint; browsers will warn, which is the correct trade while
testing.

## Curricula

Course material is data, not code. A curriculum is a directory:

```
<curriculum>/
├── welcome.txt     (optional)  shown in the student's banner
├── skills/         (optional)  copied to ~/.claude/skills/
└── everything else             copied to ~/  (lessons/, CLAUDE.md, data/, ...)
```

Every curriculum is baked into the image and one is selected at spawn time, so
switching a cohort to different material is a flag, not a rebuild. Only
authoring new material requires `build`. An unknown name falls back to the
alphabetically-first curriculum and logs a warning.

Student homes follow a fixed contract, stated in each curriculum's `CLAUDE.md`,
in its lessons, and in the login banner: `~/lessons` is read-only material,
`~/work` is where the student's files go.

Point `LAB_CURRICULA_DIR` at a private directory or repo to keep course content
out of this repository. The two curricula here are examples.

```bash
make curricula     # what's baked into the current image
```

## Local development

Everything below runs on Docker with no AWS spend.

```bash
make dev-build                      # build both images for your host arch
make dev-up CURRICULUM=intro-agents # hub on http://localhost:8000
make dev-logs
make dev-reset                      # stop and drop student home volumes
```

Log in with a code from `hub/codes.json`.

```bash
./scripts/test-size.sh                        # sizing and its boundaries
./scripts/test-curriculum.sh                  # seeding, isolation, fallback
./scripts/test-e2e.sh mcp-servers             # local login -> spawn -> material
./scripts/test-live.sh "$LAB_DOMAIN" <code>   # a deployed workshop
```

## Sizing

There is no default cohort size. `--students` is required, and the instance type
is derived: the smallest `r7i` that fits `students × --mem + 4 GiB` of host
overhead. Within the `r7i` family the cost per GiB-hour is the same at every
size, so no size is a better deal than another — only fit matters.

| Instance | RAM | Max seats @ 2 GiB |
|---|---|---|
| r7i.large | 16 GiB | 6 |
| r7i.xlarge | 32 GiB | 14 |
| r7i.2xlarge | 64 GiB | 30 |
| r7i.4xlarge | 128 GiB | 62 |
| r7i.8xlarge | 256 GiB | 126 |
| r7i.12xlarge | 384 GiB | 190 |

Past 190 seats nothing fits and `up` refuses; run multiple independent stacks and
encode the box in the login code.

```bash
./scripts/workshop size --students 30
./scripts/workshop size --students 30 --mem 4
```

Root volume is sized for **tool caches, not authored files**: `15 GiB + 5 GiB
per student`. A student's own work is trivially small, but the `uv`, `pip` and
`npm` installs they make during exercises are not — the go-jupyter workshop
needed 150–200 GB for ~40 participants. Sizing this from an empty home is how
you fill the disk mid-session.

**This volume is ephemeral.** It is created at `up` with
`DeleteOnTermination=true` and destroyed by `down`, so a large root disk costs
only for the hours the workshop runs — 165 GiB for six hours is about 11 cents.
Nothing of that size persists between classes. The only thing that does is the
AMI snapshot, which is built at the 20 GiB floor and stores just its used blocks.

Memory-optimized (`r7i`) is the default because Claude Code is mostly I/O bound
waiting on the model. If your exercises execute a lot of code rather than mostly
calling the model, CPU becomes the constraint — that workshop saw load peak
above 3.0 during concurrent script runs and tool installs. Pass
`--instance-type` to use a compute-optimized family instead.

`workshop size` prints indicative costs based on us-east-1 on-demand pricing
captured 2026-09-18. **Consult AWS pricing for your region for actual figures.**
Prices vary by region and change over time. Nothing in the tool depends on them
being exact — the instance choice is driven purely by memory, which is
region-independent.

## How it works

```
browser ──https──► Caddy ──► JupyterHub ──► one container per student
                                            (Claude Code, JupyterLab, 2 GiB cap)
```

JupyterHub runs in a container and spawns sibling student containers through the
Docker socket, so the local harness and the deployed box are the same
`docker-compose.yml`. A code maps to a seat name; there are no accounts and no
passwords. Each container is capped with `mem_limit`, so one runaway agent is
OOM-killed in its own cgroup instead of driving the host into memory-reclaim
livelock.

## Constraints worth knowing

**Build native locally, amd64 for the AMI.** Claude Code ships as a Bun binary
whose JS engine crashes under QEMU emulation (`MemoryExhaustion` →
`qemu: uncaught target signal 6`). On Apple Silicon an amd64 student image will
serve JupyterLab but Claude Code will not start. `make dev-build` builds native;
`make prod-build` builds amd64.

**Never set `set -e`/`set -u` in a `before-notebook.d` hook.** docker-stacks
*sources* those scripts into `start.sh`, so shell options leak into the parent
and kill it on its own unset `JUPYTER_DOCKER_STACKS_QUIET`. The hook here runs
the real script as a subprocess.

**Home seeding happens at container start, not image build.** DockerSpawner
mounts a named volume over `/home/jovyan`, shadowing anything baked at that path.
Content lives in `/opt/lab/` and is copied in, guarded by a `.lab-seeded` marker
so a container restarting mid-workshop keeps the student's work.

**`Authenticator.allow_all = True` is required.** JupyterHub 5.0+ stopped
implicitly allowing users that authenticate successfully.

**An instance cannot have a root volume smaller than its AMI's snapshot.** `up`
takes whichever is larger, cohort need or AMI floor, and says so.

## Acknowledgements

This project began as a re-architecture of
[geneontology/go-jupyter](https://github.com/geneontology/go-jupyter), which
solves the same problem — JupyterHub on EC2 giving each participant a browser
terminal with Claude Code — for agentic biocuration workshops run by the Gene
Ontology Consortium.

Beyond the architecture, their published workshop write-up supplied findings
this project acts on directly: which Claude Code settings suppress first-run
prompts, that per-user tool caches rather than authored files drive disk
requirements, that context carried between exercises triggers compaction, and
that model API spend dwarfs infrastructure cost by roughly 50x. Those are
expensive lessons to learn from a live room, and they published them.

About 6% of this project's code is derived from theirs — principally the Claude
Code first-run state seeding — and remains under its BSD 3-Clause License. See
[NOTICE](NOTICE) for exactly which parts and how that was measured.

## License

MIT — see [LICENSE](LICENSE), and [NOTICE](NOTICE) for the derived portions.
