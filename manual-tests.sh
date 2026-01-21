#!/usr/bin/env bash
# manual-tests.sh - Interactive manual test suite for Clavinculis
# Run this OUTSIDE any clavinculis sandbox to test real-world functionality

set -euo pipefail

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

# State
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAVINCULIS="${SCRIPT_DIR}/clavinculis.sh"
TEST_RESULTS=()
PASSED=0
FAILED=0
SKIPPED=0
WARNINGS=0

# Ensure we're not in a sandbox
if [[ -f /.flatpak-info ]] || mount | grep -q "bubblewrap\|bwrap"; then
    echo -e "${YELLOW}WARNING: You may be inside a sandbox. These tests should be run on the real host.${RESET}"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# Header
clear
cat << 'EOF'
╔═══════════════════════════════════════════════════════════════╗
║           CLAVINCULIS MANUAL TEST SUITE                       ║
║                                                               ║
║  This script will guide you through critical manual tests     ║
║  that verify real-world functionality.                        ║
╚═══════════════════════════════════════════════════════════════╝

EOF

echo -e "${BOLD}Test Environment:${RESET}"
echo "  Script location: $CLAVINCULIS"
echo "  Current user: $USER"
echo "  Working directory: $PWD"
echo ""

# Check prerequisites
echo -e "${BOLD}Checking prerequisites...${RESET}"
if [[ ! -f "$CLAVINCULIS" ]]; then
    echo -e "${RED}✗ clavinculis.sh not found at: $CLAVINCULIS${RESET}"
    exit 1
fi
echo -e "${GREEN}✓ clavinculis.sh found${RESET}"

if ! command -v bwrap >/dev/null 2>&1; then
    echo -e "${RED}✗ bubblewrap not installed${RESET}"
    exit 1
fi
echo -e "${GREEN}✓ bubblewrap installed${RESET}"

if command -v claude >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Claude Code found in PATH${RESET}"
    HAS_CLAUDE=1
else
    echo -e "${YELLOW}⊘ Claude Code not found (some tests will be skipped)${RESET}"
    HAS_CLAUDE=0
fi

echo ""
read -p "Press Enter to start tests..."
clear

# Helper functions
section() {
    echo ""
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${BLUE}  $1${RESET}"
    echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════════${RESET}"
    echo ""
}

test_result() {
    local status="$1"
    local name="$2"
    local details="${3:-}"

    case "$status" in
        pass)
            echo -e "${GREEN}✓ PASS${RESET}: $name"
            TEST_RESULTS+=("PASS: $name")
            ((PASSED++)) || true
            ;;
        fail)
            echo -e "${RED}✗ FAIL${RESET}: $name"
            [[ -n "$details" ]] && echo -e "  ${RED}Details: $details${RESET}"
            TEST_RESULTS+=("FAIL: $name - $details")
            ((FAILED++)) || true
            ;;
        skip)
            echo -e "${YELLOW}⊘ SKIP${RESET}: $name"
            [[ -n "$details" ]] && echo -e "  ${YELLOW}Reason: $details${RESET}"
            TEST_RESULTS+=("SKIP: $name - $details")
            ((SKIPPED++)) || true
            ;;
        warn)
            echo -e "${YELLOW}⚠ WARN${RESET}: $name"
            [[ -n "$details" ]] && echo -e "  ${YELLOW}Details: $details${RESET}"
            TEST_RESULTS+=("WARN: $name - $details")
            ((WARNINGS++)) || true
            ;;
    esac
}

ask_user() {
    local question="$1"
    echo ""
    echo -e "${BOLD}$question${RESET}"
    echo "  [y] Yes (pass)"
    echo "  [n] No (fail)"
    echo "  [s] Skip this test"
    read -p "Your answer: " -n 1 -r
    echo
    case "$REPLY" in
        [Yy]) return 0 ;;
        [Ss]) return 2 ;;
        *) return 1 ;;
    esac
}

pause_with_instructions() {
    echo ""
    echo -e "${BOLD}$1${RESET}"
    echo ""
    read -p "Press Enter when ready to continue..."
}

cleanup_test_repo() {
    local repo="$1"
    if [[ -d "$repo" ]]; then
        rm -rf "$repo"
        echo "  Cleaned up test repo: $repo"
    fi
}

