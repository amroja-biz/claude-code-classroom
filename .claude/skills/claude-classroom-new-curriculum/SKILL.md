---
name: claude-classroom-new-curriculum
description: Scaffold a new curriculum for the Claude Code Classroom platform — creates the directory layout, placeholder files and agent-behaviour contract a class needs, then explains how to point the platform at it. Writes structure only; the course author supplies the content. Use when someone wants to write, create, author, scaffold or start a curriculum, course, class or lesson set for this workshop platform, or asks how their own material gets into a class environment.
---

# Scaffold a new curriculum

Your job is to give a course designer a working skeleton and a clear path to
their first class, **without making them read `docs/SPEC.md` or reverse-engineer
`student-image/seed-home.sh`**.

You create structure. They create content. Do not write lessons, exercises or
teaching material unless they explicitly ask you to — a scaffold full of
plausible-looking filler is worse than an empty one, because it gets taught.

## What you are building

A curriculum is a directory. At spawn time its contents are copied into every
student's home directory by `student-image/seed-home.sh`. Three rules govern
that copy, and everything else follows from them:

| In the curriculum | Lands at | Why it matters |
|---|---|---|
| `skills/` | `~/.claude/skills/` | The only directory that is relocated |
| `welcome.txt` | `~/.lab-welcome`, shown in the terminal banner | The only file that is renamed |
| everything else | `~/` verbatim | `lessons/` becomes `~/lessons` **because it is named `lessons`** |

There is no magic beyond those three. `~/lessons` is a convention the author
creates by naming a directory `lessons`, not a feature the platform provides.

The platform does provide `~/work`, created empty for every student. The
read-only-material / writable-workspace split that students rely on is asserted
nowhere in code — it lives in the curriculum's `CLAUDE.md`, which is why that
file is effectively required even though the seeder treats it as ordinary.

## Step 1 — Ask where it goes, and get this right

Two questions, asked together. The second is the one people get wrong.

**Where should the curriculum live?** Offer both, with the trade-off:

- **Inside this repo, under `curricula/`** — simplest, works with no config
  change. Their material is then in this git repository, which is the wrong
  place for anything private or client-owned.
- **Anywhere else** (`~/courses/`, a private git clone, a shared drive) — keeps
  content out of this repo. Costs one line in `workshop.conf`.

**What is the curriculum called?** This string is three things at once: the
directory name, the value of `--curriculum`, and what the instructor types on
the day. Lowercase, hyphens, no spaces — `intro-to-agents`, not `Intro to
Agents`.

> **The trap.** `LAB_CURRICULA_DIR` points at the **parent directory that holds
> curriculum directories**, never at one curriculum. If they are building
> `~/courses/intro-to-agents/`, then `LAB_CURRICULA_DIR=~/courses` and
> `--curriculum intro-to-agents`. Point it one level too deep and `workshop up`
> still succeeds — it ships the directory, finds no match for the name, and each
> student silently gets the alphabetically-first thing it did find. The warning
> lands in a container log nobody is reading during class.
>
> Say this out loud when you report the paths back. Do not assume they inferred
> it from the config line.

If they choose a location outside the repo, note that `workshop up` ships the
**entire** `LAB_CURRICULA_DIR` tree to the instance, not just the selected
curriculum. A directory holding three curricula is fine. Their whole `~/Documents`
is not.

## Step 2 — Create the skeleton

Create exactly this, with the placeholder content below. Substitute their
curriculum name for `<name>` and use their chosen parent directory.

```
<parent>/<name>/
├── CLAUDE.md                     how the agent should behave for this course
├── welcome.txt                   the terminal banner students see first
├── lessons/
│   └── 01-<first-topic>/
│       └── README.md             one directory per lesson, numbered
└── skills/                       optional — delete if unused
    └── .gitkeep
```

Do not create `data/`, `solutions/` or anything else unless they ask. Mention
that any directory they add lands in the student's home under the same name.

### `CLAUDE.md`

This is the file that makes a class feel designed rather than improvised. Write
the structural parts — they are the same for every course on this platform and
are drawn from what the go-jupyter workshop learned the hard way — and leave the
course-specific parts as marked gaps.

```markdown
# <Course title> — workshop context

<!-- TODO: who is the student? What do they already know? Are they programmers?
     The agent adapts its explanations to this sentence more than anything
     else in this file. -->

## Where things live

- `~/lessons/` is the course material. **Read it; do not write into it.**
- `~/work/` is the student's workspace. **Put every file you create here**,
  unless the student explicitly asks for somewhere else. Do not write to the
  home directory itself.

## How to work

- Work through `~/lessons` in order. Don't skip ahead unless asked.
- Explain what you're doing before you do it. Show the command, then run it.
- Prefer small, verifiable steps over long automated runs.
- If the student seems stuck, ask what they expected to happen.

<!-- TODO: course-specific working rules. Which tools should the agent reach
     for? Is there a house style, a validator, a dataset it must not modify? -->

## Session hygiene

- Tell the student to run `/clear` at the end of each exercise. Context that
  carries across unrelated exercises triggers compaction mid-task, after which
  the agent appears to "forget" what it was doing.
- Red error text during iteration is normal — a failed command you are about to
  fix is not a broken environment. Say so when it appears, because students
  reasonably read red as "I broke it".
- If an exercise calls an external API, do not fan out concurrent requests. A
  room of students hitting the same endpoint at once looks like an attack to it.

## Tone

Write as a knowledgeable colleague: plain, direct, professional. Skip
exclamation marks, cheerleading, and filler enthusiasm — the default informal
register reads as wrong in a working context.
```

