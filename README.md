# Clavinculis

**Clavinculis** (_Claudius in vinculis_ — "Claude in chains") is a small CLI wrapper that runs **Claude Code**, **OpenCode**, or **Codex CLI** inside a **bubblewrap** sandbox with **hard, OS-enforced project-only visibility**.

The goal is simple: Your coding assistant can see and modify **one repo** (and its own sandbox HOME), and **nothing else** on your machine.

## Why

Coding agents are powerful, but the local runtime can read files, spawn processes, and access your environment. App-level "scope" promises are helpful, but for security-sensitive work you often want **kernel-enforced isolation**:

- prevent accidental reads of `~/.ssh`, `~/.aws`, other repos, etc.
- reduce host metadata exposure
- make the allowed filesystem view explicit and auditable

Clavinculis does this using Linux namespaces via `bwrap`.

## How it works (high level)

Clavinculis launches your coding assistant (`claude`, `opencode`, or `codex`) in a dedicated mount namespace and mounts only:

- your **repo** (by default at `/work/<name>` in the sandbox)
- a **sandbox HOME**:
  - persisted under `~/.claude-sandboxes/<name>/home` (default), or
  - tmpfs (ephemeral) with `--ephemeral-home`
- a "practical minimal runtime" filesystem:
  - `/usr`, `/bin`, `/lib*`, `/proc`, `/dev`, and tmpfs `/tmp`
  - `/dev/shm` for shared memory (required for headless browsers)
  - Font configuration (`/etc/fonts`) for text rendering
- **synthetic `/etc`** (strict profile, secure by default):
  - Fully generated passwd/group/hosts files (no host metadata exposed)
  - DNS (`resolv.conf`) and TLS certificates (required for Anthropic API)
  - Zero host user/group/hostname disclosure
  - Use `--profile balanced` for more host compatibility, or `--profile compat` / `--full-etc` if something breaks

Anything you don't mount simply does not exist from the sandbox's point of view.

### Headless browser support

The sandbox includes built-in support for **headless browsers** (Firefox, Chromium, Chrome):
- Browsers run in headless mode (no GUI, no display server needed)
- Shared memory (`/dev/shm`) is properly configured for Chromium
- Font rendering works for screenshots, PDFs, and layout calculations
- No additional flags required - just use browsers in headless mode

**Example usage:**
```bash
# Firefox headless
clavinculis /path/to/repo -- firefox --headless --screenshot=/tmp/page.png https://example.com

# Chrome/Chromium headless
clavinculis /path/to/repo -- google-chrome --headless --screenshot=/tmp/page.png https://example.com

# Playwright test suite (if installed in repo)
clavinculis /path/to/repo -- npm test

# Puppeteer script
clavinculis /path/to/repo -- node scripts/scrape-data.js

# Interactive browser automation
clavinculis /path/to/repo  # Then run browser commands from Claude Code
```

Browsers will use the sandbox HOME (`~/.cache`, `~/.local/share`) for profiles and cache, keeping host clean.

**Note:** Display-based GUI browsers are not supported (no X11/Wayland). For web testing and automation, use headless mode.

**Quick test:**
```bash
./test-browser.sh /path/to/repo
```
This script verifies that headless browsers work correctly in the sandbox by taking a screenshot of example.com.

## Non-goals / threat model boundaries

Clavinculis **does not**:

- prevent network exfiltration of data that *is* visible in the sandbox (the agent can still send repo contents to the model service)
- provide MAC-level isolation (SELinux/AppArmor), VM-level isolation, or kernel exploit resistance
- "sanitize" the repo itself — if secrets are in the repo, Claude can read them unless you use masking options

What it **does** provide:

- OS-level enforcement of "your coding assistant can't read files outside the mounts you allow".

## Requirements

- Linux with user namespaces enabled (typical on modern distros)
- `bubblewrap` (`bwrap`) installed
- Claude Code, OpenCode, or Codex CLI installed locally (`claude`, `opencode`, or `codex` on PATH)
  - Alternatively, specify the binary path with `--claude-bin`, `--opencode-bin`, or `--codex-bin`
  - Auto-detection order: Claude Code → OpenCode → Codex CLI (override with `--tool`)

On Debian:

```bash
sudo apt install bubblewrap
```

## Install

1) Put the script somewhere on your PATH:

```bash
install -m 0755 clavinculis.sh ~/.local/bin/clavinculis
hash -r
```

2) Verify:

```bash
clavinculis --help
```

## Usage

Run Claude scoped to a specific repo:

```bash
clavinculis /path/to/repo
```

Inside the sandbox the repo will appear at:

```text
/work/<repo-name>
```

### Selecting the coding assistant

By default, Clavinculis auto-detects which coding assistant is available (prefers Claude Code, then OpenCode, then Codex CLI). You can explicitly select one:

