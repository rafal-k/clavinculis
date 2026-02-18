#!/usr/bin/env bash
set -euo pipefail

umask 077

usage() {
  cat <<'EOF'
clavinculis — run Claude Code or OpenCode with hard "project-only visibility" via bubblewrap.

OVERVIEW
  Launches Claude Code or OpenCode inside a dedicated Linux mount namespace (bubblewrap).
  Only the repo you pass in is mounted into the sandbox (at /work/<name> by default),
  plus a minimal runtime filesystem (/usr, /bin, /lib*, /proc, /dev, /tmp).
  Your real $HOME is NOT mounted. Instead, the coding assistant gets a sandbox HOME.

SECURITY PROFILES
  Use --profile to choose a security/compatibility trade-off.

  --profile strict (DEFAULT - maximum host privacy)
      - Project: mounted read-write (use --ro-repo to force RO)
      - /etc: fully synthetic (generated passwd/group/hosts; no host metadata)
      - HOME: persistent sandbox HOME (use --ephemeral-home for tmpfs)
              Claude: ~/.claude-sandboxes/<name>/home
              OpenCode: ~/.opencode-sandboxes/<name>/home
      - Network: enabled (required for API access)
      - SSH/Git: not mounted (use --with-ssh / --with-gitconfig if needed)
      - Extra binds: none unless explicitly requested with --bind-ro/--bind-rw
            (strict prints a warning)

      Best default for LLM clients: minimal host visibility, still usable.

  --profile balanced (compat-friendly)
      - Project: mounted read-write
      - /etc: small host subset (passwd, group, hosts, localtime + DNS + certs)
      - HOME: persistent sandbox HOME
      - Network: enabled
      - SSH/Git: not mounted by default

  --profile compat (compatibility escape hatch)
      - Project: mounted read-write
      - /etc: full host /etc mounted read-only (maximum compatibility)
            WARNING: Exposes host users, groups, hostname, installed services
      - HOME: persistent sandbox HOME
      - Network: enabled

      Use when something breaks. Most compatible but least private.

USAGE
  clavinculis [options] <src-repo-dir> [-- [claude-args...]]
  clavinculis [options] <src-repo-dir> -- <command> [args...]

OPTIONS
  -n, --name NAME
      Sandbox name (default: basename of <src-repo-dir>).
      Also used for per-sandbox state directory naming under --state-base.

  -m, --mount-base PATH
      Repo mount base INSIDE the sandbox (default: /work).
      Repo will appear as: <mount-base>/<name>
      Example: --mount-base /project  => /project/<name>

  -s, --state-base PATH
      Host path where per-sandbox state is stored.
      Default: ~/.claude-sandboxes (for Claude Code)
              ~/.opencode-sandboxes (for OpenCode)
      Persistent sandbox HOME will be: <state-base>/<name>/home

  --profile balanced|strict|compat
      Security profile (see SECURITY PROFILES above). Default: strict

  --shell
      Instead of launching the coding assistant, start an interactive /bin/bash inside the sandbox.

  --tool claude|opencode
      Select which coding assistant to use (default: auto-detect).
      Auto-detection checks for 'claude' first, then 'opencode'.

  --
      End of clavinculis options.

      - If followed by options starting with '-', they are treated as arguments to Claude.
        Example: clavinculis /path/to/repo -- --help

      - Otherwise, the remaining words are treated as a command to run inside the sandbox.
        Example: clavinculis /path/to/repo -- /bin/bash

      IMPORTANT: This runs the command INSIDE THE SANDBOX with the same isolation as Claude.
      It does not bypass or escape sandbox restrictions. Useful for debugging or running
      other tools in the sandboxed environment.

  --ro-repo
      Mount the repo READ-ONLY inside the sandbox.
      In all profiles, repo is mounted read-write by default (use --ro-repo to override).

  --rw-repo
      Mount the repo READ-WRITE (overrides --ro-repo or profile defaults).

  --ephemeral-home
      Do NOT persist sandbox HOME. HOME is placed on tmpfs.
      You will need to login to Claude again each time.

  --persistent-home
      Persist sandbox HOME (overrides --ephemeral-home or profile defaults).

  --bind-ro HOST_PATH:SANDBOX_PATH
      Mount HOST_PATH read-only at SANDBOX_PATH inside sandbox.
      Can be repeated. Example: --bind-ro /host/foo:/sandbox/foo

  --bind-rw HOST_PATH:SANDBOX_PATH
      Mount HOST_PATH read-write at SANDBOX_PATH inside sandbox.
      Can be repeated. Example: --bind-rw /host/data:/work/data

  --with-gitconfig
      Mount ~/.gitconfig read-only inside sandbox (enables git author identity).
      Convenience for: --bind-ro ~/.gitconfig:/home/$USER/.gitconfig

  --with-ssh
      Mount ~/.ssh read-only inside sandbox (enables git push/pull over SSH).
      Convenience for: --bind-ro ~/.ssh:/home/$USER/.ssh
      WARNING: Exposes your SSH keys to Claude Code.

  --full-etc
      Override /etc mode: mount entire host /etc read-only (compat mode).
      This is the default for --profile compat.
      WARNING: Exposes host metadata (users, groups, hostname, services).

  --no-etc
      Override /etc mode: empty /etc (extreme isolation).
      WARNING: Claude Code will NOT be able to connect to Anthropic API.

  --mask-env
      OS-level masking: over-mount .env and .env.* files as empty files,
      except templates: .env.example/.env.sample/.env.template

  --mask-secrets
      OS-level masking: over-mount directories named "secrets" as empty dirs.

  --claude-bin PATH
      Host path to the 'claude' executable (default: command -v claude).

  --claude-share PATH
      Host path to the Claude share dir (default: ~/.local/share/claude).

  --opencode-bin PATH
      Host path to the 'opencode' executable (default: command -v opencode).

  --opencode-share PATH
      Host path to the OpenCode share dir (default: ~/.local/share/opencode).

  -h, --help
      Show help.

EXAMPLES
  # Default strict profile (recommended)
  clavinculis /path/to/repo

  # Balanced profile (more host compatibility)
  clavinculis --profile balanced /path/to/repo

  # Strict profile (maximum host privacy, RW repo, persistent home)
  clavinculis --profile strict /path/to/repo

  # Strict but read-only repo + ephemeral home (maximum immutability)
  clavinculis --profile strict --ro-repo --ephemeral-home /path/to/repo

  # Compat mode (when something breaks)
  clavinculis --profile compat --with-gitconfig --with-ssh /path/to/repo

  # Custom bind mounts
  clavinculis --bind-ro /host/data:/work/external-data /path/to/repo

COMMON RECIPES
  # Enable git with SSH
  clavinculis --with-gitconfig --with-ssh /path/to/repo

  # Mount docker socket (use with caution!)
  clavinculis --bind-rw /var/run/docker.sock:/var/run/docker.sock /path/to/repo

  # Custom bind for shared data
  clavinculis --bind-ro ~/shared-data:/work/data /path/to/repo
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }

