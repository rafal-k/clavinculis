#!/usr/bin/env bash
# test-clavinculis.sh - Automated test suite for Clavinculis
#
# Tests the clavinculis wrapper script for correctness and security isolation.
# Does NOT require Claude Code to be installed (uses --shell mode and mock binaries).
#
# Usage: ./test-clavinculis.sh [--verbose] [--no-color] [--skip-sudo]

set -euo pipefail

# Configuration
SCRIPT="${SCRIPT:-./clavinculis.sh}"
TEST_DIR=""
VERBOSE=0
USE_COLOR=1
SKIP_SUDO=0

# Counters
PASSED=0
FAILED=0
SKIPPED=0

# Colors
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
fi

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose|-v) VERBOSE=1; shift;;
        --no-color) USE_COLOR=0; shift;;
        --skip-sudo) SKIP_SUDO=1; shift;;
        -h|--help)
            cat <<EOF
Usage: $0 [options]

Options:
  --verbose, -v    Show detailed output for each test
  --no-color       Disable colored output
  --skip-sudo      Skip tests that require sudo access
  -h, --help       Show this help

Tests the clavinculis.sh wrapper for security isolation and correctness.
Does not require Claude Code installation (uses --shell mode).
EOF
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1;;
    esac
done

[[ $USE_COLOR -eq 0 ]] && RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''

# Logging functions
log_verbose() {
    [[ $VERBOSE -eq 1 ]] && echo "  $*" >&2
    return 0  # Always return success for set -e compatibility
}

pass() {
    echo -e "${GREEN}✓${RESET} $1"
    ((PASSED++)) || true  # || true for set -e compatibility when PASSED=0
}

fail() {
    echo -e "${RED}✗${RESET} $1"
    ((FAILED++)) || true  # || true for set -e compatibility when FAILED=0
}

skip() {
    echo -e "${YELLOW}⊘${RESET} $1 (skipped)"
    ((SKIPPED++)) || true  # || true for set -e compatibility when SKIPPED=0
}

section() {
    echo ""
    echo -e "${BOLD}${BLUE}▸ $1${RESET}"
}

# Setup and cleanup
setup() {
    TEST_DIR="$(mktemp -d /tmp/clavinculis-test.XXXXXX)"
    log_verbose "Test directory: $TEST_DIR"

    # Create test repo
    mkdir -p "$TEST_DIR/repo"
    echo "# Test Project" > "$TEST_DIR/repo/README.md"
    echo "test content" > "$TEST_DIR/repo/file.txt"
    echo "SECRET_KEY=hunter2" > "$TEST_DIR/repo/.env"
    echo "EXAMPLE_KEY=safe" > "$TEST_DIR/repo/.env.example"

    # Create nested structure for secrets masking
    mkdir -p "$TEST_DIR/repo/secrets"
    mkdir -p "$TEST_DIR/repo/not-secrets"
    echo "password123" > "$TEST_DIR/repo/secrets/api-key"
    echo "public-config" > "$TEST_DIR/repo/not-secrets/config.txt"

    # Create mock Claude binary
    cat > "$TEST_DIR/mock-claude" <<'EOF'
#!/bin/bash
echo "MOCK_CLAUDE_STARTED"
echo "PWD=$PWD"
echo "HOME=$HOME"
echo "USER=$USER"
ls -la 2>/dev/null | head -3
exit 0
EOF
    chmod +x "$TEST_DIR/mock-claude"
}

cleanup() {
    # Kill any background processes from this script
    local bg_jobs=$(jobs -p)
    if [[ -n "$bg_jobs" ]]; then
        echo "$bg_jobs" | xargs -r kill 2>/dev/null || true
        log_verbose "Cleaned up background processes"
    fi

    if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
        log_verbose "Cleaned up test directory"
    fi
}

# Validation
validate_environment() {
    if [[ ! -f "$SCRIPT" ]]; then
        echo -e "${RED}ERROR:${RESET} Script not found: $SCRIPT" >&2
        echo "Set SCRIPT=/path/to/clavinculis.sh or run from project root" >&2
        exit 1
    fi

    if ! command -v bwrap >/dev/null 2>&1; then
        echo -e "${RED}ERROR:${RESET} bubblewrap (bwrap) not found" >&2
        echo "Install: sudo apt install bubblewrap" >&2
        exit 1
    fi

    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        echo -e "${RED}ERROR:${RESET} Do not run tests as root" >&2
        exit 1
    fi
}

