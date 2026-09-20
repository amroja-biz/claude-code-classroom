# Principles

What this platform is for, stated plainly enough that a decision can be checked
against it.

This file exists because it was missing. `scripts/lib-size.sh` was written to
pick the cheapest instance a cohort fits into — its own comment said "the only
thing that matters is picking the smallest box the cohort fits in" — and nothing
anywhere said that a class staying up outranks saving six dollars. The code
optimized the variable that had been written down. So the rest of it gets
written down here.

**This file outranks `docs/SPEC.md` and every code comment.** SPEC §2 holds
design rules — how we build. These are goals — what we are building for. When a
design rule produces an outcome that violates a principle, the rule is wrong.

---

## The principles

### 1. Easy to deploy

> This platform makes it easy for the user to deploy AWS resources for a Claude
> Code class.

**In practice.** An instructor with an AWS account and no AWS expertise reaches a
working class. Defaults are correct without tuning. Anything the operator must
decide is asked, once, with a recommendation.

**This rules out.** Tuning knobs offered in place of fixes. If a default produces
a bad result, the default is the bug — do not tell the operator to override it.
Steps that exist only because the implementation is inconvenient.

### 2. No technical troubleshooting during class

> Students and teachers will be able to focus on course material without concerns
> about technical troubleshooting or downtime during class.

**In practice.** This is the principle the platform exists to deliver. Class time
is the moment where failure is most expensive and recovery options are worst: 30
people are watching, the instructor is teaching, and nobody is going to debug a
host OOM in front of an audience.

Failures are graded by blast radius. One student's container dying is bad and
recoverable. The host dying takes the whole class and is not. Design for the
second case even when it costs money, and make the first case impossible to
cause for anyone but yourself.

**This rules out.** Any argument of the form "it probably fits." Silent
oversubscription. Load-bearing assumptions that have never been measured.
Trading a class-wide failure mode for a marginal cost saving.

### 3. Idle cost approaches zero

> This platform is designed so that AWS costs approach $0 when there are no
> active courses being taught.

**In practice.** Between classes the account holds an AMI and a hosted zone.
`down` destroys everything else. Nothing bills by the hour when no one is
teaching.

**This rules out.** Always-on managed services. Anything that survives `down`
without a stated reason. Persistent storage kept "just in case" — see SPEC §2.1,
nothing persists between cohorts.

**This principle governs the account at rest. It does not govern instance
sizing during a class.** See "When principles conflict" below.

### 4. Reasonably secure during class

> This platform will be reasonably secure to intrusion by non-participants during
> class time.

**In practice.** The bar is a non-participant not getting in during the hours a
class runs. TLS, login codes that are not guessable, no open ports beyond what
the class needs, and no credential material reachable by someone who is not in
the class.

"Reasonably" is doing real work in that sentence. This is a disposable teaching
box that exists for a few hours, not a system of record. Students' agents run
with `--dangerously-skip-permissions` and share one API key by design.

**This rules out.** Treating participants as adversaries — they are not the
threat model. Security theater that costs principle 1. Equally: shipping
anything that makes the box trivially reachable by a stranger who has the URL.

### 5. Sizing serves uptime

> This platform will recommend resource sizing appropriate to the needs of any
> given course based on the number of students and course material. Sufficient
> buffer will be accounted for to ensure principle #2 is met.

**In practice.** Sizing is a reliability feature, not a cost feature. Buffer is
the point of the exercise, not an overage to be minimized. The recommendation
accounts for what the course material actually does, which means it has to be
grounded in measurement of that material rather than a figure borrowed from a
different workshop.

Both exhaustible resources are in scope. Memory and disk both end the class when
they run out, and both need a per-student limit and a host-level budget.

**This rules out.** Sizing from an assumed peak. Planning percentages that are
only safe under conditions nobody checks. Choosing the smallest instance that
fits. Capping one resource and leaving the other unbounded.

---

## When principles conflict

**2 beats 3.** Cost discipline applies to the account at rest, not to the box
under a live class. r7i prices linearly per GiB-hour, so one size larger costs
single-digit dollars for a day of teaching — against 30 people's afternoon. There
is no exchange rate at which that trade is worth taking. Principle 5 says this
explicitly: buffer exists to serve principle 2.

**2 beats 1.** A default that is easy and occasionally fails is worse than a
default that is easy and does not. Where they genuinely trade off, ask the
operator rather than guessing quietly.

**1 and 4 are not usually in tension.** Secure defaults should require no
operator work. Where a real security decision belongs to the operator — the
Anthropic API key spend cap is the settled example — document it clearly and do
not enforce it.

---

## Applying this

Before shipping a sizing, defaults, or lifecycle change:

- If it fails during class, what breaks — one seat, or the room?
- Is the number it depends on measured, or assumed? If assumed, say so where the
  operator can see it.
- Does it save money in a way that costs reliability during class? If so, don't.
- Does it hand the operator a knob instead of a fix?

---

## Containment: what stops one student ending the class

Claude Code runs with `--dangerously-skip-permissions`, so no confirmation
stands between a student's prompt and the host. These ceilings are the only
thing that does. Each is asserted against the kernel's own numbers by
`scripts/test-containment.sh`, because a limit nobody tests is a limit that
silently stops being applied.

| Axis | Ceiling | Proven by |
|---|---|---|
| Memory | `mem_limit` 2 GiB, `memswap_limit` equal (no swap escape) | OOM kill stays in-cgroup; hub unaffected |
| CPU | `cpu_limit`, default ¼ of the box as a hard CFS quota | held to 3.04 cores against a 3.00 ceiling while spinning on 12 |
| PIDs | `pids_limit` 512, against a measured peak of 78 | fork refused at 507 of 700; hub still serving |
| Disk | per-seat loop-mounted ext4 (`scripts/seat-storage.sh`) | a seat filled to 100% cost the shared filesystem 0.0 GiB; another seat stayed writable |

All four are ceilings, not reservations. Seats are deliberately oversubscribed
against the box; sizing does not assume everyone pegs every ceiling at once.

## Known gaps against these principles

Recorded rather than quietly carried. These are open, not accepted.

- ~~`lib-size.sh` states the wrong goal and sizes from the cap.~~ **Closed.**
  The file now says why erring large is correct, sizes from `LAB_PEAK_MIB`
  (measured), keeps the cap as a separate protective ceiling, falls back to
  planning at the cap when the operator raises it without a measurement, and
  prints the oversubscription factor instead of leaving it silent.
  `scripts/test-size.sh` asserts the case that used to fail: 30 seats at
  `--mem 5` now get 256 GiB, clearing the 124 GiB honest worst case that the
  old formula's 121 GiB could not.
- **Containment is proven locally, never yet on a real instance.** All four
  ceilings pass on Docker Desktop; the `workshop up` path that creates seat
  storage on EC2 has not been executed once. Closing this is part of the
  install test.
- **Peak usage of the actual course material has never been measured.** One
  seat running one synthetic exercise measured 1.0 GiB peak charge (246 MiB
  unreclaimable) and 252 MiB of disk. A full course, a long-lived session and
  30 concurrent seats are all still unmeasured. Violates 5.
- **`workshop stop`/`start` does not exist**, so pausing between a rehearsal and
  a class means `down`/`up`, which destroys student work. Tension with 3 as the
  only way to stop billing.
