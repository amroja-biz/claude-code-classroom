# Local development. The AWS lifecycle lives in scripts/workshop (not yet built).
#
# These targets build for the HOST architecture, which is what local testing
# needs. Nothing here builds the image that ships: `workshop build` builds it on
# the EC2 instance itself, so the AMI is always native to the box.
#
# On Apple Silicon that means local images are arm64 while the AMI is amd64. The
# gap is not fixable by building amd64 here: Claude Code 2.x is a Bun binary and
# Bun's JS engine dies under QEMU user-mode emulation with
# `ASSERTION FAILED: MemoryExhaustion ... qemu: uncaught target signal 6`. An
# amd64 image on a Mac serves JupyterLab fine and cannot start Claude Code.

# Local seat storage. Small on purpose: these exist to prove containment
# works, not to mirror a real cohort.
SEATS         ?= 2
SEAT_GIB      ?= 1
SEAT_ROOT     ?= /var/lib/lab-seats

CURRICULUM    ?= intro-agents
# Course material is mounted into student containers, not baked into the image,
# so this is read at run time and a lesson edit needs no rebuild.
CURRICULA_DIR ?= ./curricula
STUDENT_IMAGE ?= lab-student
HUB_IMAGE     ?= lab-hub

.PHONY: help dev-build dev-up dev-down dev-logs dev-reset dev-seats dev-seats-down curricula

help:
	@grep -E '^[a-z-]+:.*?##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/'

dev-build: ## Build both images for the host architecture (local testing)
	docker build -f student-image/Dockerfile -t $(STUDENT_IMAGE):latest .
	docker build -t $(HUB_IMAGE):latest ./hub

dev-seats: ## Create per-seat filesystems so disk limits apply locally
	@./scripts/dev-seats.sh setup $(SEATS) $(SEAT_GIB) $(SEAT_ROOT)

dev-seats-down: ## Unmount and delete local per-seat filesystems
	@./scripts/dev-seats.sh teardown $(SEAT_ROOT)

# LAB_SEAT_HOME_DIR is passed only when seat storage is actually mounted.
# Pointing it at an unprepared path would bind an empty root-owned directory
# into every seat: no disk limit AND a home the student cannot write.
dev-up: hub/codes.json ## Start the hub on http://localhost:8000
	@SEAT_DIR=""; \
	 if ./scripts/dev-seats.sh status $(SEAT_ROOT) 2>/dev/null | grep -q ' yes '; then \
	     SEAT_DIR="$(SEAT_ROOT)/home"; \
	 else \
	     echo "note: no seat storage mounted -- run 'make dev-seats' for disk limits"; \
	 fi; \
	 LAB_SEAT_HOME_DIR="$$SEAT_DIR" \
	 LAB_CURRICULUM="$(CURRICULUM)" \
	 LAB_CURRICULA_HOST_DIR="$$(cd $(CURRICULA_DIR) && pwd)" \
	 ANTHROPIC_API_KEY="$${ANTHROPIC_API_KEY:-$$(command -v security >/dev/null 2>&1 && security find-generic-password -a "$$USER" -s ANTHROPIC_API_KEY -w 2>/dev/null || true)}" \
		docker compose up -d
	@echo "hub: http://localhost:8000   curriculum: $(CURRICULUM)   codes: hub/codes.json"

dev-down: ## Stop the hub and remove student containers
	docker compose down
	-docker ps -aq --filter name=jupyter- | xargs -r docker rm -f

dev-logs: ## Follow hub logs
	docker compose logs -f jupyterhub

# Student homes are per-seat filesystems now, not named volumes, so dropping
# volumes alone leaves every home intact and seed-home skips re-seeding on the
# next login -- a reset that resets nothing, and a curriculum switch that
# silently keeps the old material.
dev-reset: dev-down ## Also drop student homes (forces re-seed on next login)
	-docker volume ls -q --filter name=lab-student- | xargs -r docker volume rm
	@if ./scripts/dev-seats.sh status $(SEAT_ROOT) 2>/dev/null | grep -q ' yes '; then \
	    ./scripts/dev-seats.sh teardown $(SEAT_ROOT) >/dev/null 2>&1; \
	    ./scripts/dev-seats.sh setup $(SEATS) $(SEAT_GIB) $(SEAT_ROOT); \
	fi

hub/codes.json:
	@cp hub/codes.example.json $@
	@echo "created hub/codes.json from the example (gitignored; edit freely)"

curricula: ## List available curricula
	@ls -1 $(CURRICULA_DIR) 2>/dev/null || echo "(no curricula in $(CURRICULA_DIR))"
