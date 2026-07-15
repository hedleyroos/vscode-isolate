#!/bin/bash
set -euo pipefail

# vscode-isolate.sh — Grant the "coder" user access to a project directory
# and launch VS Code as "coder".
#
# Usage:
#   ./vscode-isolate.sh /path/to/project
#   ./vscode-isolate.sh --pat /path/to/project    (also configure git PAT for the repo)
#
# ISOLATION NOTE: running the agent as a separate user gives *reduced-privilege*
# separation, NOT a hard security boundary. Known residual holes (X11 session):
#   - X11: `xhost +SI:localuser:coder` lets coder keylog / screenshot / inject
#     input into hedley's other GUI apps. Fix later via nested display / Wayland.
#   - localhost network: coder can reach services hedley runs on loopback.
#   - sudo: coder has a few NOPASSWD Linux Mint update/driver helpers (narrow).
#
# SETUP (one-time, to run Docker rootless so it is NOT root-equivalent):
#   sudo apt install -y uidmap                # (+ fuse-overlayfs if kernel <5.11)
#   sudo gpasswd -d coder docker              # remove root-equivalent group access
#   sudo loginctl enable-linger coder         # persistent /run/user/<uid> + user systemd
#   sudo -u coder XDG_RUNTIME_DIR=/run/user/$(id -u coder) \
#        DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u coder)/bus \
#        dockerd-rootless-setuptool.sh install
# This wrapper then points VS Code at coder's rootless daemon (see DOCKER_HOST).

CODER_USER="coder"
CODER_CREDS="/home/$CODER_USER/.git-credentials"
CALLING_USER="${SUDO_USER:-$USER}"
SETUP_PAT=false
ROOTED_DOCKER=false

# Parse options
while [[ $# -gt 0 ]]; do
    case "$1" in
        --pat)
            SETUP_PAT=true
            shift
            ;;
        --rooted)
            ROOTED_DOCKER=true
            shift
            ;;
        -*)
            echo "Unknown option: $1"
            echo "Usage: $0 [--pat] [--rooted] /path/to/project"
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 [--pat] [--rooted] /path/to/project"
    exit 1
fi

PROJECT_DIR="$1"

if ! id -u "$CODER_USER" >/dev/null 2>&1; then
    echo "Error: user '$CODER_USER' does not exist"
    exit 1
fi

# The isolation is pointless if coder can reach the rootful Docker daemon: the
# 'docker' group is root-equivalent (docker run -v /:/host ... => host root).
# --rooted bypasses this guard for projects that break under rootless Docker,
# but containers can then escape to host root.
if [[ "$ROOTED_DOCKER" == true ]]; then
    echo "==> WARNING: --rooted mode — Docker containers run with host-root "
    echo "    privileges. Isolation is significantly degraded."
    if ! id -nG "$CODER_USER" | grep -qw docker; then
        echo "==> WARNING: '$CODER_USER' is NOT in the 'docker' group."
        echo "    Rooted Docker may not work. Run: sudo gpasswd -a $CODER_USER docker"
        echo "    then log out and back in (or newgrp docker) for it to take effect."
    fi
elif id -nG "$CODER_USER" | grep -qw docker; then
    echo "Error: '$CODER_USER' is in the 'docker' group (root-equivalent), which"
    echo "       defeats isolation. Run: sudo gpasswd -d $CODER_USER docker"
    echo "       and set up rootless Docker instead (see SETUP block in this file)."
    echo "       Or use --rooted if you explicitly need rootful Docker."
    exit 1
fi

if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "Error: '$PROJECT_DIR' is not a directory"
    exit 1
fi

# Resolve to absolute path
PROJECT_DIR="$(realpath "$PROJECT_DIR")"

