# Claude Code Classroom

A disposable workshop environment for teaching Claude Code.
Students open a URL, enter a code from their handout, and land in JupyterLab.
Opening a terminal there starts Claude Code after a short welcome banner.
Class exercises are baked into each student's container and a single Anthropic API
key stored in a secure location on your AWS account means that there is no setup.
Students login and are ready to rol.

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

## Requirements

In order to deploy a Claude Code class environment you must have admin access to an AWS account 
and an Anthropic API key. 

## Setup

1. Clone this repo
2. Open Claude Code and type, 

> Use the `claude-classroom-aws-setup` skill in this repo to configure a class

The skill instructs Claude to inspect your AWS account, make suggestions, ask what it cannot infer, 
write the config, deploy the stack, walk you through DNS delegation if needed, 
and verifies each step. 

The Anthropic API key is placed in AWS Parameter Store via a manual CLI command,

```bash
aws ssm put-parameter --name /claude-classroom/anthropic-api-key \
  --type SecureString --value 'sk-ant-...'
```

This ensures that Claude never sees the API key. Though students will be able to see it in their
terminals during class sessions.

## Overview

The setup skill will take care of all AWS configuration but if you're interested in looking under the hood, 
here's some more information. 

The platform adds a few resources to your AWS environment, but these are minimal.
AWS costs are near zero when classes aren't running.

The platform creates a single EC2 instance for each class, with student isolation handled via containers. 
This simple architecture allows the platform to scale to reasonably large class sizes of a few dozen 
students while maintaining a very simple design. 

Jupyter Hub is used so that the students get browser-based access to the Claude Code terminal while being able to 
see lesson files and work output in an intuitive UI. 

Class configuration is written to a file called `workshop.conf`. 

Instructors create classes by using the workshop CLI script that comes with this repo. 


## Preparing a workshop

Classes need exercises so there's a skill in this repo to create the folder structure 
supported by the platform. Once created, add whatever lessons you want. 
Lessons get copied directly onto the instance that's used by the students for the class. 
This means that once the lessons are installed, they're not very easy to change. 
If you find an error in your lesson, you should shut down the instance and start a new one with the curriculum. 

## Running a workshop

```bash
./scripts/workshop build                                      # day before, ~20 min
./scripts/workshop up --students 30 --curriculum ~/courses/my-class # ~5 min
./scripts/workshop down                                       # after class
./scripts/workshop size --students 30                         # what it would cost
./scripts/workshop status
./scripts/workshop codes                                      # reprint URL + codes
```

`up` prints the URL and a code table to paste into a handout. Codes are new every
time, so the last cohort's stop working. If you lose the table, `codes` reads it
back from the running instance. Instance type and disk are derived from
`--students`; there is no default cohort size.

### Keep it current

Pull before every class, then let the two slow commands run:

```bash
git pull
./scripts/workshop init      # updates the CloudFormation stack; ~1 min, no downtime
./scripts/workshop build     # rebuilds the AMI; ~20 min
./scripts/workshop up ...
```

`init` and `build` are safe to run when nothing has changed, so there is no
need to work out whether they are needed. The order matters: `build` bakes
values from the stack into the AMI, so the stack must be updated first. `up`
warns when the AMI or the stack is behind the code, but by then it is too
late to fix it before that class.

`down` terminates the instance and removes the A record. **Student work is not
preserved.** The TLS certificate is: `down` saves it to the durable stack's
bucket and the next `up` restores it, so Let's Encrypt issues one certificate
per hostname and renews it, rather than issuing a new one every workshop. That
matters because Let's Encrypt allows only 5 new certificates per hostname per
week, and refuses — with no override — once you cross it.

### One student cannot end the class

Every seat runs with a ceiling on each resource it could otherwise exhaust for
everyone else. 

| If a student… | What happens |
|---|---|
| runs out of memory | only their container is killed, and it restarts with their work intact |
| pegs every CPU | only their container is throttled; the room stays responsive |
| fork-bombs the machine | their container is refused more processes; the hub keeps serving |
| fills the disk | only their own seat fills; everyone else keeps working |