```bash
# Use Claude Code
clavinculis --tool claude /path/to/repo

# Use OpenCode
clavinculis --tool opencode /path/to/repo

# Use Codex CLI
clavinculis --tool codex /path/to/repo

# Specify custom binary paths
clavinculis --opencode-bin /custom/path/to/opencode /path/to/repo
clavinculis --codex-bin /custom/path/to/codex /path/to/repo
```

For Codex, Clavinculis will auto-mount the runtime tree when `--codex-bin` points outside standard mounted locations (`~/.config/nvm`, `/usr`, `/usr/local`, `/opt`).

**Note:** Each tool uses its own isolated state directory:
- Claude Code: `~/.claude-sandboxes/<repo-name>/home`
- OpenCode: `~/.opencode-sandboxes/<repo-name>/home`
- Codex CLI: `~/.codex-sandboxes/<repo-name>/home`

This ensures complete isolation between tools working on the same repository.

### Common options

#### Debug the OUTER sandbox (recommended)

This starts an interactive shell *inside the same outer bwrap sandbox*:

```bash
clavinculis --shell /path/to/repo
```

Inside that shell, you can verify namespaces and mounts:

```bash
readlink /proc/self/ns/mnt
cat /proc/self/mountinfo | grep -E ' /work/| /home/| /tmp ' | head
```

> Note: Coding assistants may run their own *inner* sandbox for command execution. `--shell` avoids ambiguity by letting you inspect the outer sandbox directly.

#### Run arbitrary commands in the sandbox

You can run any command inside the sandbox using `--`:

```bash
clavinculis /path/to/repo -- /bin/bash
clavinculis /path/to/repo -- python script.py
```

**IMPORTANT:** The command runs INSIDE the sandbox with the same isolation as Claude. It does not bypass sandbox restrictions.

#### Security profiles

Clavinculis offers three security profiles via `--profile`:

**`--profile strict` (DEFAULT - maximum host privacy)**
- **Repo:** read-write (use `--ro-repo` to force read-only)
- **`/etc`:** fully synthetic (generated passwd/group/hosts; no host metadata exposed)
- **HOME:** persistent sandbox HOME under `~/.claude-sandboxes/<name>/home`
- **Network:** enabled (required for API access)
- **SSH/Git:** not mounted (use `--with-ssh` / `--with-gitconfig` if needed)
- **Extra binds:** none unless explicitly requested (prints warning)

This is the recommended default: coding assistants work perfectly while host metadata is completely isolated.

**`--profile balanced` (compatibility-friendly)**
- **Repo:** read-write
- **`/etc`:** small host subset (passwd, group, hosts, localtime, DNS, certs)
- **HOME:** persistent sandbox HOME
- **Network:** enabled

Use this if you need slightly more host compatibility.

**`--profile compat` (compatibility escape hatch)**
- **Repo:** read-write
- **`/etc`:** full host /etc mounted read-only
- **HOME:** persistent sandbox HOME
- **Network:** enabled

**WARNING:** Exposes host users, groups, hostname, installed services. Use only when something breaks.

**Examples:**

```bash
# Default strict profile (recommended)
clavinculis /path/to/repo

# Balanced profile for more compatibility
clavinculis --profile balanced /path/to/repo

# Compat profile when something breaks
clavinculis --profile compat /path/to/repo

# Strict with git access
clavinculis --profile strict --with-ssh --with-gitconfig /path/to/repo
```

#### Override /etc mode

You can override the profile's /etc behavior:

**Full host /etc (compatibility mode):**
```bash
clavinculis --full-etc /path/to/repo
```

**WARNING:** `--full-etc` exposes host metadata (users, groups, hostname, installed services).

**Empty /etc (extreme isolation):**
```bash
clavinculis --no-etc /path/to/repo
```

This creates an **empty** `/etc` (tmpfs only):
- No DNS resolution
- No TLS certificates
- Coding assistant **cannot** connect to its API

**Use cases:**
- Testing what breaks without /etc
- Offline code inspection/review
- Extreme isolation scenarios where API access isn't needed
- Research/experimentation

**Note:** With `--no-etc`, you can still use `--shell` mode to inspect files, but the coding assistant itself won't function.

#### Max hygiene: don't persist coding assistant state

Useful if you don’t want credentials/session state written to disk:

```bash
clavinculis --ephemeral-home /path/to/repo
```

Expect to log in each run (by design).

#### Mask common secret locations inside the repo

If secrets live in `.env` files or `secrets/` directories, you can OS-mask them inside the sandbox:

```bash
clavinculis --mask-env --mask-secrets /path/to/repo
```

- `--mask-env` masks `.env` and `.env.*` files, including symlinks (except `.env.example`, `.env.sample`, `.env.template`)
- `--mask-secrets` masks directories named exactly `secrets`, including symlinked directories

