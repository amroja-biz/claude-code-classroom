# Local development. The AWS lifecycle lives in scripts/workshop (not yet built).
#
# ARCHITECTURE MATTERS HERE. Claude Code 2.x ships as a Bun standalone binary,
# and Bun's JS engine crashes under QEMU user-mode emulation:
#
#   ASSERTION FAILED: MemoryExhaustion ... qemu: uncaught target signal 6
#
# So an amd64 image cannot be exercised on an Apple Silicon Mac. Build NATIVE for
# local testing and amd64 only for the EC2 AMI.

CURRICULUM    ?= intro-agents
STUDENT_IMAGE ?= lab-student
HUB_IMAGE     ?= lab-hub

.PHONY: help dev-build dev-up dev-down dev-logs dev-reset prod-build curricula

help:
	@grep -E '^[a-z-]+:.*?##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/'

dev-build: ## Build both images for the host architecture (local testing)
	docker build -f student-image/Dockerfile -t $(STUDENT_IMAGE):latest .
	docker build -t $(HUB_IMAGE):latest ./hub

dev-up: hub/codes.json ## Start the hub on http://localhost:8000
	@LAB_CURRICULUM="$(CURRICULUM)" \
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

prod-build: ## Build the student image for the EC2 AMI (linux/amd64)
	docker build --platform linux/amd64 -f student-image/Dockerfile -t $(STUDENT_IMAGE):amd64 .

hub/codes.json:
	@cp hub/codes.example.json $@
	@echo "created hub/codes.json from the example (gitignored; edit freely)"

curricula: ## List curricula baked into the current student image
	@docker run --rm --entrypoint /bin/bash $(STUDENT_IMAGE):latest \
		-c 'ls -1 /opt/lab/curricula' 2>/dev/null || echo "(build the image first: make dev-build)"