# Refuse root/sudo
if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  die "Do not run with sudo/root."
fi

# Check for bubblewrap
BWRAP_PATH="$(command -v bwrap || true)"
[[ -n "$BWRAP_PATH" ]] || die "bubblewrap (bwrap) not found. Install: sudo apt install bubblewrap"
# Default values
PROFILE="strict"
NAME=""
MOUNT_BASE="/work"
STATE_BASE="${HOME}/.claude-sandboxes"

MASK_ENV=0
MASK_SECRETS=0
SHELL_MODE=0
RO_REPO_FLAG=""        # empty = not set, 0 = force RW, 1 = force RO
EPHEMERAL_HOME_FLAG="" # empty = not set, 0 = force persistent, 1 = force ephemeral
ETC_MODE=""            # empty = profile default, "full" = --full-etc, "none" = --no-etc
WITH_GITCONFIG=0
WITH_SSH=0

TOOL=""                # empty = auto-detect, "claude" or "opencode"
CLAUDE_BIN="$(command -v claude || true)"
CLAUDE_SHARE="${HOME}/.local/share/claude"
OPENCODE_BIN="$(command -v opencode || true)"
OPENCODE_SHARE="${HOME}/.local/share/opencode"

# Bind mount arrays
BIND_RO_LIST=()
BIND_RW_LIST=()

SRC=""
CMD_AFTER_DASHDASH=()
SEEN_DASHDASH=0

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--name)          NAME="${2:-}"; shift 2;;
    -m|--mount-base)    MOUNT_BASE="${2:-}"; shift 2;;
    -s|--state-base)    STATE_BASE="${2:-}"; shift 2;;
    --profile)          PROFILE="${2:-}"; shift 2;;
    --mask-env)         MASK_ENV=1; shift;;
    --mask-secrets)     MASK_SECRETS=1; shift;;
    --shell)            SHELL_MODE=1; shift;;
    --tool)             TOOL="${2:-}"; shift 2;;
    --ro-repo)          RO_REPO_FLAG=1; shift;;
    --rw-repo)          RO_REPO_FLAG=0; shift;;
    --ephemeral-home)   EPHEMERAL_HOME_FLAG=1; shift;;
    --persistent-home)  EPHEMERAL_HOME_FLAG=0; shift;;
    --full-etc)         ETC_MODE="full"; shift;;
    --no-etc)           ETC_MODE="none"; shift;;
    --with-gitconfig)   WITH_GITCONFIG=1; shift;;
    --with-ssh)         WITH_SSH=1; shift;;
    --bind-ro)          BIND_RO_LIST+=("${2:-}"); shift 2;;
    --bind-rw)          BIND_RW_LIST+=("${2:-}"); shift 2;;
    --claude-bin)       CLAUDE_BIN="${2:-}"; shift 2;;
    --claude-share)     CLAUDE_SHARE="${2:-}"; shift 2;;
    --opencode-bin)     OPENCODE_BIN="${2:-}"; shift 2;;
    --opencode-share)   OPENCODE_SHARE="${2:-}"; shift 2;;
    -h|--help)          usage; exit 0;;
    --) shift; SEEN_DASHDASH=1; CMD_AFTER_DASHDASH=("$@"); break;;
    -*) die "Unknown option: $1";;
    *)  if [[ -z "$SRC" ]]; then SRC="$1"; else die "Only one <src-repo-dir> argument is allowed (got extra: $1)"; fi; shift;;
  esac