Leave the TODO comments in. They are the author's checklist, and an unedited
`CLAUDE.md` should be visibly unfinished rather than quietly generic.

### `welcome.txt`

Plain text, no markdown — it is echoed into a terminal banner, so what they
type is what students see. Keep it short enough to survive a small window.

```
   <Course title>

   Lessons:   ~/lessons   (course material — read only)
   Your work: ~/work      (everything you create goes here)

   Start with  ~/lessons/01-<first-topic>/README.md
   Ask Claude: "walk me through lesson 1"
```

### `lessons/01-<first-topic>/README.md`

One numbered directory per lesson, zero-padded so they sort. A stub only:

```markdown
# Lesson 1 — <title>

<!-- TODO: what the student asks the agent to do. Write it as an instruction to
     the student, not to the agent. -->

**Goal:** <!-- TODO: what they should understand afterwards, not what they
should produce. -->

> Your files belong in `~/work`. The `~/lessons` folder is the course
> material — read it, don't write to it.
```

### `skills/` — offer, don't impose

A curriculum can ship Claude Code skills that appear in every student's
`~/.claude/skills/`. Useful for a course-specific helper: an orientation skill,
a validator, a wrapper around a domain API.

Ask whether they want one. If yes, create `skills/<skill-name>/SKILL.md` with
frontmatter, since a skill without `name` and `description` will not load:

```markdown
---
name: <skill-name>
description: <TODO: what it does, and the situations where the agent should reach for it. This sentence is what triggers it — write it as trigger conditions, not as a summary.>
---

<!-- TODO: the instructions the agent follows when this skill fires. -->
```

If no, create `skills/.gitkeep` and tell them they can add one later, or delete
the directory — an empty `skills/` is harmless.

## Step 3 — Names that will collide

Check what you created against this list, and warn the author before they add
directories of their own. Curriculum files **overwrite** base files of the same
name, deliberately, so a collision is silent.

- **`work`** — the student's workspace is created at `~/work`. A curriculum
  directory of that name puts course material where students save their files.
- **`.claude`** — holds the seeded Claude Code state. Use `skills/` instead;
  that is what it is for.
- **`.profile`, `.bashrc`, `.lab-bashrc`, `.lab-welcome`, `.lab-seeded`** —
  platform files. `.profile` is what a login shell reads, and the chain
  `.profile` → `.bashrc` → `.lab-bashrc` is what starts Claude Code. Overwrite
  any link in it and students land on a bare prompt.
- **`lessons`** — not reserved, but by convention it is the read-only material
  and `CLAUDE.md` tells the agent so. If they name it something else, change
  `CLAUDE.md` and `welcome.txt` to match, or the agent will protect a directory
  that does not exist.

## Step 4 — Tell them how to expose it to the platform

This is the step the README leaves implicit, so be concrete. Give them the
commands with their real paths filled in, not a template.

**If they built it under this repo's `curricula/`** — nothing to configure:

```bash
make curricula                       # their new name should be listed
./scripts/workshop up --students <N> --curriculum <name>
```

**If they built it anywhere else** — one line in `workshop.conf`, pointing at
the **parent** directory:

```bash
# in workshop.conf
LAB_CURRICULA_DIR=/Users/<them>/courses
```

then:

```bash
make curricula CURRICULA_DIR=/Users/<them>/courses    # confirm it is found
./scripts/workshop up --students <N> --curriculum <name>
```

Explain what happens next, because it is short and it reassures: `up` tars that
directory, ships it to the instance, and bind-mounts it read-only into every
student container. Editing a lesson costs a re-run of `up` — about three
minutes — not an AMI rebuild. There is no rebuild step for content, ever.

## Step 5 — Verify before it matters

`--curriculum` is not validated at `up` time. A typo produces a working class
teaching the wrong material, so check the name resolves before the day.

Confirm the directory is where you both think it is, and that the name matches
exactly:

```bash
ls -d <parent>/<name>            # must exist
make curricula CURRICULA_DIR=<parent>
```

If Docker is available, offer a local run — it exercises the same seeding code
the instance uses, costs nothing, and is the only way to see the banner and the
home directory as a student will:

```bash
make dev-reset                                       # forces a re-seed
make dev-up CURRICULA_DIR=<parent> CURRICULUM=<name>
# open http://localhost:8000, log in with a code from hub/codes.json
./scripts/test-curriculum.sh     # seeding, cross-contamination, fallback
make dev-down
```

Report what you checked and what you did not. If Docker was unavailable, say
that the layout is correct but unrun rather than implying it is verified.

## Finally

Tell them, in this order:

1. Where the skeleton is, as an absolute path.
2. Which files have TODOs in them, listed — that is their work queue.
3. The exact `workshop up` command for their class, with the name filled in.
4. That `LAB_CURRICULA_DIR` is the parent directory, if they need it — say it
   again here even though you said it in step 1.

Do not summarise the layout contract back at them. They have the files.