# Helper: run command in shell mode, return output
run_in_shell() {
    local repo="$1"
    local cmd="$2"
    shift 2
    local args=("$@")

    log_verbose "Running in shell: $cmd"
    $SCRIPT --shell "${args[@]}" "$repo" <<EOF 2>&1
$cmd
exit 0
EOF
}

# Helper: check if string appears in output
contains() {
    grep -qF "$1" <<< "$2"
}

#
# TEST SUITES
#

test_argument_parsing() {
    section "Argument Parsing & Error Handling"

    # Help text
    if $SCRIPT --help 2>&1 | grep -q "clavinculis"; then
        pass "Help text displays correctly"
    else
        fail "Help text missing or malformed"
    fi

    # Missing repo path
    if ! $SCRIPT >/dev/null 2>&1; then
        pass "Error on missing repo argument"
    else
        fail "Should error when no repo provided"
    fi

    # Non-existent repo
    output=$($SCRIPT /nonexistent/repo/path/xyz 2>&1 || true)
    if grep -q "Source repo dir missing" <<< "$output"; then
        pass "Error on non-existent repo path"
    else
        fail "Should error on non-existent repo"
    fi

    # Invalid option
    output=$($SCRIPT --invalid-flag-xyz "$TEST_DIR/repo" 2>&1 || true)
    if grep -q "Unknown option" <<< "$output"; then
        pass "Error on unknown option"
    else
        fail "Should error on unknown option"
    fi

    # Root check (can't actually test running as root, but verify code exists)
    if grep -q 'EUID.*-eq 0' "$SCRIPT" && grep -q 'Do not run with sudo' "$SCRIPT"; then
        pass "Root/sudo check present in code"
    else
        fail "Root/sudo check missing or malformed"
    fi
}

test_basic_shell_mode() {
    section "Basic Shell Mode Functionality"

    # Shell mode starts
    local output
    output=$(run_in_shell "$TEST_DIR/repo" "echo SHELL_WORKS")
    if contains "SHELL_WORKS" "$output"; then
        pass "Shell mode starts and executes commands"
    else
        fail "Shell mode does not work"
    fi

    # Working directory is correct
    output=$(run_in_shell "$TEST_DIR/repo" "pwd")
    if contains "/work/repo" "$output"; then
        pass "Working directory is /work/repo"
    else
        fail "Working directory incorrect: $output"
    fi

    # Repo files are visible
    output=$(run_in_shell "$TEST_DIR/repo" "cat README.md")
    if contains "Test Project" "$output"; then
        pass "Repo files are readable"
    else
        fail "Repo files not accessible"
    fi

    # Can write to repo (default mode)
    output=$(run_in_shell "$TEST_DIR/repo" "echo test > /tmp/write-test && echo SUCCESS || echo FAILED")
    if contains "SUCCESS" "$output"; then
        pass "Can write to /tmp in sandbox"
    else
        fail "Cannot write to /tmp"
    fi
}