# --- PAT setup ---
if [[ "$SETUP_PAT" == true ]]; then
    # Detect the git remote URL from the project
    REMOTE_URL="$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || true)"

    if [[ -z "$REMOTE_URL" ]]; then
        echo "Error: No git remote 'origin' found in $PROJECT_DIR"
        exit 1
    fi

    # Extract owner/repo from remote URL (handles https and git@ formats)
    if [[ "$REMOTE_URL" != *github.com[:/]* ]]; then
        echo "Error: Could not parse GitHub owner/repo from remote URL: $REMOTE_URL"
        exit 1
    fi
    REPO_PATH="${REMOTE_URL##*github.com[:/]}"
    REPO_PATH="${REPO_PATH%.git}"
    if [[ "$REPO_PATH" != */* ]]; then
        echo "Error: Could not parse GitHub owner/repo from remote URL: $REMOTE_URL"
        exit 1
    fi

    echo "==> Configuring PAT for repo: $REPO_PATH"
    read -rsp "    Enter GitHub PAT: " PAT
    echo

    if [[ -z "$PAT" ]]; then
        echo "Error: PAT cannot be empty"
        exit 1
    fi

    # Ensure credential helper is set for coder; useHttpPath makes git match
    # credentials per repo path instead of host-wide (first-line-wins otherwise)
    sudo -u "$CODER_USER" git config --global credential.helper store
    sudo -u "$CODER_USER" git config --global credential.useHttpPath true

    # Build the credential line
    CRED_LINE="https://coder-pat:${PAT}@github.com/${REPO_PATH}.git"

    # Remove any existing entry for this repo, then append the new one
    if [[ -f "$CODER_CREDS" ]]; then
        sudo sed -i "\|github\.com/${REPO_PATH}|d" "$CODER_CREDS"
    fi
    echo "$CRED_LINE" | sudo tee -a "$CODER_CREDS" > /dev/null
    sudo chmod 600 "$CODER_CREDS"
    sudo chown "$CODER_USER":"$CODER_USER" "$CODER_CREDS"

    echo "    PAT stored for $REPO_PATH."
fi

# --- ACL setup ---
echo "==> Granting $CODER_USER full access to $PROJECT_DIR ..."

# Grant read/write/execute (capital X = execute only on dirs and already-executable files)
# in a single recursive pass:
#  - access ACL for coder
#  - default ACL so new files/dirs created by either user inherit both users' access
sudo setfacl -R \
    -m  u:"$CODER_USER":rwX \
    -dm u:"$CODER_USER":rwX \
    -dm u:"$CALLING_USER":rwX \
    "$PROJECT_DIR"

echo "    Done. ACLs set."

# Allow coder to use the current X display (skip on Wayland-only sessions)
if [[ -n "${DISPLAY:-}" ]] && command -v xhost >/dev/null; then
    echo "==> Granting $CODER_USER display access ..."
    xhost +SI:localuser:"$CODER_USER"
fi

# Ensure coder's runtime and config directories exist
CODER_UID="$(id -u "$CODER_USER")"
CODER_HOME="/home/$CODER_USER"
CODER_RUNTIME="/run/user/$CODER_UID"

echo "==> Ensuring $CODER_USER runtime & config directories exist ..."

# Create XDG_RUNTIME_DIR if missing (normally created by systemd-logind on login)
if [[ ! -d "$CODER_RUNTIME" ]]; then
    sudo mkdir -p "$CODER_RUNTIME"
    sudo chown "$CODER_USER":"$CODER_USER" "$CODER_RUNTIME"
    sudo chmod 700 "$CODER_RUNTIME"
fi

# Create VS Code config/extensions dirs
sudo -u "$CODER_USER" mkdir -p "$CODER_HOME/.config/Code"
sudo -u "$CODER_USER" mkdir -p "$CODER_HOME/.vscode/extensions"

# Ensure coder's rootless Docker daemon is running, and point the sandbox at it
# (its own unprivileged socket) rather than the host's root-owned socket.
# Skip when --rooted: coder will use the host's rootful Docker daemon instead.
if [[ "$ROOTED_DOCKER" == false ]]; then
    CODER_DOCKER_SOCK="$CODER_RUNTIME/docker.sock"
    sudo -u "$CODER_USER" \
        XDG_RUNTIME_DIR="$CODER_RUNTIME" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=$CODER_RUNTIME/bus" \
        systemctl --user start docker 2>/dev/null || true
    if [[ ! -S "$CODER_DOCKER_SOCK" ]]; then
        echo "Warning: rootless Docker socket not found at $CODER_DOCKER_SOCK"
        echo "         Has 'dockerd-rootless-setuptool.sh install' been run? (see SETUP block)"
    fi
fi

# Capture coder's login PATH so tools like Flutter are available
CODER_PATH="$(sudo -u "$CODER_USER" -i bash -lc 'echo "$PATH"')"

# Allow coder to work in repos owned by other users (skip if already listed)
if ! sudo -u "$CODER_USER" git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$PROJECT_DIR"; then
    sudo -u "$CODER_USER" git config --global --add safe.directory "$PROJECT_DIR"
fi

# Launch VS Code as coder
echo "==> Launching VS Code as $CODER_USER on $PROJECT_DIR ..."

# Build the DOCKER_HOST assignment: rootless points at coder's own socket;
# rooted omits it so Docker falls back to /var/run/docker.sock.
DOCKER_HOST_ENV=()
if [[ "$ROOTED_DOCKER" == false ]]; then
    DOCKER_HOST_ENV=("DOCKER_HOST=unix://$CODER_DOCKER_SOCK")
fi

sudo -u "$CODER_USER" \
    PATH="$CODER_PATH" \
    DISPLAY="$DISPLAY" \
    WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-}" \
    XDG_RUNTIME_DIR="$CODER_RUNTIME" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$CODER_RUNTIME/bus" \
    "${DOCKER_HOST_ENV[@]}" \
    code --no-sandbox --password-store="basic" "$PROJECT_DIR"