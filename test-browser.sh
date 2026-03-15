#!/bin/bash
# Test headless browser support in clavinculis sandbox
set -euo pipefail

REPO_DIR="${1:-$(pwd)}"
REPO_DIR="$(cd "$REPO_DIR" && pwd -P)"
REPO_NAME="$(basename "$REPO_DIR")"

echo "Testing headless browser support in clavinculis..."
echo "Repo: $REPO_DIR"
echo

PASS=0
FAIL=0
SKIP=0

run_browser_test() {
  local label="$1" browser_cmd="$2"

  local screenshot_name=".clavinculis-browser-test-${label}-$$.png"
  local sandbox_output="/work/${REPO_NAME}/${screenshot_name}"
  local host_output="${REPO_DIR}/${screenshot_name}"

  # Substitute placeholder with actual sandbox path
  browser_cmd="${browser_cmd//\{OUTPUT\}/${sandbox_output}}"

  echo "[$label] Running: $browser_cmd"
  rm -f "$host_output"

  local rc=0
  ./clavinculis.sh "$REPO_DIR" -- $browser_cmd 2>&1 || rc=$?

  if [[ -f "$host_output" ]]; then
    local size
    size=$(stat -c%s "$host_output" 2>/dev/null || echo "0")
    rm -f "$host_output"
    echo "[$label] PASS (screenshot: $size bytes)"
    PASS=$((PASS + 1))
  else
    echo "[$label] FAIL (no screenshot created, exit code $rc)"
    FAIL=$((FAIL + 1))
  fi
  echo
}

# Test Firefox
if command -v firefox &>/dev/null; then
  run_browser_test "firefox" \
    "firefox --headless --screenshot={OUTPUT} https://example.com"
else
  echo "[firefox] SKIP (not installed)"
  SKIP=$((SKIP + 1))
fi

# Test Chrome
if command -v google-chrome-stable &>/dev/null || command -v google-chrome &>/dev/null; then
  chrome_bin="google-chrome-stable"
  command -v google-chrome-stable &>/dev/null || chrome_bin="google-chrome"
  run_browser_test "chrome" \
    "$chrome_bin --headless --disable-gpu --screenshot={OUTPUT} https://example.com"
else
  echo "[chrome] SKIP (not installed)"
  SKIP=$((SKIP + 1))
fi

# Test Chromium
if command -v chromium &>/dev/null || command -v chromium-browser &>/dev/null; then
  chromium_bin="chromium"
  command -v chromium &>/dev/null || chromium_bin="chromium-browser"
  run_browser_test "chromium" \
    "$chromium_bin --headless --disable-gpu --screenshot={OUTPUT} https://example.com"
else
  echo "[chromium] SKIP (not installed)"
  SKIP=$((SKIP + 1))
fi

echo "---"
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
