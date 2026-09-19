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

CURRICULUM    ?= intro-agents
# Course material is mounted into student containers, not baked into the image,
# so this is read at run time and a lesson edit needs no rebuild.
CURRICULA_DIR ?= ./curricula
STUDENT_IMAGE ?= lab-student
HUB_IMAGE     ?= lab-hub

.PHONY: help dev-build dev-up dev-down dev-logs dev-reset curricula

help:
	@grep -E '^[a-z-]+:.*?##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/'

dev-build: ## Build both images for the host architecture (local testing)
	docker build -f student-image/Dockerfile -t $(STUDENT_IMAGE):latest .
	docker build -t $(HUB_IMAGE):latest ./hub

dev-up: hub/codes.json ## Start the hub on http://localhost:8000
	@LAB_CURRICULUM="$(CURRICULUM)" \
	 LAB_CURRICULA_HOST_DIR="$$(cd $(CURRICULA_DIR) && pwd)" \
	 ANTHROPIC_API_KEY="$${ANTHROPIC_API_KEY:-$$(command -v security >/dev/null 2>&1 && security find-generic-password -a "$$USER" -s ANTHROPIC_API_KEY -w 2>/dev/null || true)}" \
		docker compose up -d
	@echo "hub: http://localhost:8000   curriculum: $(CURRICULUM)   codes: hub/codes.json"

dev-down: ## Stop the hub and remove student containers
	docker compose down
	-docker ps -aq --filter name=jupyter- | xargs -r docker rm -f

dev-logs: ## Follow hub logs
	docker compose logs -f jupyterhub

dev-reset: dev-down ## Also drop student home volumes (forces re-seed on next login)
	-docker volume ls -q --filter name=lab-student- | xargs -r docker volume rm

hub/codes.json:
	@cp hub/codes.example.json $@
	@echo "created hub/codes.json from the example (gitignored; edit freely)"

curricula: ## List available curricula
	@ls -1 $(CURRICULA_DIR) 2>/dev/null || echo "(no curricula in $(CURRICULA_DIR))"
