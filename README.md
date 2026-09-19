# claude-code-class-environment-aws

A disposable workshop environment for teaching people to work with AI agents.
Students open a URL, enter a code from their handout, and land in a browser
terminal with Claude Code already running. `down` destroys everything.

One EC2 instance, Docker and Caddy — no ALB, NAT, ECS, EKS, EFS or Cognito.
Idle cost between workshops is about $1/month.

Design decisions, sizing tables and the traps found while building it:
**[`docs/SPEC.md`](docs/SPEC.md)**.

---

## IMPORTANT

**Claude Code runs with `--dangerously-skip-permissions`.** Students' agents
execute without confirmation prompts. Fine for a time-boxed workshop on a
disposable host with people you know; not for untrusted participants, anything
long-lived, or a host with access to data you care about. The host existing for
only a few hours is the primary control — it only works if you run `down`.

**One API key is shared by the cohort, with no spend cap.** Use a **dedicated
key with a spend limit set in the Anthropic Console**, not your main key.
Students can read it from their own container; that is unavoidable. A comparable
published workshop (~40 people, 4 hours) spent **$8 on EC2 and $380 on model API
calls** — infrastructure cost is a rounding error, so set the limit before you
hand out codes.

---

## Setup

Needs an AWS account with a VPC and public subnet, a Route53 domain, `aws` CLI
v2, Docker, and an Anthropic API key.

```bash
cp workshop.conf.example workshop.conf && $EDITOR workshop.conf
```

`workshop.conf` is gitignored and holds everything account-specific: domain,
hosted zone, profile, region, VPC, SSH key, stack name, curricula directory, and
where the API key comes from. Each setting is commented in the example.

Then deploy the durable resources — security group, IAM role, key pair and DNS:

```bash
./scripts/workshop init
```

That reads `workshop.conf`, so there is nothing to retype. If you set
`LAB_HOSTED_ZONE_ID` to a Route53 zone you already own in this account, the stack
writes records into it. Leave it empty and the stack creates a zone for the
subdomain instead, printing the nameservers to delegate from the parent — the
path to use when the parent domain lives in a different AWS account.

Finally store the API key where the instance can fetch it under its own IAM role,
rather than you handling it on every `up`:

```bash
aws ssm put-parameter --name /ai-agents-lab/anthropic-api-key \
  --type SecureString --value 'sk-ant-...'
```

## Run a workshop

```bash
./scripts/workshop build                                      # day before, ~20 min
./scripts/workshop up --students 30 --curriculum intro-agents # ~3 min
./scripts/workshop down                                       # after class
./scripts/workshop size --students 30                         # what it would cost
./scripts/workshop status
```

`up` prints the URL and a code table to paste into a handout. Codes are new every
time, so the last cohort's stop working. Instance type and disk are derived from
`--students`; there is no default cohort size.

Run `build` the day *before* — Claude Code ships often, and a broken upstream
should surface with a day of slack. While iterating, add `--staging`: Let's
Encrypt allows only 5 duplicate certificates per week per hostname, and a
debugging loop will exhaust that.

`down` terminates the instance and removes the A record. **Nothing is preserved**,
including student work.

## Curricula

Course material is data. A curriculum is a directory:

```
<curriculum>/
├── welcome.txt     (optional)  shown in the student's banner
├── skills/         (optional)  copied to ~/.claude/skills/
└── everything else             copied to ~/  (lessons/, CLAUDE.md, ...)
```

All curricula are baked into the image and one is chosen at spawn time, so
switching material is a flag, not a rebuild. Students get `~/lessons` (read-only
material) and `~/work` (their files) — a contract stated in each curriculum's
`CLAUDE.md`. Point `LAB_CURRICULA_DIR` outside this repo to keep your content
private; the two here are examples.

## Local development

Runs entirely on Docker, no AWS spend.

```bash
make dev-build && make dev-up CURRICULUM=intro-agents   # http://localhost:8000
make dev-reset                                          # wipe and start over
./scripts/test-size.sh && ./scripts/test-curriculum.sh && ./scripts/test-e2e.sh
```

Log in with a code from `hub/codes.json`.

**Build native locally, amd64 for the AMI.** Claude Code is a Bun binary whose JS
engine crashes under QEMU, so an amd64 student image on Apple Silicon serves
JupyterLab but won't start Claude Code. `make dev-build` is native;
`make prod-build` is amd64. Other traps of this kind are in
[`docs/SPEC.md`](docs/SPEC.md).

## Acknowledgements

Began as a re-architecture of
[geneontology/go-jupyter](https://github.com/geneontology/go-jupyter) by the Gene
Ontology Consortium, which solves the same problem for agentic biocuration
workshops. The Claude Code first-run state seeding came from them more or less
intact, as did several hard-won operational findings. Everything else here is
new. See [NOTICE](NOTICE).

## License

MIT — see [LICENSE](LICENSE).
