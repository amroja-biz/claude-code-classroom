---
name: claude-classroom-aws-setup
description: Set up this workshop environment in the user's AWS account — discovers their VPC, subnet and Route53 zones, asks only what cannot be inferred, and asks for user confirmation for things that can. Writes workshop.conf, deploys the CloudFormation stack, stores the Anthropic API key, and verifies. Use when the user wants to install, configure, set up, deploy or get started with this repo, or says the workshop is not working and they need to check their configuration.
---

# Set up the workshop environment

Your job is to get this repo running in the user's AWS account **without making
them read the README or type resource IDs**. Discover what you can, ask only
what you genuinely cannot infer, raise important issues to user for confirmation to 
ensure your inferences do not amount to incorrect assumptions and verify each 
step before moving on.

## Principles

- **Discover, don't ask.** `./scripts/workshop discover` returns JSON describing
  their account. Use it to offer concrete choices rather than asking someone to
  paste a VPC ID. If multiple accounts or profiles are available, you must ask the
  user which one to use and remember it.
- **Ask in batches, not one at a time.** Collect the open questions and put them
  in a single AskUserQuestion where the tool is available.
- **Never print the API key.** Not in a command you run, not in a summary, not
  in a file you write. See step 5.
- **Verify, don't assume.** Every step has a check. Run it.
- **Stop and report on any failure.** Do not paper over a failed step by
  continuing; the later steps depend on the earlier ones.

## Step 1 — Prerequisites

Alert the user that they must have an AWS account with appropriate permissions,
an Anthropic API key, an ssh key, and a domain they can point at this — either a
Route53 zone in this account, or one they can add an NS record to elsewhere.
Docker is not needed: every image is built on the EC2 instance.

```bash
./scripts/workshop discover
```

If this fails because credentials are missing or expired, tell the user to run
`aws sso login --profile <name>` (or `aws configure`) themselves — suggest they
type `! aws sso login --profile <name>` so the output lands in the session — and
stop until they have.

### Choose the AWS profile before anything else

`discover` reports two fields: `profile`, the one it actually used, and
`profiles`, every profile configured on the machine. The script exports a single
`AWS_PROFILE` for every AWS call it makes, so this one choice governs the whole
install — and an unset profile falls through to `default`, which on a
multi-account machine is rarely the intended account.

- **`profiles` has one entry, or is empty** — nothing to choose. Continue.
- **`profiles` has several** — stop and ask. Show the list, and show which
  account `identity` resolved to, so they can see what `default` would have
  given them. Never pick one yourself, and never treat the `default` fallback as
  a decision the user made.

Once they choose, re-run discovery against it and use that output from here on:

```bash
AWS_PROFILE=<name> ./scripts/workshop discover
```

Record it as `LAB_AWS_PROFILE` in step 3 — that is what makes the choice stick
for `init`, `up`, `down` and `status`.

If the user exported `AWS_PROFILE` themselves before starting, `discover` has
already picked it up. Confirm it is the account they mean rather than assuming
the export was deliberate.

**One profile, one account.** The tool cannot reach a second account, so if the
domain's parent zone lives elsewhere, that shows up as a missing zone in step 2
and a manual delegation in step 4. That is expected, not a failure.

From the JSON, confirm:

- `identity` is non-null — they have working credentials
- `tools.docker` — **ignore it.** Docker is not needed to install or run a
  workshop; the images are built on the EC2 instance. Do not mention it, and do
  not warn if it is false.
- `vpcs` is non-empty and `public_subnets` is non-empty — **hard requirement**.
  If there is no public subnet, stop: the workshop instance must be reachable.

## Step 2 — Decide the configuration

Read `workshop.conf.example` for the full list of settings and their comments.

Infer where possible:

- **VPC** — if exactly one, use it. If several, ask, showing name/CIDR/default.
- **Subnet** — leave `LAB_SUBNET_ID` empty; the tool auto-selects a public subnet
  in the security group's VPC. Only set it if they ask for a specific one.
- **Region** — take from the `discover` output.
- **Profile** — already settled in step 1. Do not re-derive it here; write
  the profile the user chose into `LAB_AWS_PROFILE`.
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
- **Curriculum.** Ask **which one**, not whether. A class runs exactly one
  curriculum: `--curriculum` selects a single directory and its contents are
  what every student gets. "The examples" is not a possible answer, so do not
  offer it as one — a user who picks it will reasonably expect the material
  from both and receive one.

  List what is actually there, with what each contains, and say plainly that
  both are thin placeholders rather than courses:

  ```bash
  for c in curricula/*/; do
      echo "=== $(basename "$c")"; find "$c" -type f | sed "s|$c||"
  done
  ```

  Their answer is the value you pass to `--curriculum` in step 7. Carry it
  forward; do not substitute a different one because it is first alphabetically.

  If they say they will write their own, point them at the
  `claude-classroom-new-curriculum` skill and mention that `--curriculum`
  takes a path, so course content can live anywhere and stay out of this repo.
  Switching between curricula later is a `down` and an `up` with a different
  `--curriculum`, not a rebuild.