test_isolation_filesystem() {
    section "Filesystem Isolation (Critical Security Tests)"

    # Real HOME should not be visible
    local real_home="$HOME"
    local test_file="$HOME/.bashrc"
    if [[ -f "$test_file" ]]; then
        output=$(run_in_shell "$TEST_DIR/repo" "test -f ~/.bashrc && echo VISIBLE || echo HIDDEN")
        if contains "HIDDEN" "$output"; then
            pass "Real HOME is not visible (~/.bashrc not accessible)"
        else
            fail "SECURITY ISSUE: Real HOME is visible in sandbox"
        fi
    else
        skip "Cannot test real HOME isolation (~/.bashrc doesn't exist)"
    fi

    # Real HOME path should not be mounted as a source
    # Check that real HOME is not bind-mounted from its real location
    output=$(run_in_shell "$TEST_DIR/repo" "cat /proc/self/mountinfo | grep -E ' $real_home ' || echo GOOD")
    if contains "GOOD" "$output"; then
        pass "Real HOME path not bind-mounted"
    else
        fail "SECURITY ISSUE: Real HOME path appears as bind mount source"
    fi

    # Common sensitive directories should not exist
    output=$(run_in_shell "$TEST_DIR/repo" "test -d ~/.ssh && echo VISIBLE || echo HIDDEN")
    if contains "HIDDEN" "$output"; then
        pass "~/.ssh is not visible"
    else
        fail "SECURITY ISSUE: ~/.ssh is visible"
    fi

    output=$(run_in_shell "$TEST_DIR/repo" "test -d ~/.aws && echo VISIBLE || echo HIDDEN")
    if contains "HIDDEN" "$output"; then
        pass "~/.aws is not visible"
    else
        fail "SECURITY ISSUE: ~/.aws is visible"
    fi

    # /srv/Projects should not be visible (if it exists on host)
    if [[ -d /srv/Projects ]]; then
        output=$(run_in_shell "$TEST_DIR/repo" "test -d /srv/Projects && echo VISIBLE || echo HIDDEN")
        if contains "HIDDEN" "$output"; then
            pass "/srv/Projects is not visible"
        else
            fail "SECURITY ISSUE: /srv/Projects is visible"
        fi
    else
        skip "/srv/Projects doesn't exist on host"
    fi

    # Sandbox HOME should have different contents than real HOME
    # (The path may be the same, but it should be bind-mounted from sandbox state)
    # Test by checking if real HOME files are accessible
    if [[ -f "$real_home/.bashrc" ]]; then
        output=$(run_in_shell "$TEST_DIR/repo" "test -f ~/.bashrc && echo SAME || echo DIFFERENT")
        if contains "DIFFERENT" "$output"; then
            pass "Sandbox HOME contents isolated from real HOME"
        else
            fail "SECURITY ISSUE: Sandbox HOME has same contents as real HOME"
        fi
    else
        # If .bashrc doesn't exist, check if sandbox HOME is empty/fresh
        output=$(run_in_shell "$TEST_DIR/repo" "ls -A ~ 2>/dev/null | wc -l")
        count=$(echo "$output" | grep -v "bash:" | grep -oE '^[0-9]+$' | head -1)
        if [[ -n "$count" && "$count" -lt 5 ]]; then
            pass "Sandbox HOME is isolated (minimal contents)"
        else
            skip "Cannot verify HOME isolation (no .bashrc in real HOME)"
        fi
    fi
}

test_networking() {
    section "Network Access"

    # DNS resolution file should exist
    output=$(run_in_shell "$TEST_DIR/repo" "test -f /etc/resolv.conf && echo EXISTS || echo MISSING")
    if contains "EXISTS" "$output"; then
        pass "/etc/resolv.conf exists"
    else
        fail "/etc/resolv.conf missing"
    fi

    # Network connectivity: ping the configured nameserver (more reliable than hardcoded IP)
    output=$(run_in_shell "$TEST_DIR/repo" "ns=\$(awk '/^nameserver/{print \$2; exit}' /etc/resolv.conf); ping -c1 -W2 \"\$ns\" >/dev/null 2>&1 && echo SUCCESS || echo FAILED")
    if contains "SUCCESS" "$output"; then
        pass "Network access works (ping configured nameserver)"
    else
        # Fallback: just verify DNS resolution works (implies network works)
        output=$(run_in_shell "$TEST_DIR/repo" "getent hosts anthropic.com >/dev/null 2>&1 && echo SUCCESS || echo FAILED")
        if contains "SUCCESS" "$output"; then
            pass "Network access works (DNS resolution)"
        else
            fail "Network access broken"
        fi
    fi
}

test_options_mount_base() {
    section "Mount Base Option"

    # Custom mount base
    output=$(run_in_shell "$TEST_DIR/repo" "pwd" --mount-base /project)
    if contains "/project/repo" "$output"; then
        pass "--mount-base changes mount location"
    else
        fail "--mount-base does not work correctly"
    fi
}

test_options_custom_name() {
    section "Custom Name Option"

    output=$(run_in_shell "$TEST_DIR/repo" "pwd" --name custom-sandbox)
    if contains "/work/custom-sandbox" "$output"; then
        pass "--name changes sandbox name"
    else
        fail "--name does not work correctly"
    fi
}