done

if [[ "$SEEN_DASHDASH" -eq 1 && ${#CMD_AFTER_DASHDASH[@]} -eq 0 ]]; then
  die "-- must be followed by Claude arguments (e.g. -- --help) or a command (e.g. -- /bin/bash)"
fi

[[ -n "$SRC" ]] || { usage; exit 2; }

# Validate --state-base early (must be absolute on host)
if [[ "$STATE_BASE" != /* ]]; then
  die "--state-base must be an absolute path (got: $STATE_BASE)"
fi

# Validate profile
case "$PROFILE" in
  balanced|strict|compat) ;;
  *) die "Invalid --profile: $PROFILE (must be: balanced, strict, or compat)" ;;
esac

# Validate and auto-detect tool
if [[ -n "$TOOL" ]]; then
  case "$TOOL" in
    claude|opencode) ;;
    *) die "Invalid --tool: $TOOL (must be: claude or opencode)" ;;
  esac
else
  # Auto-detect: prefer claude, fallback to opencode
  if [[ -n "$CLAUDE_BIN" ]]; then
    TOOL="claude"
  elif [[ -n "$OPENCODE_BIN" ]]; then
    TOOL="opencode"
  else
    # Will be checked later if we actually need a coding assistant
    TOOL=""
  fi
fi

# Apply profile defaults (only if flags not explicitly set)
case "$PROFILE" in
  balanced)
    [[ -n "$RO_REPO_FLAG" ]] || RO_REPO_FLAG=0
    [[ -n "$EPHEMERAL_HOME_FLAG" ]] || EPHEMERAL_HOME_FLAG=0
    [[ -n "$ETC_MODE" ]] || ETC_MODE="balanced"
    ;;
  strict)
    [[ -n "$RO_REPO_FLAG" ]] || RO_REPO_FLAG=0
    [[ -n "$EPHEMERAL_HOME_FLAG" ]] || EPHEMERAL_HOME_FLAG=0
    [[ -n "$ETC_MODE" ]] || ETC_MODE="synthetic"
    ;;

  compat)
    [[ -n "$RO_REPO_FLAG" ]] || RO_REPO_FLAG=0
    [[ -n "$EPHEMERAL_HOME_FLAG" ]] || EPHEMERAL_HOME_FLAG=0
    [[ -n "$ETC_MODE" ]] || ETC_MODE="full"
    ;;
esac

# Finalize flags
RO_REPO="${RO_REPO_FLAG}"
EPHEMERAL_HOME="${EPHEMERAL_HOME_FLAG}"

# Validate ETC_MODE
case "$ETC_MODE" in
  balanced|synthetic|full|none) ;;
  *) die "Internal error: invalid ETC_MODE: $ETC_MODE" ;;
esac

# Canonicalize source repo (host)
[[ -d "$SRC" ]] || die "Source repo dir missing: $SRC"
SRC_REPO="$(cd "$SRC" && pwd -P)"
REPO_BASENAME="$(basename "$SRC_REPO")"
[[ -n "$NAME" ]] || NAME="$REPO_BASENAME"

# Validate NAME is a simple identifier (prevents path injection)
if [[ ! "$NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  die "--name must contain only letters, digits, dots, underscores, or hyphens (got: $NAME)"
fi

# Validate mount base is absolute (inside sandbox)
[[ "$MOUNT_BASE" == /* ]] || die "--mount-base must be an absolute path (e.g. /work)"
SANDBOX_REPO="${MOUNT_BASE%/}/${NAME}"

# Prevent mount collision with /home
if [[ "$SANDBOX_REPO" == /home/* ]]; then
  die "Repo cannot be mounted under /home (conflicts with sandbox HOME at /home/\$USER)"
fi

# Coding assistant paths (host) — only needed if we are actually going to launch one.
# If the user uses:  clavinculis <repo> -- <command>
# then we should NOT require a coding assistant to be installed.
NEED_TOOL=1
if [[ "$SHELL_MODE" -eq 1 ]]; then
  NEED_TOOL=0
elif [[ "$SEEN_DASHDASH" -eq 1 && ${#CMD_AFTER_DASHDASH[@]} -gt 0 && "${CMD_AFTER_DASHDASH[0]}" != -* ]]; then
  NEED_TOOL=0
fi

if [[ "$NEED_TOOL" -eq 1 ]]; then
  [[ -n "$TOOL" ]] || die "No coding assistant found in PATH. Install claude or opencode, or use --tool/--claude-bin/--opencode-bin"

  if [[ "$TOOL" == "claude" ]]; then
    [[ -n "$CLAUDE_BIN" ]] || die "claude not found in PATH (use --claude-bin)"
    TOOL_BIN_REAL="$(readlink -f "$CLAUDE_BIN" || true)"
    [[ -x "$TOOL_BIN_REAL" ]] || die "Missing/invalid claude bin: $TOOL_BIN_REAL"
    [[ -d "$CLAUDE_SHARE" ]] || die "Missing claude share dir: $CLAUDE_SHARE (use --claude-share)"
    TOOL_SHARE="$CLAUDE_SHARE"
    TOOL_NAME="claude"
  elif [[ "$TOOL" == "opencode" ]]; then
    [[ -n "$OPENCODE_BIN" ]] || die "opencode not found in PATH (use --opencode-bin)"
    TOOL_BIN_REAL="$(readlink -f "$OPENCODE_BIN" || true)"
    [[ -x "$TOOL_BIN_REAL" ]] || die "Missing/invalid opencode bin: $TOOL_BIN_REAL"
    [[ -d "$OPENCODE_SHARE" ]] || die "Missing opencode share dir: $OPENCODE_SHARE (use --opencode-share)"
    TOOL_SHARE="$OPENCODE_SHARE"
    TOOL_NAME="opencode"
  fi
else
  TOOL_BIN_REAL=""
  TOOL_SHARE=""
  TOOL_NAME=""
fi

# Per-sandbox state dirs on host (persistent mode / masking placeholders)
# Use tool-specific base directory if not explicitly set
if [[ "$NEED_TOOL" -eq 1 && "$STATE_BASE" == "${HOME}/.claude-sandboxes" ]]; then
  # Default STATE_BASE and we need a tool - use tool-specific directory
  if [[ "$TOOL" == "opencode" ]]; then
    STATE_BASE="${HOME}/.opencode-sandboxes"
  fi
  # claude keeps using ~/.claude-sandboxes (default)
fi
SANDBOX_STATE="${STATE_BASE%/}/${NAME}"
PERSIST_HOME="${SANDBOX_STATE}/home"

# Masking placeholders (host-side) - only create if masking enabled
if [[ "$MASK_ENV" -eq 1 || "$MASK_SECRETS" -eq 1 ]]; then
  MASK_ROOT="${SANDBOX_STATE}/mask"
  EMPTY_FILE="${MASK_ROOT}/empty"
  EMPTY_DIR="${MASK_ROOT}/emptydir"
  mkdir -p "$EMPTY_DIR"
  : > "$EMPTY_FILE"
fi

# Persistent HOME directory (only when not ephemeral)
if [[ "$EPHEMERAL_HOME" -eq 0 ]]; then
  mkdir -p "$PERSIST_HOME"/{.config,.cache,.local/bin,.local/share}
  # Create tool-specific directories
  if [[ "$TOOL" == "claude" ]]; then
    mkdir -p "$PERSIST_HOME/.claude"
  fi
fi

# Synthetic /etc directory (used by synthetic and balanced modes)
SYNTHETIC_ETC="${SANDBOX_STATE}/etc-synthetic"

# DNS gotcha: /etc/resolv.conf may be a symlink into /run
RESOLV_REAL="$(readlink -f /etc/resolv.conf || true)"
RESOLV_SRC="/etc/resolv.conf"
if [[ -n "$RESOLV_REAL" ]]; then
  RESOLV_SRC="$RESOLV_REAL"
fi

# Additional gotcha: if resolv.conf is already a bind mount (e.g., some containers),
# bubblewrap can fail to re-bind it. If it is a *file mount*, copy it to a temp file.
if command -v findmnt >/dev/null 2>&1; then
  mnt_target="$(findmnt -T "$RESOLV_SRC" -no TARGET 2>/dev/null || true)"
  if [[ "$mnt_target" == "$RESOLV_SRC" ]]; then
    RESOLV_COPY="$(mktemp -t resolv.conf.XXXXXX)"
    cp -f "$RESOLV_SRC" "$RESOLV_COPY" || die "Cannot read /etc/resolv.conf. Try --full-etc or --no-etc"
    trap 'rm -f "$RESOLV_COPY"' EXIT
    RESOLV_SRC="$RESOLV_COPY"
  fi
fi


UID_NUM="$(id -u)"
GID_NUM="$(id -g)"
USER_NAME="${USER:-$(id -un)}"

# Detect setuid bubblewrap (--disable-userns does not work there)
BWRAP_IS_SETUID=0
if [[ -u "$BWRAP_PATH" ]]; then
  BWRAP_IS_SETUID=1
fi

# Generate synthetic /etc files (Strategy 1: fully synthetic)
generate_synthetic_etc() {
  mkdir -p "$SYNTHETIC_ETC"

  # /etc/passwd - single user entry
  cat > "$SYNTHETIC_ETC/passwd" <<EOF
root:x:0:0:root:/root:/bin/bash
${USER_NAME}:x:${UID_NUM}:${GID_NUM}:${USER_NAME}:/home/${USER_NAME}:/bin/bash
EOF

  # /etc/group - minimal groups
  cat > "$SYNTHETIC_ETC/group" <<EOF
root:x:0:
${USER_NAME}:x:${GID_NUM}:
EOF

  # /etc/shadow - not really needed but some tools check
  # Use current date for "last changed" field to avoid expiry warnings
  SHADOW_DATE="$(($(date +%s) / 86400))"
  cat > "$SYNTHETIC_ETC/shadow" <<EOF
root:*:${SHADOW_DATE}:0:99999:7:::
${USER_NAME}:*:${SHADOW_DATE}:0:99999:7:::
EOF
  chmod 600 "$SYNTHETIC_ETC/shadow"

  # /etc/gshadow
  cat > "$SYNTHETIC_ETC/gshadow" <<EOF
root:*::
${USER_NAME}:*::
EOF
  chmod 600 "$SYNTHETIC_ETC/gshadow"

  # /etc/nsswitch.conf - files only (no LDAP/NIS)
  cat > "$SYNTHETIC_ETC/nsswitch.conf" <<'EOF'
passwd:     files
group:      files
shadow:     files
gshadow:    files
hosts:      files dns
networks:   files
protocols:  files
services:   files
ethers:     files
rpc:        files
netgroup:   files
EOF

  # /etc/hosts - localhost only
  cat > "$SYNTHETIC_ETC/hosts" <<EOF
127.0.0.1       localhost
::1             localhost ip6-localhost ip6-loopback
EOF

  # /etc/hostname
  echo "sandbox-${NAME}" > "$SYNTHETIC_ETC/hostname"

  # /etc/protocols - prefer host copy for compatibility, fallback to a small baseline
  if [[ -r /etc/protocols ]]; then
    cp /etc/protocols "$SYNTHETIC_ETC/protocols"
  else
    cat > "$SYNTHETIC_ETC/protocols" <<'EOF'
icmp    1       ICMP
igmp    2       IGMP
tcp     6       TCP
udp     17      UDP
ipv6    41      IPv6
icmpv6  58      ICMPv6
EOF
  fi

  # /etc/services - prefer host copy for compatibility, fallback to a broader baseline
  if [[ -r /etc/services ]]; then
    cp /etc/services "$SYNTHETIC_ETC/services"
  else
    cat > "$SYNTHETIC_ETC/services" <<'EOF'
domain  53/udp
domain  53/tcp
ntp     123/udp
http    80/tcp
https   443/tcp
ssh     22/tcp
smtp    25/tcp
submission 587/tcp
imap    143/tcp
imaps   993/tcp
pop3    110/tcp
pop3s   995/tcp
git     9418/tcp
EOF
  fi

  # resolv.conf (copy from host or generate minimal)
  if [[ -f "$RESOLV_SRC" ]]; then
    cp "$RESOLV_SRC" "$SYNTHETIC_ETC/resolv.conf"
  else
    # Fallback: use Cloudflare DNS
    cat > "$SYNTHETIC_ETC/resolv.conf" <<'EOF'
nameserver 1.1.1.1
nameserver 1.0.0.1
EOF
  fi
}

BWRAP_ARGS=(
  --die-with-parent
  --unshare-all --unshare-user --share-net
  --new-session
  --uid "$UID_NUM" --gid "$GID_NUM"

  --clearenv
  --setenv USER "$USER_NAME"
  --setenv LOGNAME "$USER_NAME"
  --setenv HOME "/home/$USER_NAME"
  --setenv XDG_CONFIG_HOME "/home/$USER_NAME/.config"
  --setenv XDG_CACHE_HOME  "/home/$USER_NAME/.cache"
  --setenv PATH "/usr/bin:/bin:/usr/sbin:/sbin:/home/$USER_NAME/.local/bin"
  --setenv LANG "${LANG:-C.UTF-8}"
  --setenv TERM "${TERM:-xterm-256color}"
  --setenv SHELL /bin/bash

  # Minimal runtime FS (practical userland)
  --proc /proc
  --dev /dev
  --perms 1777 --tmpfs /dev/shm
  --tmpfs /tmp

  # Create a HOME path inside sandbox
  --dir /home
  --dir "/home/$USER_NAME"
)

# Minimal runtime FS (practical userland) - continued
# Always bind /usr (universal)
BWRAP_ARGS+=( --ro-bind /usr /usr )

# Handle /bin (required - all distros have this)
if [[ -L /bin ]]; then
  # Modern merged-/usr: /bin is a symlink
  BWRAP_ARGS+=( --symlink usr/bin /bin )
else
  # Old layout: /bin is a real directory
  BWRAP_ARGS+=( --ro-bind /bin /bin )
fi

# Handle /sbin (may not exist on some minimal systems)
if [[ -L /sbin ]]; then
  BWRAP_ARGS+=( --symlink usr/sbin /sbin )
elif [[ -d /sbin ]]; then
  BWRAP_ARGS+=( --ro-bind /sbin /sbin )
fi

# Handle /lib (required on most systems)
if [[ -L /lib ]]; then
  BWRAP_ARGS+=( --symlink usr/lib /lib )
else
  BWRAP_ARGS+=( --ro-bind /lib /lib )
fi

# Handle /lib64 (not universal - missing on 32-bit, some ARM)
if [[ -L /lib64 ]]; then
  # Preserve the host's symlink intent, but avoid creating a dangling link
  LIB64_TGT="$(readlink /lib64)" # e.g. "usr/lib64" or "/usr/lib64" or "lib"
  LIB64_TGT="${LIB64_TGT#/}"     # normalize to relative (bwrap --symlink likes relative targets)

  if [[ -e "/$LIB64_TGT" ]]; then
    BWRAP_ARGS+=( --symlink "$LIB64_TGT" /lib64 )
  else
    echo "WARNING: /lib64 is a symlink to '/$LIB64_TGT' but that target does not exist; skipping /lib64" >&2
  fi

elif [[ -d /lib64 ]]; then
  BWRAP_ARGS+=( --ro-bind /lib64 /lib64 )
fi

# Reduce namespace escape surface when possible.
# NOTE: --disable-userns does not work with the setuid bubblewrap build.
if [[ "$BWRAP_IS_SETUID" -eq 0 ]]; then
  BWRAP_ARGS+=( --disable-userns )
fi

# Preserve common connectivity env vars (helps corporate proxies / custom CAs).
for v in HTTPS_PROXY https_proxy HTTP_PROXY http_proxy NO_PROXY no_proxy \
         SSL_CERT_FILE SSL_CERT_DIR REQUESTS_CA_BUNDLE CURL_CA_BUNDLE NODE_EXTRA_CA_CERTS; do
  if [[ -n "${!v:-}" ]]; then
    BWRAP_ARGS+=( --setenv "$v" "${!v}" )
  fi
done

# /etc handling based on ETC_MODE
case "$ETC_MODE" in
  none)
    # Extreme isolation: empty /etc (Claude Code will not connect to API)
    BWRAP_ARGS+=( --tmpfs /etc )
    ;;

  full)
    # Compatibility mode: full /etc access (WARNING: exposes host metadata)
    BWRAP_ARGS+=( --ro-bind /etc /etc )
    ;;

  synthetic)
    # Strategy 1: Fully synthetic /etc (maximum privacy)
    generate_synthetic_etc
    BWRAP_ARGS+=(
      --tmpfs /etc
      --ro-bind "$SYNTHETIC_ETC/passwd" /etc/passwd
      --ro-bind "$SYNTHETIC_ETC/group" /etc/group
      --ro-bind "$SYNTHETIC_ETC/nsswitch.conf" /etc/nsswitch.conf
      --ro-bind "$SYNTHETIC_ETC/shadow" /etc/shadow
      --ro-bind "$SYNTHETIC_ETC/gshadow" /etc/gshadow
      --ro-bind "$SYNTHETIC_ETC/protocols" /etc/protocols
      --ro-bind "$SYNTHETIC_ETC/services" /etc/services
      --ro-bind "$SYNTHETIC_ETC/hosts" /etc/hosts
      --ro-bind "$SYNTHETIC_ETC/hostname" /etc/hostname
      --ro-bind "$SYNTHETIC_ETC/resolv.conf" /etc/resolv.conf
      --dir /etc/ssl/certs
    )
    # TLS trust + OpenSSL config
    BWRAP_ARGS+=( --ro-bind-try /etc/ssl/certs /etc/ssl/certs )
    BWRAP_ARGS+=( --ro-bind-try /etc/ca-certificates.conf /etc/ca-certificates.conf )
    BWRAP_ARGS+=( --ro-bind-try /etc/ssl/openssl.cnf /etc/ssl/openssl.cnf )
    ;;

  balanced)
    # Strategy 2: Bind small host subset (good balance of privacy/compatibility)
    # If host files don't exist (e.g., in containers), generate synthetic fallbacks
    BWRAP_ARGS+=(
      --tmpfs /etc
      --dir /etc/ssl/certs
    )

    # Check if essential host files exist; if not, generate synthetic
    if [[ ! -f /etc/passwd || ! -f /etc/group || ! -f /etc/nsswitch.conf ]]; then
      # Host is missing essential files (e.g., container env) - use synthetic
      generate_synthetic_etc
      BWRAP_ARGS+=( --ro-bind "$SYNTHETIC_ETC/passwd" /etc/passwd )
      BWRAP_ARGS+=( --ro-bind "$SYNTHETIC_ETC/group" /etc/group )
      BWRAP_ARGS+=( --ro-bind "$SYNTHETIC_ETC/nsswitch.conf" /etc/nsswitch.conf )
      BWRAP_ARGS+=( --ro-bind "$SYNTHETIC_ETC/shadow" /etc/shadow )
      BWRAP_ARGS+=( --ro-bind "$SYNTHETIC_ETC/gshadow" /etc/gshadow )
      BWRAP_ARGS+=( --ro-bind "$SYNTHETIC_ETC/protocols" /etc/protocols )
      BWRAP_ARGS+=( --ro-bind "$SYNTHETIC_ETC/services" /etc/services )
      BWRAP_ARGS+=( --ro-bind "$SYNTHETIC_ETC/hosts" /etc/hosts )
      BWRAP_ARGS+=( --ro-bind "$SYNTHETIC_ETC/hostname" /etc/hostname )
      BWRAP_ARGS+=( --ro-bind "$SYNTHETIC_ETC/resolv.conf" /etc/resolv.conf )
    else
      # Host has standard files - bind them (exposes local account list)
      BWRAP_ARGS+=( --ro-bind /etc/passwd /etc/passwd )
      BWRAP_ARGS+=( --ro-bind /etc/group /etc/group )
      BWRAP_ARGS+=( --ro-bind /etc/nsswitch.conf /etc/nsswitch.conf )
      # Some utilities probe these files even when not doing real auth; use -try for portability.
      BWRAP_ARGS+=( --ro-bind-try /etc/shadow /etc/shadow )
      BWRAP_ARGS+=( --ro-bind-try /etc/gshadow /etc/gshadow )
      BWRAP_ARGS+=( --ro-bind-try /etc/protocols /etc/protocols )
      BWRAP_ARGS+=( --ro-bind-try /etc/services /etc/services )
      BWRAP_ARGS+=( --ro-bind /etc/hosts /etc/hosts )
      BWRAP_ARGS+=( --ro-bind-try /etc/hostname /etc/hostname )
      BWRAP_ARGS+=( --ro-bind-try /etc/localtime /etc/localtime )
      BWRAP_ARGS+=( --ro-bind "$RESOLV_SRC" /etc/resolv.conf )
    fi

    # TLS trust + OpenSSL config
    BWRAP_ARGS+=( --ro-bind-try /etc/ssl/certs /etc/ssl/certs )
    BWRAP_ARGS+=( --ro-bind-try /etc/ca-certificates.conf /etc/ca-certificates.conf )
    BWRAP_ARGS+=( --ro-bind-try /etc/ssl/openssl.cnf /etc/ssl/openssl.cnf )
    ;;
esac

# Sandbox HOME: persistent (bind from host) or ephemeral (tmpfs)
if [[ "$EPHEMERAL_HOME" -eq 1 ]]; then
  BWRAP_ARGS+=( --tmpfs "/home/$USER_NAME" )
else
  BWRAP_ARGS+=( --bind "$PERSIST_HOME" "/home/$USER_NAME" )
fi

# If we're actually going to run a coding assistant, provide its install inside sandbox HOME
if [[ "$NEED_TOOL" -eq 1 ]]; then
  BWRAP_ARGS+=(
    --dir "/home/$USER_NAME/.local"
    --dir "/home/$USER_NAME/.local/bin"
    --dir "/home/$USER_NAME/.local/share"
    --ro-bind "$TOOL_BIN_REAL" "/home/$USER_NAME/.local/bin/$TOOL_NAME"
  )

  # OpenCode needs write access to its share dir for logs; Claude Code doesn't
  if [[ "$TOOL" == "opencode" ]]; then
    BWRAP_ARGS+=( --bind "$TOOL_SHARE" "/home/$USER_NAME/.local/share/opencode" )
  else
    BWRAP_ARGS+=( --ro-bind "$TOOL_SHARE" "/home/$USER_NAME/.local/share/$TOOL_NAME" )
  fi
fi

# Helper: create a directory chain inside sandbox for an absolute path
add_dir_chain() {
  local p="$1"
  [[ "$p" == /* ]] || die "Internal error: add_dir_chain needs absolute path"
  local cur=""
  IFS='/' read -r -a parts <<< "${p#/}"
  for part in "${parts[@]}"; do
    [[ -n "$part" ]] || continue
    cur="${cur}/${part}"
    BWRAP_ARGS+=( --dir "$cur" )
  done
}

# Helper: parse and validate bind mount specification HOST:SANDBOX
parse_bind_spec() {
  local spec="$1"
  local host_path sandbox_path

  if [[ "$spec" != *:* ]]; then
    die "Invalid bind spec (missing ':'): $spec (format: HOST_PATH:SANDBOX_PATH)"
  fi

  host_path="${spec%%:*}"
  sandbox_path="${spec#*:}"

  [[ -n "$host_path" ]] || die "Empty host path in bind spec: $spec"
  [[ -n "$sandbox_path" ]] || die "Empty sandbox path in bind spec: $spec"
  [[ "$sandbox_path" == /* ]] || die "Sandbox path must be absolute in bind spec: $spec"

  # Expand ~
  if [[ "$host_path" == "~/"* ]]; then
    host_path="${HOME}/${host_path#~/}"
  elif [[ "$host_path" == "~" ]]; then
    host_path="${HOME}"
  fi

  # Check host path exists
  [[ -e "$host_path" ]] || die "Host path does not exist in bind spec: $host_path (from: $spec)"

  echo "$host_path:$sandbox_path"
}

# Create mountpoints INSIDE sandbox, then mount repo
add_dir_chain "$SANDBOX_REPO"

if [[ "$RO_REPO" -eq 1 ]]; then
  BWRAP_ARGS+=( --ro-bind "$SRC_REPO" "$SANDBOX_REPO" )
else
  BWRAP_ARGS+=( --bind "$SRC_REPO" "$SANDBOX_REPO" )
fi

# Process convenience flags (convert to bind mounts)
if [[ "$WITH_GITCONFIG" -eq 1 ]]; then
  if [[ -f "${HOME}/.gitconfig" ]]; then
    BIND_RO_LIST+=("${HOME}/.gitconfig:/home/${USER_NAME}/.gitconfig")
  else
    echo "WARNING: --with-gitconfig specified but ~/.gitconfig not found" >&2
  fi
fi

if [[ "$WITH_SSH" -eq 1 ]]; then
  if [[ -d "${HOME}/.ssh" ]]; then
    BIND_RO_LIST+=("${HOME}/.ssh:/home/${USER_NAME}/.ssh")
  else
    echo "WARNING: --with-ssh specified but ~/.ssh not found" >&2
  fi
fi

# Strict profile: extra binds are only allowed when explicitly requested,
# but they materially weaken isolation — warn loudly.
if [[ "$PROFILE" == "strict" ]]; then
  if (( ${#BIND_RO_LIST[@]} + ${#BIND_RW_LIST[@]} > 0 )); then
    echo "WARNING: strict profile: extra bind mounts were requested; this weakens isolation." >&2
    echo "         Review --bind-ro/--bind-rw and convenience flags like --with-ssh/--with-gitconfig." >&2
  fi
fi

# Process custom read-only bind mounts
for bind_spec in "${BIND_RO_LIST[@]}"; do
  parsed=$(parse_bind_spec "$bind_spec")
  host_path="${parsed%%:*}"
  sandbox_path="${parsed#*:}"

  # Create parent directory chain
  add_dir_chain "$(dirname "$sandbox_path")"

  BWRAP_ARGS+=( --ro-bind "$host_path" "$sandbox_path" )
done

# Process custom read-write bind mounts
for bind_spec in "${BIND_RW_LIST[@]}"; do
  parsed=$(parse_bind_spec "$bind_spec")
  host_path="${parsed%%:*}"
  sandbox_path="${parsed#*:}"

  # Create parent directory chain
  add_dir_chain "$(dirname "$sandbox_path")"

  BWRAP_ARGS+=( --bind "$host_path" "$sandbox_path" )
done

# Optional OS-level masking (applies inside sandbox target path)
if [[ "$MASK_ENV" -eq 1 ]]; then

  # Warn on symlink matches (mount operations follow symlinks; masking them could target unexpected paths)
  while IFS= read -r -d '' l; do
    rel="${l#"$SRC_REPO"/}"
    echo "WARNING: --mask-env: skipping symlink (not masking): $rel" >&2
  done < <(
    find "$SRC_REPO" -type l \( -name '.env' -o -name '.env.*' \)       ! -name '.env.example' ! -name '.env.sample' ! -name '.env.template'       -print0 2>/dev/null
  )

  while IFS= read -r -d '' f; do
    rel="${f#"$SRC_REPO"/}"
    tgt="${SANDBOX_REPO%/}/${rel}"
    BWRAP_ARGS+=( --ro-bind-try "$EMPTY_FILE" "$tgt" )
  done < <(
    find "$SRC_REPO" -type f \( -name '.env' -o -name '.env.*' \)       ! -name '.env.example' ! -name '.env.sample' ! -name '.env.template'       -print0 2>/dev/null
  )
fi

if [[ "$MASK_SECRETS" -eq 1 ]]; then
  # Warn on symlink matches (mount operations follow symlinks)
  while IFS= read -r -d '' l; do
    rel="${l#"$SRC_REPO"/}"
    echo "WARNING: --mask-secrets: skipping symlink (not masking): $rel" >&2
  done < <(
    find "$SRC_REPO" -type l -name 'secrets' -print0 2>/dev/null
  )

  while IFS= read -r -d '' d; do
    rel="${d#"$SRC_REPO"/}"
    tgt="${SANDBOX_REPO%/}/${rel}"
    BWRAP_ARGS+=( --ro-bind-try "$EMPTY_DIR" "$tgt" )
  done < <(
    find "$SRC_REPO" -type d -name 'secrets' -print0 2>/dev/null
  )
fi

# DNS workaround only needed in the "full /etc" mode:
# if /etc/resolv.conf is a symlink into /run and /run isn't mounted, resolution can break.
if [[ "$ETC_MODE" == "full" && -n "${RESOLV_REAL}" && "${RESOLV_REAL}" == /run/* ]]; then
  BWRAP_ARGS+=( --dir /run )
  rel="${RESOLV_REAL#/run/}"
  IFS='/' read -r -a parts <<<"$rel"
  parent="/run"
  for ((i=0; i<${#parts[@]}-1; i++)); do
    parent="$parent/${parts[i]}"
    BWRAP_ARGS+=( --dir "$parent" )
  done
  BWRAP_ARGS+=( --ro-bind "$RESOLV_REAL" "$RESOLV_REAL" )
fi

# Start inside the sandboxed repo path
BWRAP_ARGS+=( --chdir "$SANDBOX_REPO" )

if [[ "$SHELL_MODE" -eq 1 ]]; then
  if (( ${#CMD_AFTER_DASHDASH[@]} > 0 )); then
    die "--shell cannot be combined with -- <command/args>"
  fi
  cmd=(/bin/bash -i)
else
  if (( ${#CMD_AFTER_DASHDASH[@]} > 0 )); then
    if [[ "${CMD_AFTER_DASHDASH[0]}" == -* ]]; then
      cmd=(/home/"$USER_NAME"/.local/bin/"$TOOL_NAME" "${CMD_AFTER_DASHDASH[@]}")
    else
      cmd=("${CMD_AFTER_DASHDASH[@]}")
    fi
  else
    cmd=(/home/"$USER_NAME"/.local/bin/"$TOOL_NAME")
  fi
fi

if [[ -n "${RESOLV_COPY:-}" ]]; then
  bwrap "${BWRAP_ARGS[@]}" "${cmd[@]}"; rc=$?
  exit $rc
else
  exec bwrap "${BWRAP_ARGS[@]}" "${cmd[@]}"
fi