## Step 3 — Write the config

Copy `workshop.conf.example` to `workshop.conf` and set the values decided
above. Keep the explanatory comments. `workshop.conf` is gitignored.

`LAB_SSM_PARAM` is required and the example's default
(`/claude-classroom/anthropic-api-key`) is fine unless they want another name.
It has to be right *before* step 4, because the stack grants the instance role
read access to exactly that parameter name. The key itself does not need to
exist yet — that is step 5.

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

Parameter Store is the only supported source. The instance fetches the key under
its own IAM role, so it never touches the operator's machine and never crosses an
ssh session — there is no environment-variable or keychain path to fall back to.

**Do not ask the user to paste the key into the conversation, and never run a
command containing it.**

Tell them to run it themselves, using the `!` prefix so it executes in their
session and never passes through you — with the name they set as `LAB_SSM_PARAM`:

```
! aws ssm put-parameter --name /claude-classroom/anthropic-api-key --type SecureString --value 'sk-ant-...' --profile <their-profile>
```

Then verify without revealing the value:

```bash
aws ssm get-parameter --name /claude-classroom/anthropic-api-key --with-decryption --query 'Parameter.Value' --output text | wc -c
```

A plausible length confirms it. Also remind them, once and plainly, to set a
**spend limit on that key in the Anthropic Console** — it is shared by the whole
cohort with no cap, and model spend dwarfs infrastructure cost.

## Step 6 — Bake the AMI

```bash
./scripts/workshop build
```

Takes about 20 minutes. Say so before you start it, and say why the timing
matters: it should be run the day before a workshop, not the morning of. Claude
Code ships often and this step pulls from several upstreams, so a failure wants
a day of slack rather than thirty minutes.

This builds the images on an EC2 instance and snapshots it. Nothing is built on
the user's machine, and Docker is not required locally.

## Step 7 — Rehearse, as a student

**Do not skip this, and do not offer to skip it.** Everything up to here proves
the infrastructure exists. Only this proves a student can get a container — and
nothing between `build` and a real login exercises a spawn.

Use **the curriculum they chose in step 2**, not a hardcoded one. Rehearsing
with different material than the class will teach proves the wrong thing, and
the student will notice the difference before you do.

```bash
./scripts/workshop up --students 2 --curriculum <their choice from step 2>
```

Then have the user open the URL, enter the first code from the table, and
confirm three things: JupyterLab loads, the welcome banner names **their**
curriculum, and `claude` starts on its own without them typing it. Tell them
what they should see before they look, so a broken lab is obvious.

A bare shell prompt with no banner is a failure, not a cosmetic one — it means
the login-shell chain that launches the agent is broken, and a student would sit
in front of a terminal with nothing telling them what to do.

When it works:

```bash
./scripts/workshop down
```

Say plainly that billing runs until they do. Then tell them the rehearsal is
repeatable and is the recommended habit the night before a class, with the real
`--students N` so the instance they test is the instance they teach on. A fresh
`up` the next morning is a carbon copy: same AMI, same images, same curricula,
and nothing is fetched from the internet at `up` time.

If the spawn fails, stop and report it rather than continuing to step 8. Check
`docker logs` on the box — `remove = True` deletes a failed container quickly, so
look promptly.

## Step 8 — Hand over

Summarize:

- The URL students will visit
- The three commands they will actually use: `up --students N --curriculum X`,
  `down`, `status`
- That `down` destroys everything including student work, by design
- Their idle cost now (~$1/month) and per-workshop cost from
  `./scripts/workshop size`

- That the rehearsal in step 7 is the habit to keep: `up` with the real cohort
  size the night before, log in as a student, then `down`

Point them at the README for running workshops. Point them at
`docs/DEVELOPMENT.md` only if they say they want to change the platform itself —
it is for contributors, and nothing in it is needed to teach a class.

## If something fails

- **`init` fails on IAM** — their credentials lack CloudFormation or IAM rights.
  Report exactly which call failed.
- **TLS never issues** — almost always DNS. Re-check step 4's `dig`.
- **`up` says no AMI found** — step 7 has not run or did not finish.
- **A student container starts then disappears** — check `docker logs` on the
  box; `remove = True` deletes failed spawns before they can be inspected.

`docs/SPEC.md` has the design rationale and a list of traps found while building
this. Consult it before inventing an explanation for unexpected behaviour.
