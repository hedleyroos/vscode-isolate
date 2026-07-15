# vscode-isolate

Run VS Code — and any coding agent inside it — as a **separate, lower-privilege Linux user**, while still working on your own project files.

`vscode-isolate` is a small Bash wrapper that grants a dedicated `coder` user access to one project directory (via ACLs), lets it use your desktop session, and launches VS Code as that user. It's aimed at running AI coding agents in **auto/YOLO mode**: the agent can freely edit the project and run commands, but it operates as `coder`, not as you.

> [!IMPORTANT]
> This is **reduced-privilege separation, not a hard security boundary.** A determined process running as `coder` on the same machine still has meaningful reach (see [Security model](#security-model)). Treat it as a seatbelt, not a vault. If you need real containment, use a VM or a rootless container — not this.

---

## What it does

Given a project directory, the script:

1. **Shares the files** — grants `coder` recursive `rwX` ACLs on the project, plus *default* ACLs so files created later by either user stay mutually accessible.
2. **Shares the display** — lets `coder` open windows on your current X session (`xhost`).
3. **Prepares the environment** — ensures `coder`'s `XDG_RUNTIME_DIR`, VS Code config dirs, git `safe.directory`, and login `PATH` are set up.
4. **Points Docker at a rootless daemon** — so containers the agent starts run unprivileged (see [Docker, rootless](#2-optional-docker-rootless)).
5. **Launches VS Code** as `coder` on the project.

Optionally (`--pat`) it stores a GitHub Personal Access Token in `coder`'s git credentials, scoped per-repository.

---

## Requirements

- Linux with `sudo` access
- `acl` (`setfacl`) — `sudo apt install acl`
- An X11 session (Wayland works too; the `xhost` step is skipped automatically)
- VS Code (`code` on `PATH`)
- Docker, if the agent needs it — configured **rootless** (see below)

---

## Setup (one-time)

### 1. Create the `coder` user

```bash
sudo useradd -m -s /bin/bash coder
```

You do **not** need to give `coder` a password or sudo rights — in fact, the less it has, the better the isolation.

### 2. (Optional) Docker, rootless

If the agent uses Docker, do **not** add `coder` to the `docker` group — that group is root-equivalent (a container can bind-mount `/` and write to the host as root), which would defeat the whole point. The script refuses to run if `coder` is in the `docker` group.

Instead, set up a rootless daemon owned by `coder`:

```bash
sudo apt install -y uidmap            # + fuse-overlayfs on kernels < 5.11
sudo gpasswd -d coder docker          # if it was ever added
sudo loginctl enable-linger coder     # keep coder's user services alive at boot
sudo -u coder \
     XDG_RUNTIME_DIR=/run/user/$(id -u coder) \
     DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u coder)/bus \
     dockerd-rootless-setuptool.sh install
```

The wrapper then sets `DOCKER_HOST` inside VS Code to `coder`'s rootless socket, so the agent's `docker` commands hit the unprivileged daemon and never touch your root-owned one.

---

## Usage

```bash
# Grant access + launch VS Code as coder on a project
./vscode-isolate.sh /path/to/project

# Also configure a GitHub PAT for the project's origin remote
./vscode-isolate.sh --pat /path/to/project

# Use rootful (host) Docker instead of rootless (opt-in escape hatch)
./vscode-isolate.sh --rooted /path/to/project
```

**`--rooted`**: Skips rootless Docker enforcement and lets `coder` use the host's rootful Docker daemon (`/var/run/docker.sock`). Use this when a project breaks under rootless Docker (e.g., needs privileged containers, certain volume mounts, or host networking). **Trade-off**: containers can escape to host root — isolation is significantly degraded. `coder` must be in the `docker` group (`sudo gpasswd -a coder docker`).

The script blocks until VS Code exits. Run it in the background (`&`) if you want your shell back.

---

## Security model

Running as a second user on the *same machine and same desktop session* closes some doors and leaves others open. Know what you're getting:

**What it protects against**
- Accidental edits to files outside the shared project directory.
- The agent running commands *as you* / with your privileges.
- (With rootless Docker) containers escaping to **host root**.

**What it does *not* protect against** — residual holes, roughly worst-first:
- **X11 has no inter-client isolation.** On an X11 session, `coder` can keylog, screenshot, and inject input into *your* GUI apps. This is the biggest gap. Mitigate with a nested display (Xephyr/Xpra) or a Wayland session.
- **Loopback network.** `coder` can connect to services you run on `localhost` (databases, dev servers, etc.).
- **Any privilege you grant `coder`** (sudo rules, extra groups) is a potential escalation path. Keep it minimal.

For untrusted code you genuinely can't trust on your host, use a disposable VM or a properly sandboxed container instead.

---

## How it works

All behaviour lives in a single script, [`vscode-isolate.sh`](vscode-isolate.sh); the user and paths are configurable via variables at the top (`CODER_USER`, etc.). It leans on standard tools — `setfacl` for file sharing, `xhost` for display access, `sudo -u` to switch users, and rootless Docker for container isolation — so there's nothing to install beyond those.

---

## License

MIT — see [LICENSE](LICENSE).