test_options_ro_repo() {
    section "Read-Only Repo Option"

    # Should not be able to write to repo
    output=$(run_in_shell "$TEST_DIR/repo" "touch /work/repo/new-file 2>&1 && echo WRITTEN || echo BLOCKED" --ro-repo)
    if contains "BLOCKED" "$output"; then
        pass "--ro-repo prevents writes to repo"
    else
        fail "--ro-repo does not prevent writes"
    fi

    # Should still be able to read
    output=$(run_in_shell "$TEST_DIR/repo" "cat README.md" --ro-repo)
    if contains "Test Project" "$output"; then
        pass "--ro-repo still allows reads"
    else
        fail "--ro-repo breaks read access"
    fi
}

test_options_minimal_etc() {
    section "Synthetic /etc (Default Strict Profile)"

    # Should have synthetic /etc by default (strict profile)
    output=$(run_in_shell "$TEST_DIR/repo" "ls /etc 2>/dev/null | wc -l")
    local count=$(echo "$output" | grep -v "bash:" | grep -oE '^[0-9]+$' | head -1)
    if [[ -n "$count" && "$count" -ge 10 && "$count" -lt 15 ]]; then
        pass "Default strict mode has synthetic /etc (found $count entries)"
    else
        fail "Default strict mode /etc count unexpected (found $count entries, expected 10-14)"
    fi

    # Should have DNS
    output=$(run_in_shell "$TEST_DIR/repo" "test -f /etc/resolv.conf && echo YES || echo NO")
    if contains "YES" "$output"; then
        pass "Default strict mode includes resolv.conf (DNS)"
    else
        fail "Default strict mode missing resolv.conf"
    fi

    # SHOULD have synthetic passwd (strict profile generates it)
    output=$(run_in_shell "$TEST_DIR/repo" "test -f /etc/passwd && echo YES || echo NO")
    if contains "YES" "$output"; then
        pass "Default strict mode includes synthetic /etc/passwd"
    else
        fail "Default strict mode missing synthetic /etc/passwd"
    fi

    # SHOULD have synthetic hosts (strict profile generates it)
    output=$(run_in_shell "$TEST_DIR/repo" "test -f /etc/hosts && echo YES || echo NO")
    if contains "YES" "$output"; then
        pass "Default strict mode includes synthetic /etc/hosts"
    else
        fail "Default strict mode missing synthetic /etc/hosts"
    fi
}

test_options_full_etc() {
    section "Full /etc Option"

    # Count host /etc entries for comparison
    local host_etc_count=$(ls /etc 2>/dev/null | wc -l)

    # Should have same count as host /etc (full bind mount)
    output=$(run_in_shell "$TEST_DIR/repo" "ls /etc 2>/dev/null | wc -l" --full-etc)
    local count=$(echo "$output" | grep -v "bash:" | grep -oE '^[0-9]+$' | head -1)
    if [[ -n "$count" && "$count" -eq "$host_etc_count" ]]; then
        pass "--full-etc exposes full host /etc (found $count entries, same as host)"
    elif [[ -n "$count" && "$count" -gt 10 ]]; then
        # Fallback: if host has many entries, sandbox should too
        pass "--full-etc exposes many /etc entries (found $count entries)"
    else
        fail "--full-etc does not expose host /etc (found $count entries, host has $host_etc_count)"
    fi

    # Check for host-specific /etc file (passwd on full systems, or any host file)
    if [[ -f /etc/passwd ]]; then
        output=$(run_in_shell "$TEST_DIR/repo" "test -f /etc/passwd && echo YES || echo NO" --full-etc)
        if contains "YES" "$output"; then
            pass "--full-etc includes /etc/passwd"
        else
            fail "--full-etc missing /etc/passwd"
        fi
    else
        # In minimal containers, check for ca-certificates.conf or resolv.conf
        skip "--full-etc passwd check (host has minimal /etc)"
    fi
}

