#!/bin/bash
# Seed a student's home directory on first container start.
#
# Runs as a subprocess from /usr/local/bin/before-notebook.d/10-seed-home.sh.
# NOT sourced -- see the comment in that file before changing how it is invoked.
#
# Content lives in /opt/lab/ rather than being baked into /home/jovyan, because
# DockerSpawner mounts a named volume over that path at spawn time and would
# shadow anything baked there.
#
# The class's one curriculum is bind-mounted at /opt/lab/curriculum. Which one
# that is was decided on the trainer's machine (`workshop up --curriculum`), so
# there is nothing to choose here: one image serves every cohort and switching
# material needs no rebuild.
set -euo pipefail

HOME_DIR="${HOME:-/home/jovyan}"
MARKER="${HOME_DIR}/.lab-seeded"
SKEL=/opt/lab/skel
CURRICULUM=/opt/lab/curriculum

log() { echo "[lab-seed] $*" >&2; }

if [ -f "$MARKER" ]; then
    log "already seeded ($(cat "$MARKER" 2>/dev/null || echo unknown)); keeping existing work"
    exit 0
fi

# Loud rather than fatal: a content problem should not stop the container from
# starting, but nobody should mistake a base-files-only home for a lab.
have_curriculum=1
if [ ! -d "$CURRICULUM" ] || [ -z "$(ls -A "$CURRICULUM" 2>/dev/null)" ]; then
    log "ERROR: no curriculum mounted at $CURRICULUM; seeding base files only"
    have_curriculum=0
fi

# --- base dotfiles -----------------------------------------------------------
if [ -d "$SKEL" ]; then
    cp -rn "$SKEL"/. "$HOME_DIR"/ 2>/dev/null || true
fi

# The student's writable workspace. It happens to exist in the current
# jupyter/docker-stacks base image, but relying on that is how you end up with a
# convention nobody declared -- create it explicitly so the contract holds
# whatever the base image does next.
mkdir -p "${HOME_DIR}/work"

# --- curriculum --------------------------------------------------------------
# Layout contract:
#   <curriculum>/skills/       -> ~/.claude/skills/
#   <curriculum>/welcome.txt   -> ~/.lab-welcome   (rendered by .lab-bashrc)
#   <curriculum>/*             -> ~/               (lessons/, CLAUDE.md, data/, ...)
if [ "$have_curriculum" = 1 ]; then
    src="$CURRICULUM"

    # NOTE: curriculum files deliberately CLOBBER the base skel (cp -r, not
    # cp -rn). Seeding runs once, guarded by the marker, so there is no student
    # work to overwrite -- and the alternative is worse: with no-clobber, a base
    # file silently beats the curriculum's own version of the same path.
    if [ -d "${src}/skills" ]; then
        mkdir -p "${HOME_DIR}/.claude/skills"
        cp -r "${src}/skills"/. "${HOME_DIR}/.claude/skills"/ 2>/dev/null || true
    fi

    if [ -f "${src}/welcome.txt" ]; then
        cp "${src}/welcome.txt" "${HOME_DIR}/.lab-welcome" 2>/dev/null || true
    fi

    # Everything else lands directly in the home directory.
    find "$src" -mindepth 1 -maxdepth 1 \
         ! -name skills ! -name welcome.txt \
         -exec cp -r {} "$HOME_DIR"/ \; 2>/dev/null || true

    log "seeded curriculum from $src"
fi

# Hook our banner into the shell without clobbering the base image's .bashrc.
if [ -f "${HOME_DIR}/.lab-bashrc" ] && ! grep -q '.lab-bashrc' "${HOME_DIR}/.bashrc" 2>/dev/null; then
    printf '\n[ -f "$HOME/.lab-bashrc" ] && . "$HOME/.lab-bashrc"\n' >> "${HOME_DIR}/.bashrc"
fi

# --- Claude Code state -------------------------------------------------------
# This seeding came from geneontology/go-jupyter -- see NOTICE.
#
# Every field here suppresses a prompt that would otherwise stop a non-technical
# student cold. customApiKeyResponses is the load-bearing one: with
# ANTHROPIC_API_KEY injected, Claude Code asks "Detected a custom API key ... use
# it?" and anyone who escapes that prompt is stranded at /login with a perfectly
# good key in their environment. Claude keys the approval on the key's last 20
# characters.
python3 - "$HOME_DIR" <<'PY'
import json, os, sys

home = sys.argv[1]
cfg = {
    "hasCompletedOnboarding": True,
    "numStartups": 100,
    "hasSeenTasksHint": True,
    "hasSeenStashHint": True,
    # Undocumented internal counters. Each suppresses a one-off notice that
    # would otherwise interrupt a student's first session. High values rather
    # than booleans because Claude Code counts impressions.
    "opus1mMergeNoticeSeenCount": 99,
    "ideHintShownCount": 99,
    "voiceNoticeSeenCount": 99,
    "tipsHistory": {str(i): True for i in range(50)},
    "projects": {
        home: {
            "hasTrustDialogAccepted": True,
            "allowedTools": [],
            "hasCompletedProjectOnboarding": True,
        }
    },
}

key = os.environ.get("ANTHROPIC_API_KEY", "").strip()
if key:
    cfg["customApiKeyResponses"] = {"approved": [key[-20:]], "rejected": []}


def write_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)


write_json(os.path.join(home, ".claude.json"), cfg)

claude_dir = os.path.join(home, ".claude")
os.makedirs(claude_dir, exist_ok=True)
write_json(
    os.path.join(claude_dir, "settings.json"),
    {
        "skipDangerousModePermissionPrompt": True,
        "spinnerTipsEnabled": False,
        "feedbackSurveyRate": 0,
        # Platform credit, bold white on emerald (#047857). A darker emerald
        # than the classic #50C878, which white text on is hard to read.
        "statusLine": {
            "type": "command",
            "command": "printf '\\033[1;38;2;255;255;255;48;2;4;120;87m Training platform made by https://amroja.com \\033[0m'",
        },
    },
)
PY

# Records when, and whether a curriculum was present; nothing re-seeds while
# this exists, so a student's work survives a container restart.
printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$([ "$have_curriculum" = 1 ] && echo curriculum || echo base-only)" > "$MARKER"
log "done"