If your course material is heavier than the default assumption — large models,
big datasets, long-running builds — raise the per-seat allowance with
`--mem <GiB>` and `size` will pick a correspondingly larger box.

## Rehearse the night before

Run `./scripts/workshop up` the day *before* the class to ensure it works.

Then do a full dress rehearsal:

```bash
./scripts/workshop up --students 30 --curriculum ./curricula/intro-agents
# open the URL, enter the first code, confirm you land in JupyterLab,
# then open a Terminal: the banner shows and Claude Code starts on its
# own. Having to type `claude` means the AMI is stale: `workshop build`
./scripts/workshop down
```

Use the real cohort size, so the instance you test is the instance you will
teach on. In the morning, `up` again: same AMI, same images, same curricula, and
nothing is fetched from the internet at `up` time — so it is a carbon copy of
what you just verified.

### If the URL stops working in your browser (instructors)

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

## Networking

Everything the platform does on the network, in one place.

**DNS.** The durable stack owns a Route53 hosted zone for the class domain,
either one you already have in the account or one it creates, which you then
delegate from your parent domain once with an NS record. Nothing else is ever
touched in that zone. `up` writes a single A record for the class hostname
pointing at the new instance's public IP, with a 60-second TTL. `down` deletes
it. No Elastic IP is held between classes, so the IP changes every time and
the hostname does not resolve while no class is running.

**Ports.** The security group opens 80 and 443 to the world by default
(students need them) and 22 for the instructor. Both ranges are stack
parameters, `WebCidr` and `SshCidr`, and 22 is worth tightening to your own
address. Nothing else is reachable from outside.

**Reverse proxy.** Caddy runs on the instance and forwards 80 and 443 to
JupyterHub on localhost. Plain http redirects to https. Its whole
configuration is the hostname and that one forward.

**Certificates.** Caddy requests a certificate from Let's Encrypt on first
start using the HTTP-01 challenge, which is why port 80 must be open to
everyone, not just students. Because Let's Encrypt allows only five new
certificates per hostname per week with no override, the certificate, key and
account are copied to a private, versioned S3 bucket in the durable stack:
restored before Caddy starts, saved every five minutes, and saved again at
`up` and `down`. Every class after the first reuses the same certificate and
Let's Encrypt renews it on its own schedule, which does not count against the
limit. `up --staging` uses Let's Encrypt's staging service instead, which has
no meaningful limit but issues certificates browsers do not trust; use it only
to test the platform itself, never for a class.

**Third parties.** The platform itself depends on three outside services:
Let's Encrypt for certificates, the Anthropic API for Claude Code, and AWS (S3
for the certificate, Parameter Store for the API key). Everything else it
needs is baked into the AMI at `build` time, so `up` fetches nothing from the
internet. Outbound traffic is not filtered, so students' Claude Code sessions
can reach whatever the lessons ask them to.

**Inside the box.** Student containers sit on a private Docker network with no
published ports. JupyterHub reaches each one by container name, and the only
way in from outside is through Caddy and the hub's login page.

## Curricula

Course material is data. A curriculum is a directory:

```
<curriculum>/
├── welcome.txt     (optional)  shown in the student's banner
├── skills/         (optional)  copied to ~/.claude/skills/
└── everything else             copied to ~/  (lessons/, CLAUDE.md, ...)
```

Curricula are mounted into student containers. Editing a lesson requires a re-run of `workshop up`, 
so a typo found on the morning of a workshop is fixable. 
Students see `~/lessons` (read-only material) and `~/work`
(their files) with their respective purposes specified in each curriculum's `CLAUDE.md`.

`--curriculum` takes the path to a directory  anywhere on your machine. 
`up` checks the layout before launching a server so errors are found early.

### Writing your own curriculum

Open this repo in Claude Code and ask it:

> Use the `claude-classroom-new-curriculum` skill to scaffold a curriculum

It asks where the material should live, creates the layout with placeholder
files, and gives you the `workshop up` command for it. It writes structure only —
the lessons are yours to write.

The directory's name is what students see it called on the instance, so keep
it lowercase with hyphens: `intro-to-agents`, not `Intro to Agents`.

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