test_options_no_etc() {
    section "No /etc Option (Extreme Isolation)"

    # Should have empty /etc with --no-etc
    output=$(run_in_shell "$TEST_DIR/repo" "ls /etc 2>/dev/null | wc -l" --no-etc)
    local count=$(echo "$output" | grep -v "bash:" | grep -oE '^[0-9]+$' | head -1)
    if [[ -n "$count" && "$count" -eq 0 ]]; then
        pass "--no-etc creates empty /etc (found $count entries)"
    else
        fail "--no-etc does not create empty /etc (found $count entries)"
    fi

    # Should NOT have resolv.conf with --no-etc
    output=$(run_in_shell "$TEST_DIR/repo" "test -f /etc/resolv.conf && echo YES || echo NO" --no-etc)
    if contains "NO" "$output"; then
        pass "--no-etc does NOT include /etc/resolv.conf"
    else
        fail "--no-etc incorrectly includes /etc/resolv.conf"
    fi

    # File operations should still work
    output=$(run_in_shell "$TEST_DIR/repo" "echo test > /tmp/file && cat /tmp/file" --no-etc)
    if contains "test" "$output"; then
        pass "--no-etc still allows file operations"
    else
        fail "--no-etc breaks file operations"
    fi
}

test_options_mask_env() {
    section "Mask .env Files Option"

    # .env should be masked (empty)
    output=$(run_in_shell "$TEST_DIR/repo" "cat .env" --mask-env)
    if ! contains "SECRET_KEY" "$output"; then
        pass "--mask-env masks .env file"
    else
        fail "--mask-env does not mask .env"
    fi

    # .env.example should NOT be masked
    output=$(run_in_shell "$TEST_DIR/repo" "cat .env.example" --mask-env)
    if contains "EXAMPLE_KEY" "$output"; then
        pass "--mask-env preserves .env.example"
    else
        fail "--mask-env incorrectly masks .env.example"
    fi
}

test_options_mask_secrets() {
    section "Mask secrets/ Directories Option"

    # secrets/ should be masked (empty dir)
    output=$(run_in_shell "$TEST_DIR/repo" "ls secrets/ 2>/dev/null | wc -l" --mask-secrets)
    # Extract just the number, ignoring bash warnings
    local count=$(echo "$output" | grep -v "bash:" | grep -v "bash-" | grep -oE '^[0-9]+$' | head -1)
    if [[ -n "$count" && "$count" -eq 0 ]]; then
        pass "--mask-secrets masks secrets/ directory"
    else
        fail "--mask-secrets does not mask secrets/ (found $count files)"
    fi

    # not-secrets/ should NOT be masked
    output=$(run_in_shell "$TEST_DIR/repo" "cat not-secrets/config.txt" --mask-secrets)
    if contains "public-config" "$output"; then
        pass "--mask-secrets preserves non-secret directories"
    else
        fail "--mask-secrets incorrectly masks non-secret directories"
    fi
}

test_options_ephemeral_home() {
    section "Ephemeral HOME Option"

    # Create a file in HOME, restart, check if it persists
    # First run: create file
    run_in_shell "$TEST_DIR/repo" "echo ephemeral-test > ~/test-file.txt" --ephemeral-home --name ephemeral-test >/dev/null 2>&1

    # Second run: check if file exists (it shouldn't)
    output=$(run_in_shell "$TEST_DIR/repo" "test -f ~/test-file.txt && echo PERSISTED || echo GONE" --ephemeral-home --name ephemeral-test)
    if contains "GONE" "$output"; then
        pass "--ephemeral-home does not persist files"
    else
        fail "--ephemeral-home incorrectly persists files"
    fi
}

test_mock_claude() {
    section "Mock Claude Binary"

    # Run with mock Claude to test wrapper mechanics
    output=$($SCRIPT --claude-bin "$TEST_DIR/mock-claude" --claude-share "$TEST_DIR/repo" "$TEST_DIR/repo" 2>&1 || true)

    if contains "MOCK_CLAUDE_STARTED" "$output"; then
        pass "Mock Claude binary executes"
    else
        fail "Mock Claude binary does not execute"
    fi

    if contains "/work/repo" "$output"; then
        pass "Mock Claude sees correct working directory"
    else
        fail "Mock Claude working directory incorrect"
    fi
}