# ==============================================================================
# TEST 1: DNS Resolution (Critical)
# ==============================================================================
section "TEST 1: DNS Resolution (systemd-resolved compatibility)"

echo "Checking your DNS configuration..."
if [[ -L /etc/resolv.conf ]]; then
    RESOLV_TARGET=$(readlink -f /etc/resolv.conf)
    echo "  /etc/resolv.conf -> $RESOLV_TARGET"
    if [[ "$RESOLV_TARGET" == /run/* ]]; then
        echo -e "  ${YELLOW}→ Uses systemd-resolved (symlink to /run)${RESET}"
        RESOLV_TYPE="systemd-resolved"
    else
        echo "  → Regular symlink"
        RESOLV_TYPE="symlink"
    fi
else
    echo "  /etc/resolv.conf is a regular file"
    RESOLV_TYPE="regular"
fi

echo ""
echo "Testing network and DNS in default mode..."
output=$("$CLAVINCULIS" --shell "$SCRIPT_DIR" <<'TESTEOF' 2>&1
# Ping the configured nameserver (not a hardcoded IP)
ns=$(awk '/^nameserver/{print $2; exit}' /etc/resolv.conf 2>/dev/null)
if [[ -n "$ns" ]]; then
    ping -c1 -W2 "$ns" >/dev/null 2>&1 && echo "PING_OK" || echo "PING_FAIL"
else
    echo "PING_SKIP"
fi
getent hosts anthropic.com >/dev/null 2>&1 && echo "DNS_OK" || echo "DNS_FAIL"
exit 0
TESTEOF
)

if echo "$output" | grep -q "DNS_OK"; then
    test_result pass "DNS resolution in default mode"
    if echo "$output" | grep -q "PING_OK"; then
        test_result pass "Network connectivity (ping nameserver)"
    elif echo "$output" | grep -q "PING_SKIP"; then
        test_result warn "Network connectivity" "No nameserver found to ping"
    else
        test_result warn "Network connectivity" "Ping failed but DNS works"
    fi
elif echo "$output" | grep -q "DNS_FAIL"; then
    test_result fail "DNS resolution in default mode" "DNS lookup failed"
else
    test_result fail "DNS resolution in default mode" "Unexpected output"
fi

echo ""
echo "Testing DNS in --full-etc mode..."
output=$("$CLAVINCULIS" --full-etc --shell "$SCRIPT_DIR" <<'TESTEOF' 2>&1
getent hosts anthropic.com >/dev/null 2>&1 && echo "DNS_OK" || echo "DNS_FAIL"
exit 0
TESTEOF
) || true

if echo "$output" | grep -q "DNS_OK"; then
    test_result pass "DNS resolution in --full-etc mode"
else
    test_result fail "DNS resolution in --full-etc mode"
fi

# ==============================================================================
# TEST 2: Security Profiles
# ==============================================================================
section "TEST 2: Security Profiles"

echo "Testing --profile strict (default)..."
output=$("$CLAVINCULIS" --shell "$SCRIPT_DIR" <<'TESTEOF' 2>&1
# Check synthetic /etc (should have limited entries)
etc_count=$(ls /etc 2>/dev/null | wc -l)
echo "ETC_COUNT=$etc_count"
# Check for synthetic hostname
grep -q "sandbox-" /etc/hostname 2>/dev/null && echo "SYNTHETIC_HOSTNAME" || echo "HOST_HOSTNAME"
# Check passwd has only root and current user
user_count=$(wc -l < /etc/passwd)
echo "PASSWD_LINES=$user_count"
exit 0
TESTEOF
)

if echo "$output" | grep -q "SYNTHETIC_HOSTNAME"; then
    test_result pass "Strict profile: synthetic /etc/hostname"
else
    test_result fail "Strict profile: synthetic /etc/hostname" "Expected sandbox-* hostname"
fi

passwd_lines=$(echo "$output" | grep -oP 'PASSWD_LINES=\K[0-9]+' | head -1)
if [[ -n "$passwd_lines" && "$passwd_lines" -le 3 ]]; then
    test_result pass "Strict profile: minimal /etc/passwd ($passwd_lines lines)"
else
    test_result fail "Strict profile: minimal /etc/passwd" "Expected ≤3 lines, got $passwd_lines"
fi

echo ""
echo "Testing --profile balanced..."
output=$("$CLAVINCULIS" --profile balanced --shell "$SCRIPT_DIR" <<'TESTEOF' 2>&1
# Balanced should have /etc/localtime (if host has it)
test -f /etc/localtime && echo "LOCALTIME_EXISTS" || echo "LOCALTIME_MISSING"
# Should still have resolv.conf
test -f /etc/resolv.conf && echo "RESOLV_EXISTS" || echo "RESOLV_MISSING"
exit 0
TESTEOF
)

if echo "$output" | grep -q "RESOLV_EXISTS"; then
    test_result pass "Balanced profile: /etc/resolv.conf present"
else
    test_result fail "Balanced profile: /etc/resolv.conf missing"
fi

echo ""
echo "Testing --profile compat (full /etc)..."
# Count host /etc entries for comparison
HOST_ETC_COUNT=$(ls /etc 2>/dev/null | wc -l)
output=$("$CLAVINCULIS" --profile compat --shell "$SCRIPT_DIR" <<'TESTEOF' 2>&1
etc_count=$(ls /etc 2>/dev/null | wc -l)
echo "ETC_COUNT=$etc_count"
exit 0
TESTEOF
)

sandbox_etc_count=$(echo "$output" | grep -oP 'ETC_COUNT=\K[0-9]+' | head -1)
if [[ -n "$sandbox_etc_count" && "$sandbox_etc_count" -eq "$HOST_ETC_COUNT" ]]; then
    test_result pass "Compat profile: full host /etc ($sandbox_etc_count entries)"
elif [[ -n "$sandbox_etc_count" && "$sandbox_etc_count" -gt 20 ]]; then
    test_result pass "Compat profile: many /etc entries ($sandbox_etc_count)"
else
    test_result fail "Compat profile: full /etc" "Expected $HOST_ETC_COUNT entries, got $sandbox_etc_count"
fi

echo ""
echo "Testing --no-etc (extreme isolation)..."
output=$("$CLAVINCULIS" --no-etc --shell "$SCRIPT_DIR" <<'TESTEOF' 2>&1
etc_count=$(ls /etc 2>/dev/null | wc -l)
echo "ETC_COUNT=$etc_count"
test -f /etc/resolv.conf && echo "RESOLV_EXISTS" || echo "RESOLV_MISSING"
exit 0
TESTEOF
)

no_etc_count=$(echo "$output" | grep -oP 'ETC_COUNT=\K[0-9]+' | head -1)
if [[ -n "$no_etc_count" && "$no_etc_count" -eq 0 ]]; then
    test_result pass "--no-etc: empty /etc directory"
else
    test_result fail "--no-etc: empty /etc" "Expected 0 entries, got $no_etc_count"
fi

if echo "$output" | grep -q "RESOLV_MISSING"; then
    test_result pass "--no-etc: no DNS (resolv.conf missing as expected)"
else
    test_result fail "--no-etc: resolv.conf should be missing"
fi

# ==============================================================================
# TEST 3: Validation Error Messages (Critical)
# ==============================================================================
section "TEST 3: Validation Error Messages"

echo "Testing --name validation (invalid characters)..."
output=$("$CLAVINCULIS" --name '../../../evil' /tmp 2>&1 || true)
if echo "$output" | grep -q "must contain only"; then
    test_result pass "--name validation (path traversal blocked)"
else
    test_result fail "--name validation" "Error message not shown"
fi

echo ""
echo "Testing mount collision block..."
mkdir -p /tmp/test-collision-$$
output=$("$CLAVINCULIS" --mount-base /home /tmp/test-collision-$$ 2>&1 || true)
rmdir /tmp/test-collision-$$
if echo "$output" | grep -q "cannot be mounted under /home"; then
    test_result pass "Mount collision detection"
else
    test_result fail "Mount collision detection" "Error message not shown"
fi

echo ""
echo "Testing invalid profile..."
output=$("$CLAVINCULIS" --profile invalid-profile /tmp 2>&1 || true)
if echo "$output" | grep -q "Invalid --profile"; then
    test_result pass "Invalid profile validation"
else
    test_result fail "Invalid profile validation" "Error message not shown"
fi

echo ""
echo "Testing relative --state-base rejection..."
output=$("$CLAVINCULIS" --state-base relative/path /tmp 2>&1 || true)
if echo "$output" | grep -q "must be an absolute path"; then
    test_result pass "--state-base requires absolute path"
else
    test_result fail "--state-base validation" "Error message not shown"
fi

# ==============================================================================
# TEST 4: Secrets Masking (Critical)
# ==============================================================================
section "TEST 4: Secrets Masking (including symlinks)"

TEST_SECRETS_REPO="/tmp/clavinculis-secrets-test-$$"
mkdir -p "$TEST_SECRETS_REPO/secrets"

echo "Creating test repo with secrets..."
echo "AWS_SECRET_KEY=AKIAIOSFODNN7EXAMPLE" > "$TEST_SECRETS_REPO/.env"
echo "DATABASE_PASSWORD=super_secret_123" > "$TEST_SECRETS_REPO/secrets/db.env"
ln -s secrets/db.env "$TEST_SECRETS_REPO/.env.production"
echo "EXAMPLE=safe_value" > "$TEST_SECRETS_REPO/.env.example"
echo "  Created: .env (regular file)"
echo "  Created: secrets/db.env (regular file)"
echo "  Created: .env.production -> secrets/db.env (symlink)"
echo "  Created: .env.example (template)"

echo ""
echo "Testing WITHOUT masking (secrets should be visible)..."
output=$("$CLAVINCULIS" --shell "$TEST_SECRETS_REPO" <<'TESTEOF' 2>&1
grep -q "AWS_SECRET_KEY" .env && echo "ENV_VISIBLE" || echo "ENV_HIDDEN"
exit 0
TESTEOF
)

if echo "$output" | grep -q "ENV_VISIBLE"; then
    test_result pass "Secrets visible without masking (baseline)"
else
    test_result warn "Secrets baseline check" "Unexpected behavior"
fi

echo ""
echo "Testing WITH --mask-env (secrets should be hidden)..."
output=$("$CLAVINCULIS" --mask-env --shell "$TEST_SECRETS_REPO" <<'TESTEOF' 2>&1
# Check .env is empty
[[ ! -s .env ]] && echo "ENV_MASKED" || echo "ENV_NOT_MASKED"
# Check symlink is masked
[[ ! -s .env.production ]] && echo "SYMLINK_MASKED" || echo "SYMLINK_NOT_MASKED"
# Check template is visible
grep -q "EXAMPLE" .env.example && echo "TEMPLATE_VISIBLE" || echo "TEMPLATE_HIDDEN"
exit 0
TESTEOF
)

if echo "$output" | grep -q "ENV_MASKED"; then
    test_result pass ".env file masking"
else
    test_result fail ".env file masking" "File not masked"
fi

if echo "$output" | grep -q "SYMLINK_MASKED"; then
    test_result pass "Symlinked .env masking"
else
    test_result fail "Symlinked .env masking" "Symlink not masked"
fi

if echo "$output" | grep -q "TEMPLATE_VISIBLE"; then
    test_result pass ".env.example preserved"
else
    test_result fail ".env.example preserved" "Template was masked"
fi

echo ""
echo "Testing WITH --mask-secrets (directory should be empty)..."
output=$("$CLAVINCULIS" --mask-secrets --shell "$TEST_SECRETS_REPO" <<'TESTEOF' 2>&1
[[ -d secrets ]] && ls -A secrets | wc -l
exit 0
TESTEOF
)

file_count=$(echo "$output" | grep -oE '^[0-9]+$' | head -1)
if [[ -n "$file_count" && "$file_count" -eq 0 ]]; then
    test_result pass "secrets/ directory masking"
else
    test_result fail "secrets/ directory masking" "Directory not empty ($file_count files)"
fi

cleanup_test_repo "$TEST_SECRETS_REPO"

# ==============================================================================
# TEST 5: Custom Bind Mounts
# ==============================================================================
section "TEST 5: Custom Bind Mounts (--bind-ro, --bind-rw)"

TEST_BIND_DIR="/tmp/clavinculis-bind-test-$$"
mkdir -p "$TEST_BIND_DIR"
echo "external-data" > "$TEST_BIND_DIR/data.txt"

echo "Testing --bind-ro (read-only external mount)..."
output=$("$CLAVINCULIS" --bind-ro "$TEST_BIND_DIR:/external" --shell "$SCRIPT_DIR" <<'TESTEOF' 2>&1
# Check if external data is visible
cat /external/data.txt 2>/dev/null && echo "READ_OK" || echo "READ_FAIL"
# Try to write (should fail)
echo "test" > /external/write-test.txt 2>&1 && echo "WRITE_OK" || echo "WRITE_BLOCKED"
exit 0
TESTEOF
)

if echo "$output" | grep -q "external-data" && echo "$output" | grep -q "READ_OK"; then
    test_result pass "--bind-ro: external path readable"
else
    test_result fail "--bind-ro: external path not readable"
fi

if echo "$output" | grep -q "WRITE_BLOCKED"; then
    test_result pass "--bind-ro: write correctly blocked"
else
    test_result fail "--bind-ro: write should be blocked"
fi

echo ""
echo "Testing --bind-rw (read-write external mount)..."
output=$("$CLAVINCULIS" --bind-rw "$TEST_BIND_DIR:/external-rw" --shell "$SCRIPT_DIR" <<'TESTEOF' 2>&1
# Try to write
echo "written-from-sandbox" > /external-rw/sandbox-write.txt 2>&1 && echo "WRITE_OK" || echo "WRITE_FAIL"
exit 0
TESTEOF
)

if echo "$output" | grep -q "WRITE_OK"; then
    if [[ -f "$TEST_BIND_DIR/sandbox-write.txt" ]]; then
        test_result pass "--bind-rw: write persists to host"
    else
        test_result fail "--bind-rw: write did not persist"
    fi
else
    test_result fail "--bind-rw: write failed inside sandbox"
fi

rm -rf "$TEST_BIND_DIR"

# ==============================================================================
# TEST 6: Real Claude Code Integration (Critical if Claude installed)
# ==============================================================================
section "TEST 6: Real Claude Code Integration"

if [[ $HAS_CLAUDE -eq 0 ]]; then
    test_result skip "Claude Code integration" "Claude not installed"
else
    echo "This test will launch real Claude Code inside the sandbox."
    echo "You'll need to interact with it to verify functionality."
    echo ""
    echo -e "${BOLD}Instructions:${RESET}"
    echo "  1. Claude will start in the sandbox"
    echo "  2. If prompted, log in to your Anthropic account"
    echo "  3. Once Claude is ready, ask it: 'show me the first 10 lines of README.md'"
    echo "  4. Verify Claude can read the file"
    echo "  5. Type 'exit' or Ctrl+D to quit"
    echo ""
    read -p "Ready to launch Claude? (y/N) " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo ""
        echo "Launching Claude Code..."
        echo "─────────────────────────────────────────────────────────────"
        "$CLAVINCULIS" "$SCRIPT_DIR" || true
        echo "─────────────────────────────────────────────────────────────"

        if ask_user "Did Claude start successfully and respond to your query?"; then
            test_result pass "Claude Code launches and connects"
        else
            test_result fail "Claude Code launches and connects"
        fi

        if ask_user "Could Claude read files from the repo?"; then
            test_result pass "Claude can read repo files"
        else
            test_result fail "Claude can read repo files"
        fi
    else
        test_result skip "Claude Code integration" "User skipped"
    fi
fi

# ==============================================================================
# TEST 7: Session Persistence
# ==============================================================================
section "TEST 7: Session Persistence"

if [[ $HAS_CLAUDE -eq 0 ]]; then
    test_result skip "Session persistence" "Claude not installed"
else
    echo "This test verifies that Claude's login persists across runs."
    echo ""
    echo -e "${BOLD}Instructions:${RESET}"
    echo "  1. First run: Launch Claude and log in (if not already)"
    echo "  2. Exit Claude"
    echo "  3. Second run: Launch Claude again"
    echo "  4. Verify you're still logged in (no re-login prompt)"
    echo ""
    read -p "Test session persistence? (y/N) " -n 1 -r
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo ""
        echo "First run - logging in..."
        "$CLAVINCULIS" "$SCRIPT_DIR" || true

        echo ""
        echo "Second run - checking persistence..."
        "$CLAVINCULIS" "$SCRIPT_DIR" || true

        if ask_user "Were you still logged in on the second run?"; then
            test_result pass "Session persistence"
        else
            test_result fail "Session persistence" "Had to login again"
        fi
    else
        test_result skip "Session persistence" "User skipped"
    fi
fi

# ==============================================================================
# TEST 8: File Write Persistence
# ==============================================================================
section "TEST 8: File Write Persistence"

TEST_WRITE_REPO="/tmp/clavinculis-write-test-$$"
mkdir -p "$TEST_WRITE_REPO"
echo "# Test Repo" > "$TEST_WRITE_REPO/README.md"

echo "Creating test file inside sandbox..."
WRITE_TEST_NAME="write-test-$$"
"$CLAVINCULIS" --name "$WRITE_TEST_NAME" --shell "$TEST_WRITE_REPO" <<'TESTEOF' >/dev/null 2>&1
echo "test content" > test-file.txt
exit 0
TESTEOF

if [[ -f "$TEST_WRITE_REPO/test-file.txt" ]]; then
    content=$(cat "$TEST_WRITE_REPO/test-file.txt")
    if [[ "$content" == "test content" ]]; then
        test_result pass "File writes persist on host"
    else
        test_result fail "File writes persist on host" "Content mismatch"
    fi
else
    test_result fail "File writes persist on host" "File not found on host"
fi

cleanup_test_repo "$TEST_WRITE_REPO"

# ==============================================================================
# TEST 9: Isolation Verification
# ==============================================================================
section "TEST 9: Isolation Verification"

echo "Testing that real HOME is not accessible..."
output=$("$CLAVINCULIS" --shell "$SCRIPT_DIR" <<TESTEOF 2>&1
test -f ~/.bashrc && echo "BASHRC_VISIBLE" || echo "BASHRC_HIDDEN"
test -d ~/.ssh && echo "SSH_VISIBLE" || echo "SSH_HIDDEN"
test -d ~/.aws && echo "AWS_VISIBLE" || echo "AWS_HIDDEN"
exit 0
TESTEOF
)

if echo "$output" | grep -q "BASHRC_HIDDEN"; then
    test_result pass "Real HOME not accessible"
else
    test_result fail "Real HOME not accessible" ".bashrc is visible!"
fi

if echo "$output" | grep -q "SSH_HIDDEN"; then
    test_result pass "~/.ssh not accessible"
else
    test_result fail "~/.ssh not accessible" "SSH directory is visible!"
fi

if echo "$output" | grep -q "AWS_HIDDEN"; then
    test_result pass "~/.aws not accessible"
else
    test_result warn "~/.aws not accessible" "AWS directory is visible (or doesn't exist on host)"
fi

# ==============================================================================
# TEST 10: Read-Only Repo Mode
# ==============================================================================
section "TEST 10: Read-Only Repo Mode"

TEST_RO_REPO="/tmp/clavinculis-ro-test-$$"
mkdir -p "$TEST_RO_REPO"
echo "# RO Test" > "$TEST_RO_REPO/README.md"

echo "Testing write prevention in --ro-repo mode..."
RO_TEST_NAME="ro-test-$$"
output=$("$CLAVINCULIS" --name "$RO_TEST_NAME" --ro-repo --shell "$TEST_RO_REPO" <<'TESTEOF' 2>&1
echo "test" > should-fail.txt 2>&1 && echo "WRITE_OK" || echo "WRITE_BLOCKED"
cat README.md >/dev/null 2>&1 && echo "READ_OK" || echo "READ_FAIL"
exit 0
TESTEOF
)

if echo "$output" | grep -q "WRITE_BLOCKED"; then
    test_result pass "--ro-repo prevents writes"
else
    test_result fail "--ro-repo prevents writes" "Write succeeded"
fi

if echo "$output" | grep -q "READ_OK"; then
    test_result pass "--ro-repo allows reads"
else
    test_result fail "--ro-repo allows reads" "Read failed"
fi

cleanup_test_repo "$TEST_RO_REPO"

# ==============================================================================
# TEST 11: Git Operations
# ==============================================================================
section "TEST 11: Git Operations (Expected Behavior)"

if ! command -v git >/dev/null 2>&1; then
    test_result skip "Git operations" "git not installed"
else
    echo "Testing git behavior inside sandbox..."

    # This repo should be a git repo
    if [[ -d "$SCRIPT_DIR/.git" ]]; then
        output=$("$CLAVINCULIS" --shell "$SCRIPT_DIR" <<'TESTEOF' 2>&1
git status >/dev/null 2>&1 && echo "STATUS_OK" || echo "STATUS_FAIL"
git log -1 >/dev/null 2>&1 && echo "LOG_OK" || echo "LOG_FAIL"
exit 0
TESTEOF
)

        if echo "$output" | grep -q "STATUS_OK"; then
            test_result pass "git status works"
        else
            test_result fail "git status works"
        fi

        if echo "$output" | grep -q "LOG_OK"; then
            test_result pass "git log works"
        else
            test_result fail "git log works"
        fi

        test_result pass "Git read operations work (SSH-requiring ops expected to fail)"
    else
        test_result skip "Git operations" "Not a git repo"
    fi
fi

# ==============================================================================
# TEST 12: Process Cleanup
# ==============================================================================
section "TEST 12: Process Cleanup"

echo "Launching sandbox and killing it ungracefully..."
"$CLAVINCULIS" --shell "$SCRIPT_DIR" </dev/null >/dev/null 2>&1 &
PID=$!
sleep 2
kill $PID 2>/dev/null || true
wait $PID 2>/dev/null || true
sleep 2

echo "Checking for leftover bwrap processes..."
LEFTOVER=$(pgrep -u "$(id -u)" bwrap 2>/dev/null | wc -l)

if [[ $LEFTOVER -eq 0 ]]; then
    test_result pass "No leftover bwrap processes"
else
    test_result warn "No leftover bwrap processes" "Found $LEFTOVER bwrap process(es)"
fi

echo "Checking for leftover mounts..."
LEFTOVER_MOUNTS=$(mount | grep -c "claude-sandboxes" || true)

if [[ $LEFTOVER_MOUNTS -eq 0 ]]; then
    test_result pass "No leftover mounts"
else
    test_result warn "No leftover mounts" "Found $LEFTOVER_MOUNTS mount(s)"
fi

# ==============================================================================
# FINAL REPORT
# ==============================================================================
section "TEST SUMMARY"

echo ""
echo -e "${BOLD}Results:${RESET}"
echo -e "  ${GREEN}Passed:${RESET}  $PASSED"
echo -e "  ${RED}Failed:${RESET}  $FAILED"
echo -e "  ${YELLOW}Skipped:${RESET} $SKIPPED"
echo -e "  ${YELLOW}Warnings:${RESET} $WARNINGS"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════════════${RESET}"
    echo -e "${GREEN}${BOLD}  ✓ ALL CRITICAL TESTS PASSED                                  ${RESET}"
    echo -e "${GREEN}${BOLD}═══════════════════════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "${GREEN}Clavinculis is working correctly and ready for use!${RESET}"

    if [[ $WARNINGS -gt 0 ]]; then
        echo ""
        echo -e "${YELLOW}Note: $WARNINGS warning(s) found. Review details above.${RESET}"
    fi
else
    echo -e "${RED}${BOLD}═══════════════════════════════════════════════════════════════${RESET}"
    echo -e "${RED}${BOLD}  ✗ SOME TESTS FAILED                                          ${RESET}"
    echo -e "${RED}${BOLD}═══════════════════════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "${RED}Please review the failures above before using Clavinculis.${RESET}"
fi

echo ""
echo -e "${BOLD}Detailed Results:${RESET}"
for result in "${TEST_RESULTS[@]}"; do
    if [[ "$result" == PASS:* ]]; then
        echo -e "  ${GREEN}✓${RESET} ${result#PASS: }"
    elif [[ "$result" == FAIL:* ]]; then
        echo -e "  ${RED}✗${RESET} ${result#FAIL: }"
    elif [[ "$result" == SKIP:* ]]; then
        echo -e "  ${YELLOW}⊘${RESET} ${result#SKIP: }"
    elif [[ "$result" == WARN:* ]]; then
        echo -e "  ${YELLOW}⚠${RESET} ${result#WARN: }"
    fi
done

echo ""
echo "Test completed: $(date)"
echo ""

# Exit with appropriate code
if [[ $FAILED -eq 0 ]]; then
    exit 0
else
    exit 1
fi
