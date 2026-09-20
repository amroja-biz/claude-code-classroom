# Developing this repo

For people changing the platform — the images, the hub, the lifecycle scripts.
If you only want to run a workshop, you do not need any of this; see the
[README](../README.md). Running a class needs the AWS CLI and nothing else,
because the images are built on the EC2 instance rather than on your machine.

Design rationale, sizing tables and the traps found while building this are in
[`SPEC.md`](SPEC.md). Read it before inventing an explanation for odd behaviour.

## The local loop

`docker-compose.yml` is the same file that runs on the instance: a hub container
that spawns sibling student containers through the Docker socket. So a laptop
run exercises the whole student path — code login, spawn, JupyterLab, curriculum
seeding, Claude Code with the key injected — everything except EC2, TLS and DNS.

```bash
make dev-build                            # build both images for this host
make dev-up CURRICULUM=intro-agents       # http://localhost:8000
make dev-logs                             # follow the hub
make dev-down                             # stop, remove student containers
make dev-reset                            # also drop home volumes, forcing a re-seed
make curricula                            # list available curricula
```

Log in with a code from `hub/codes.json`, which is created from the example on
first `dev-up` and is gitignored.

`make dev-up` takes the API key from `$ANTHROPIC_API_KEY`, falling back to a
macOS keychain entry of the same name. This is the one place that local path
exists: on AWS the key must come from Parameter Store, because there the key
would otherwise be read onto your machine and passed over ssh. Locally there is
no instance and no ssh session, so there is nothing to leak.

Curricula are mounted, not baked into the image, so editing a lesson needs only
a respawn — `make dev-reset && make dev-up` — not a rebuild.

## Tests

```bash
./scripts/test-size.sh         # sizing maths; fails if a default cohort size reappears
./scripts/test-curriculum.sh   # seeding, cross-contamination, fallback, marker
./scripts/test-e2e.sh          # Makefile -> compose -> hub -> spawner -> seed
```

`test-e2e.sh` builds on `make dev-up`, so it needs Docker and a built image.
`test-curriculum.sh` mounts `curricula/` the way the spawner does, and guards
against curricula being baked back into the image.

## Builds are always native

Nothing here cross-builds, and nothing should.

- `make dev-build` builds for your host. On Apple Silicon that is arm64.
- `workshop build` builds on the EC2 instance, so the AMI is native to the box —
  amd64 for the `r7i` family, arm64 if you pass a Graviton `--instance-type`.

Claude Code ships as a Bun standalone binary, and Bun's JS engine crashes under
QEMU user-mode emulation with `ASSERTION FAILED: MemoryExhaustion` ->
`qemu: uncaught target signal 6`. An emulated amd64 image on an Apple Silicon Mac
therefore serves JupyterLab correctly and cannot start Claude Code, which looks
like a Claude Code bug and is not one. A `prod-build` target that cross-built
amd64 locally was removed for this reason: its output could not run on the
machine that produced it.

The practical consequence is that a local run tests the arm64 build of the image
while the instance runs the amd64 build. Same Dockerfile, different binaries.

## Iterating against real AWS

Use `--staging` while debugging a deployment:

```bash
./scripts/workshop up --students 2 --curriculum intro-agents --staging
```

Let's Encrypt issues at most **5 duplicate certificates per week** for one
hostname. A debugging loop of `up`/`down` will exhaust that and leave you with no
valid certificate mid-debug. `--staging` points Caddy at Let's Encrypt's staging
endpoint, which is effectively unlimited; browsers warn because nothing trusts
that CA, and the readiness probe skips verification to match.

Instructors never need this — a rehearsal plus a class is two certificates a
week.

## Layout

```
scripts/workshop        lifecycle CLI: discover, init, build, up, down, size, status
scripts/provision.sh    runs on the build instance; installs Docker, Caddy, builds images
scripts/lib-size.sh     instance type and disk derived from --students
infra/durable.yaml      CloudFormation: hosted zone, SG, key pair, IAM role
hub/                    JupyterHub image, config, code authenticator, login template
student-image/          the student sandbox, and the home-seeding script
curricula/              example course material
```