#### Review-only mode (optional)

Mount the repo read-only:

```bash
clavinculis --ro-repo /path/to/repo
```

The coding assistant can still write to sandbox HOME (session/config/logs), but cannot modify the repo.

#### Compare multiple repositories

Mount extra repositories **read-only** alongside the primary repo to browse or compare code safely:

```bash
clavinculis myapp --compare ../myapp-fork --compare ~/src/reference-impl
# => /work/myapp            (primary, read-write)
# => /work/myapp-fork       (read-only)
# => /work/reference-impl   (read-only)
```

- `--compare` is repeatable. Each repo is mounted read-only at `<mount-base>/<basename>`.
- The primary repo keeps its normal write access (or honors `--ro-repo`/`--rw-repo`); only the compare repos are forced read-only.
- Basename collisions are auto-suffixed (`dup`, `dup-2`, `dup-3`, …), and the full mount layout is printed at startup.
- Secret masking (`--mask-env` / `--mask-secrets`) covers the compare repos as well as the primary, so their `.env` files and `secrets/` dirs are hidden too.

### Mount location customization

Change where the repo appears inside the sandbox:

```bash
clavinculis --mount-base /project /path/to/repo
# => repo appears at /project/<name>
```

Name the sandbox explicitly (affects mount path and persistent HOME location):

```bash
clavinculis --name client-a /path/to/repo
# => repo appears at /work/client-a
# => Claude Code persistent HOME: ~/.claude-sandboxes/client-a/home
# => OpenCode persistent HOME: ~/.opencode-sandboxes/client-a/home
# => Codex CLI persistent HOME: ~/.codex-sandboxes/client-a/home
```

## Verify isolation (host-side, definitive)

While your coding assistant is running under Clavinculis:

```bash
# For Claude Code
pgrep -u "$USER" -n -a claude
# For OpenCode
pgrep -u "$USER" -n -a opencode
# For Codex CLI
pgrep -u "$USER" -n -a codex

# Take the PID and check mounts
sudo cat /proc/<PID>/mountinfo | grep -E ' /work/| /home/| /tmp '
```

You should see:

- repo bind-mounted at `/work/<name>` (or your chosen mount base)
- sandbox HOME bind-mounted at `/home/<user>` (persistent) or tmpfs (ephemeral)
- `/tmp` as tmpfs

And you should *not* see your real `$HOME` mounted.

## Testing

An automated test suite is included to verify isolation and functionality:

```bash
./test-clavinculis.sh
```

The test suite validates:
- Filesystem isolation (can't access SSH keys, AWS credentials, other projects)
- Default strict profile with synthetic /etc
- All command-line options (--profile, --full-etc, --no-etc, --mask-env, --ro-repo, etc.)
- Multi-repo comparison (--compare: read-only mounts, collision suffixing, masking coverage)
- Network access and DNS resolution
- Mount namespace isolation
- Edge cases (paths with spaces, symlinks)

Run with `--verbose` for detailed output, or `--skip-sudo` to skip tests requiring root access.

Results from a typical run: 36 tests passed, 6 skipped (sudo-only tests and environment-specific checks when using --skip-sudo).

## Notes and caveats

- **Headless browsers:** Firefox, Chromium, and Chrome work in headless mode out of the box. Shared memory (`/dev/shm`), fonts, and machine-id are properly configured. Nested sandboxing is allowed, so browsers can create their own internal sandbox without conflicts. GUI browsers (with display) are not supported as X11/Wayland are not mounted.
- **Git & SSH:** By default, your `~/.ssh` is not mounted, so git-over-SSH from inside the sandbox will not work unless you use `--with-ssh` and `--with-gitconfig`. Many users prefer to keep git operations outside the agent for safety and reviewability.
- **Networking:** The sandbox shares the network namespace so the coding assistant can function. If you want an "offline review shell", use `--shell` and modify the script to unshare net (out of scope for default operation).
- **Claude Code installations:** Native/apt Claude installations do not require `~/.local/share/claude`; their configuration and authentication state are kept in the persistent sandbox HOME. The old share directory is still supported with `--claude-share` when present.
- **Compatibility:** Default strict profile (synthetic `/etc`) works perfectly for Claude Code, OpenCode, and Codex CLI. If something breaks, use `--profile balanced` or `--profile compat` / `--full-etc` for more host compatibility (at the cost of exposing host metadata).
- **Codex CLI:** Codex is distributed as an npm package (`@openai/codex`) with a Node.js launcher and platform-specific native binary package (for example `@openai/codex-linux-x64`). Clavinculis runs Codex from its installed runtime location so module resolution works, and does not use a `--codex-share` directory.

## License

MIT License - see [LICENSE](LICENSE) file for details.

Copyright (c) 2026 Rafal Krysiak (rafal-k)
