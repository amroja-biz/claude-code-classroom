# Claude Code Classroom

A disposable workshop environment for teaching people to work with AI agents.
Students open a URL, enter a code from their handout, and land in JupyterLab.
Opening a terminal there starts Claude Code after a short welcome banner.
`down` destroys everything.

One EC2 instance, Docker and Caddy — no ALB, NAT, ECS, EKS, EFS or Cognito.
Idle cost between workshops is about $1/month.

---

## IMPORTANT

**Claude Code runs with `--dangerously-skip-permissions`.** Students' agents
execute without confirmation prompts. 

**One Anthropic API key is shared by the class.** It is recommended that you 
create a dedicated key in the Anthropic Console and set a spending cap for each class.
Students can read the key from their class environment.

**Class cost expectations**
The AWS infrastructure supporting each class has been tuned so as to incur minimal costs. 
However, Claude costs could be in the hundreds of dollars. A comparable published workshop 
(~40 people, 4 hours) spent $8 on EC2 and $380 on model API calls.

---

## Setup

Open this repo in Claude Code (or any coding agent that reads
`.claude/skills/`) and ask it:

> Use the `claude-classroom-aws-setup` skill in this repo to configure a class

It inspects your AWS account, offers choices instead of asking for resource IDs,
asks only what it cannot infer, writes the config, deploys the stack, walks you
through DNS delegation if needed, and verifies each step. The API key is handled
so that it never passes through the agent.

<details>
<summary><b>Manual setup, if you would rather not</b></summary>

Needs an AWS account with a VPC and public subnet, a domain you can point at it,
`aws` CLI v2, and an Anthropic API key. Docker is not required — the images are
built on the EC2 instance, not on your machine.

```bash
cp workshop.conf.example workshop.conf && $EDITOR workshop.conf
./scripts/workshop init
```

`workshop.conf` is gitignored and holds everything account-specific. Four
settings are required — `LAB_DOMAIN`, `LAB_VPC_ID`, `LAB_SSH_PUBLIC_KEY` and
`LAB_SSM_PARAM` — and the rest have working defaults. `./scripts/workshop
discover` prints what your account offers, which is what you need to fill it in.

If you have more than one AWS profile, set `LAB_AWS_PROFILE`. Every AWS call
uses that one profile, and `default` is rarely the account you mean. It takes
precedence over an `AWS_PROFILE` exported in your shell, so the account a
command acts on is the one written in the config — every command that changes
anything prints the profile and account id before it starts.

`init` deploys the durable resources — security group, IAM role, key pair, DNS —
about $0.50/month. Set `LAB_HOSTED_ZONE_ID` to a Route53 zone you already own in
this account and the stack writes records into it. Leave it empty and the stack
creates a zone for the subdomain instead, printing nameservers to delegate from
the parent — the path to use when the parent domain lives in a different AWS
account.

`LAB_SSM_PARAM` must be set before `init`, because the stack grants the instance
role read access to exactly that parameter name. The key itself can be stored
afterwards, any time before your first `up` — the instance fetches it under its
own IAM role, and there is no other supported source:

```bash
aws ssm put-parameter --name /claude-classroom/anthropic-api-key \
  --type SecureString --value 'sk-ant-...'
```

</details>

## Run a workshop

```bash
./scripts/workshop build                                      # day before, ~20 min
./scripts/workshop up --students 30 --curriculum intro-agents # ~5 min
./scripts/workshop down                                       # after class
./scripts/workshop size --students 30                         # what it would cost
./scripts/workshop status
./scripts/workshop codes                                      # reprint URL + codes
```

`up` prints the URL and a code table to paste into a handout. Codes are new every
time, so the last cohort's stop working. If you lose the table, `codes` reads it
back from the running instance. Instance type and disk are derived from
`--students`; there is no default cohort size.

`down` terminates the instance and removes the A record. **Nothing is preserved**,
including student work.

### One student cannot end the class

Every seat runs with a ceiling on each resource it could otherwise exhaust for
everyone else. You do not configure any of this; it is why `size` picks the box
it picks.

| If a student… | What happens |
|---|---|
| runs out of memory | only their container is killed, and it restarts with their work intact |
| pegs every CPU | only their container is throttled; the room stays responsive |
| fork-bombs the machine | their container is refused more processes; the hub keeps serving |
| fills the disk | only their own seat fills; everyone else keeps working |

`size` shows the reasoning behind the instance it chose, including what would
happen if every seat used its full memory allowance at once.

If your course material is heavier than the default assumption — large models,
big datasets, long-running builds — raise the per-seat allowance with
`--mem <GiB>` and `size` will pick a correspondingly larger box.

## Rehearse the night before

Run `build` the day *before* the class — Claude Code ships often, and a broken
upstream should surface with a day of slack rather than thirty minutes before
students arrive.