test_host_verification() {
    section "Host-Side Mount Verification (requires sudo)"

    if [[ $SKIP_SUDO -eq 1 ]]; then
        skip "Host verification (needs sudo, use without --skip-sudo)"
        skip "Real HOME mount check"
        skip "Namespace isolation check"
        return
    fi

    if ! sudo -n true 2>/dev/null; then
        skip "Host verification (sudo requires password)"
        skip "Real HOME mount check"
        skip "Namespace isolation check"
        return
    fi

    # Start shell in background
    $SCRIPT --shell "$TEST_DIR/repo" >/dev/null 2>&1 &
    local wrapper_pid=$!
    sleep 0.5

    # Find bwrap process
    local bwrap_pid=$(pgrep -P $wrapper_pid bwrap 2>/dev/null || true)

    if [[ -z "$bwrap_pid" ]]; then
        kill $wrapper_pid 2>/dev/null || true
        skip "Host verification (could not find bwrap PID)"
        skip "Real HOME mount check"
        skip "Namespace isolation check"
        return
    fi

    # Check mounts
    local mountinfo
    mountinfo=$(sudo cat /proc/$bwrap_pid/mountinfo 2>/dev/null || true)

    if [[ -n "$mountinfo" ]]; then
        if echo "$mountinfo" | grep -q "/work/repo"; then
            pass "Host verification: repo is mounted"
        else
            fail "Host verification: repo not mounted"
        fi

        if ! echo "$mountinfo" | grep -qF "$HOME"; then
            pass "Host verification: real HOME not mounted"
        else
            fail "Host verification: SECURITY ISSUE - real HOME is mounted"
        fi

        # Check namespace isolation
        local host_ns=$(readlink /proc/self/ns/mnt)
        local sandbox_ns=$(sudo readlink /proc/$bwrap_pid/ns/mnt 2>/dev/null || true)

        if [[ -n "$sandbox_ns" && "$host_ns" != "$sandbox_ns" ]]; then
            pass "Host verification: mount namespace is isolated"
        else
            fail "Host verification: mount namespace not isolated"
        fi
    else
        skip "Host verification (could not read mountinfo)"
        skip "Real HOME mount check"
        skip "Namespace isolation check"
    fi

    # Cleanup
    kill $wrapper_pid 2>/dev/null || true
    wait $wrapper_pid 2>/dev/null || true
}

test_edge_cases() {
    section "Edge Cases"

    # Path with spaces (requires explicit --name to avoid space in sandbox name)
    local space_dir="$TEST_DIR/repo with spaces"
    mkdir -p "$space_dir"
    echo "space test" > "$space_dir/file.txt"

    output=$(run_in_shell "$space_dir" "cat file.txt" --name test-spaces)
    if contains "space test" "$output"; then
        pass "Handles repo paths with spaces"
    else
        fail "Does not handle paths with spaces"
    fi

    # Symlink resolution
    ln -s "$TEST_DIR/repo" "$TEST_DIR/repo-link"
    output=$(run_in_shell "$TEST_DIR/repo-link" "pwd")
    if contains "/work/repo" "$output"; then
        pass "Resolves symlinks in repo path"
    else
        fail "Does not resolve symlinks correctly"
    fi
}

#
# MAIN
#

main() {
    echo -e "${BOLD}Clavinculis Test Suite${RESET}"
    echo "Script: $SCRIPT"
    echo ""

    validate_environment
    setup
    trap cleanup EXIT

    # Run all test suites
    test_argument_parsing
    test_basic_shell_mode
    test_isolation_filesystem
    test_networking
    test_options_mount_base
    test_options_custom_name
    test_options_ro_repo
    test_options_minimal_etc
    test_options_full_etc
    test_options_no_etc
    test_options_mask_env
    test_options_mask_secrets
    test_options_ephemeral_home
    test_mock_claude
    test_host_verification
    test_edge_cases

    # Summary
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo -e "${BOLD}Results:${RESET}"
    echo -e "  ${GREEN}Passed:${RESET}  $PASSED"
    echo -e "  ${RED}Failed:${RESET}  $FAILED"
    echo -e "  ${YELLOW}Skipped:${RESET} $SKIPPED"
    echo ""

    if [[ $FAILED -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}✓ All tests passed!${RESET}"
        exit 0
    else
        echo -e "${RED}${BOLD}✗ Some tests failed${RESET}"
        exit 1
    fi
}

main "$@"
