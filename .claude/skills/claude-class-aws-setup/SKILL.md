---
name: claude-class-aws-setup
description: Set up this workshop environment in the user's AWS account — discovers their VPC, subnet and Route53 zones, asks only what cannot be inferred, writes workshop.conf, deploys the CloudFormation stack, stores the API key, and verifies. Use when the user wants to install, configure, set up, deploy or get started with this repo, or says the workshop is not working and they need to check their configuration.
---

# Set up the workshop environment

Your job is to get this repo running in the user's AWS account **without making
them read the README or type resource IDs**. Discover what you can, ask only
what you genuinely cannot infer, and verify each step before moving on.

## Principles

- **Discover, don't ask.** `./scripts/workshop discover` returns JSON describing
  their account. Use it to offer concrete choices rather than asking someone to
  paste a VPC ID.
- **Ask in batches, not one at a time.** Collect the open questions and put them
  in a single AskUserQuestion where the tool is available.
- **Never print the API key.** Not in a command you run, not in a summary, not
  in a file you write. See step 5.
- **Verify, don't assume.** Every step has a check. Run it.
- **Stop and report on any failure.** Do not paper over a failed step by
  continuing; the later steps depend on the earlier ones.

## Step 1 — Prerequisites

```bash
./scripts/workshop discover
```

If this fails because credentials are missing or expired, tell the user to run
`aws sso login --profile <name>` (or `aws configure`) themselves — suggest they
type `! aws sso login --profile <name>` so the output lands in the session — and
stop until they have.

From the JSON, confirm:

- `identity` is non-null — they have working credentials
- `tools.docker` is true — needed only for local testing, so warn but continue
  if false
- `vpcs` is non-empty and `public_subnets` is non-empty — **hard requirement**.
  If there is no public subnet, stop: the workshop instance must be reachable.

## Step 2 — Decide the configuration

Read `workshop.conf.example` for the full list of settings and their comments.

Infer where possible:

- **VPC** — if exactly one, use it. If several, ask, showing name/CIDR/default.
- **Subnet** — leave `LAB_SUBNET_ID` empty; the tool auto-selects a public subnet
  in the security group's VPC. Only set it if they ask for a specific one.
- **Region and profile** — take from the `discover` output.
- **SSH key** — look for `~/.ssh/id_ed25519.pub`, then `~/.ssh/id_rsa.pub`. If
  neither exists, tell the user to run `! ssh-keygen -t ed25519` themselves.

Ask about (batch these into one question):

- **Hostname.** What URL should students visit? Compare their answer against
  `hosted_zones` in the discover output:
  - **Their answer is under a zone they already own** (e.g. `labs.example.com`
    and they have `example.com`): set `LAB_HOSTED_ZONE_ID` to that zone's id.
    This is the simple path — no delegation needed.
  - **No matching zone**: they either need to register the domain first, or the
    parent zone lives in another AWS account. In the second case leave
    `LAB_HOSTED_ZONE_ID` empty; the stack creates a zone and step 4 walks them
    through delegating it.
- **Expected cohort size.** Not stored in config — `--students` is passed per
  workshop — but use it to show them what `./scripts/workshop size --students N`
  reports, so the cost is concrete before they commit.
- **Curriculum.** The repo ships `intro-agents` and `mcp-servers` as examples.
  Ask whether they will write their own; if so, mention `LAB_CURRICULA_DIR` can
  point outside the repo to keep course content private.

## Step 3 — Write the config

Copy `workshop.conf.example` to `workshop.conf` and set the values decided
above. Keep the explanatory comments. `workshop.conf` is gitignored.

Show the user the finished file before proceeding.

## Step 4 — Deploy the durable stack

```bash
./scripts/workshop init
```

This reads `workshop.conf` and deploys security group, IAM role, key pair and
DNS. It costs about $0.50/month and persists between workshops.

**If it printed nameservers**, the stack created a zone and delegation is
required. The user must add those four as an `NS` record for the hostname in the
parent zone — possibly in a different AWS account, possibly at a non-AWS
registrar. Give them the exact values, then poll until it resolves:

```bash
dig +short NS <hostname>
```

Do not continue until that returns the nameservers. Nothing downstream works
without it, and Let's Encrypt will fail in a way that looks like a TLS bug.

## Step 5 — Store the API key

The workshop needs an Anthropic API key. **Do not ask the user to paste it into
the conversation, and never run a command containing it.**

Tell them to run it themselves, using the `!` prefix so it executes in their
session and never passes through you:

```
! aws ssm put-parameter --name /ai-agents-lab/anthropic-api-key --type SecureString --value 'sk-ant-...' --profile <their-profile>
```

Then verify without revealing the value:

```bash
aws ssm get-parameter --name /ai-agents-lab/anthropic-api-key --with-decryption --query 'Parameter.Value' --output text | wc -c
```

A plausible length confirms it. Also remind them, once and plainly, to set a
**spend limit on that key in the Anthropic Console** — it is shared by the whole
cohort with no cap, and model spend dwarfs infrastructure cost.

## Step 6 — Verify locally before spending on AWS

```bash
make dev-build
make dev-up CURRICULUM=intro-agents
```

Open `http://localhost:8000` and log in with a code from `hub/codes.json`. This
proves the images and hub work before any EC2 cost. Then `make dev-down`.

If the student container serves JupyterLab but Claude Code will not start,
the image was built for the wrong architecture — `make dev-build` builds native,
`make prod-build` builds amd64 for the AMI.

## Step 7 — Bake the AMI

```bash
./scripts/workshop build
```

Takes about 20 minutes. Tell the user it is long-running before you start it,
and that it should be run the day before a workshop rather than the morning of.

## Step 8 — Hand over

Summarize:

- The URL students will visit
- The three commands they will actually use: `up --students N --curriculum X`,
  `down`, `status`
- That `down` destroys everything including student work, by design
- Their idle cost now (~$1/month) and per-workshop cost from
  `./scripts/workshop size`

Offer to run a real `up` with 2 students so they can click through it, and make
clear it starts billing until they run `down`.

## If something fails

- **`init` fails on IAM** — their credentials lack CloudFormation or IAM rights.
  Report exactly which call failed.
- **TLS never issues** — almost always DNS. Re-check step 4's `dig`.
- **`up` says no AMI found** — step 7 has not run or did not finish.
- **A student container starts then disappears** — check `docker logs` on the
  box; `remove = True` deletes failed spawns before they can be inspected.

`docs/SPEC.md` has the design rationale and a list of traps found while building
this. Consult it before inventing an explanation for unexpected behaviour.
