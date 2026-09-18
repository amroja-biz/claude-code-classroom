# Installed to /usr/local/bin/before-notebook.d/ and SOURCED by docker-stacks'
# start.sh -- so it must not set shell options. `set -u` here leaks into the
# parent and kills start.sh on its own unset JUPYTER_DOCKER_STACKS_QUIET.
# Invoke the real script as a subprocess so its options stay contained.
/usr/local/bin/lab-seed-home || echo "lab-seed-home failed; continuing to start the server" >&2
