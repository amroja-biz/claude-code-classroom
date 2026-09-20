# Login-shell entry point for a student's home directory.
#
# This file exists because JupyterLab's terminal starts a LOGIN shell. From
# jupyter_server_terminals/app.py: when the server is launched by a spawner its
# stdout is not a tty, so it appends `-l` to the shell command. A bash login
# shell reads /etc/profile and then the FIRST of ~/.bash_profile, ~/.bash_login,
# ~/.profile -- and never reads ~/.bashrc on its own.
#
# The base image ships its own ~/.profile doing exactly this. We cannot rely on
# it: student homes are per-seat bind mounts (see hub/jupyterhub_config.py and
# scripts/seat-storage.sh), and a bind mount does NOT copy image content the way
# a named volume does. The image's home is shadowed, so whatever it contained is
# simply absent -- including this file.
#
# Without it the chain .profile -> .bashrc -> .lab-bashrc is broken at the first
# link: students get a bare prompt, no welcome banner, and no Claude Code. The
# lab looks fine from every other angle, which is what makes it expensive.

if [ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