Then do a full dress rehearsal, because it is the only thing that proves a
student can actually get a container:

```bash
./scripts/workshop up --students 30 --curriculum intro-agents
# open the URL, enter the first code, confirm you land in JupyterLab,
# then open a Terminal: the banner shows and Claude Code starts on its
# own. Having to type `claude` means the AMI is stale: `workshop build`
./scripts/workshop down
```

Use the real cohort size, so the instance you test is the instance you will
teach on. In the morning, `up` again: same AMI, same images, same curricula, and
nothing is fetched from the internet at `up` time — so it is a carbon copy of
what you just verified.

If you edit a curriculum after the rehearsal, you have changed the thing you
tested. Re-run `up` and check it; that costs about five minutes.

### If the URL works on your phone but not your laptop

`down` removes the DNS record, so between classes the hostname does not exist.
If anything on a network looks it up in that gap, for example you checking
whether `up` has finished, the network's router can remember "does not exist" for
up to 15 minutes after the record comes back. The lab is fine; that one network
cannot see it yet. `up` will warn that the lab is up but this machine cannot
reach it by name, and will still print the code table.

That is also why you should **not share the URL until `up` has printed the code
table**. One student trying it early on the venue Wi-Fi can hide the lab from the
whole room for 15 minutes.

To get past it:

- **Wait.** It clears on its own within 15 minutes.
- **Use another network**, such as a phone hotspot.
- **Turn on secure DNS in your browser** (Chrome: *Settings → Privacy and
  security → Security → Use secure DNS*). The browser then skips the router.
  This is the one to leave on if your network does this often.
- **Pin the address on your laptop**, using the IP that `up` printed:

  ```bash
  echo "<IP> training.example.com" | sudo tee -a /etc/hosts
  ```

  Remove it after class with
  `sudo sed -i '' '/training.example.com/d' /etc/hosts`. The IP changes on every
  `up`, so a line you forget will send your laptop to a dead address next time,
  and the lab will look broken only to you.

### If the browser says the site "took too long to respond"

If your phone can reach the lab and your laptop cannot, you probably have a
leftover `/etc/hosts` line from pinning an earlier class. It still points at
the old, terminated instance. `/etc/hosts` is checked before DNS, so flushing
the DNS cache does not help. `up` hits the same dead address, so it warns that
this machine cannot reach the lab by name.

Check for it:

```bash
grep training.example.com /etc/hosts
```

If that prints anything, delete the lines, then quit and reopen your browser,
which keeps its own copy of the old address:

```bash
sudo sed -i '' '/training.example.com/d' /etc/hosts
```

## Curricula

Course material is data. A curriculum is a directory:

```
<curriculum>/
├── welcome.txt     (optional)  shown in the student's banner
├── skills/         (optional)  copied to ~/.claude/skills/
└── everything else             copied to ~/  (lessons/, CLAUDE.md, ...)
```

Curricula are mounted into student containers, not baked into the image, and one
is chosen at spawn time. Editing a lesson costs a re-run of `workshop up`, not an
image rebuild and a 20-minute AMI rebake — so a typo found on the morning of a
workshop is fixable. Students get `~/lessons` (read-only material) and `~/work`
(their files) — a contract stated in each curriculum's `CLAUDE.md`. Point
`LAB_CURRICULA_DIR` outside this repo to keep your content private; the two here
are examples.

### Writing your own

Open this repo in Claude Code and ask it:

> Use the `claude-classroom-new-curriculum` skill to scaffold a curriculum

It asks where the material should live, creates the layout with placeholder
files, and gives you the `workshop up` command for it. It writes structure only —
the lessons are yours to write.

Two things worth knowing before you start, because neither fails loudly:

- `LAB_CURRICULA_DIR` is the **parent** directory holding curriculum
  directories, not one curriculum. Set one level too deep and `up` succeeds
  while every student gets the wrong material.
- `--curriculum` is not checked against what exists. A typo falls back to the
  alphabetically-first curriculum, and says so only in a container log.

## Changing this repo

Running a workshop needs nothing on your machine but the AWS CLI. If you want to
modify the platform itself — the images, the hub, the lifecycle scripts — there
is a local Docker loop and a test suite:
**[`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)**.

Design decisions, sizing tables and the traps found while building it are in
**[`docs/SPEC.md`](docs/SPEC.md)**.

## Acknowledgements

Began as a re-architecture of
[geneontology/go-jupyter](https://github.com/geneontology/go-jupyter) by the Gene
Ontology Consortium, which solves the same problem for agentic biocuration
workshops. The Claude Code first-run state seeding came from them more or less
intact, as did several hard-won operational findings. Everything else here is
new. See [NOTICE](NOTICE).

## License

MIT — see [LICENSE](LICENSE).
