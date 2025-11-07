#!/usr/bin/env bash
# configure-test-env.sh — run as root; resilient to failures.

# --- Resilience: never exit on errors; log and continue -----------------------
set +e
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

log() { printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }
try() { "$@"; rc=$?; [ $rc -ne 0 ] && log "ignored error ($rc): $*"; return 0; }
sleep_safe() { log "sleep $1"; try sleep "$1"; }

# --- Stop containers first ----------------------------------------------------
printf "Stopping lasorda, balboa and burgundy if running..."
try docker stop lasorda balboa burgundy
printf "Containers stopped."
sleep_safe 3

# --- Capture and clean the \"escaped\" SerialNumber from Redis ----------------
# NOTE: No -it here; TTY flags are messy in non-interactive scripts.
get_serial_clean() {
  # Grab raw value (can be "\"Something\"" or possibly already clean)
  raw="$(docker exec redis redis-cli get SerialNumber 2>/dev/null || true)"
  # Strip newlines/CRs and outer whitespace
  raw="$(printf '%s' "$raw" | tr -d '\r\n')"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"

  # Handle the "fucking stupid escaped string bullshit":
  # Example input: "\"EP200_vHUB_07\""  -> output: EP200_vHUB_07
  # 1) remove all occurrences of \" (backslash-quote)
  tmp="${raw//\\\"/}"
  # 2) remove any remaining surrounding quotes
  tmp="${tmp#\"}"; tmp="${tmp%\"}"

  printf '%s' "$tmp"
}

SAVED_VALUE="$(get_serial_clean)"
log "Captured SerialNumber => '${SAVED_VALUE}'"

# --- Flush DB and write back values (keeping the escaped-string format) -------
try docker exec redis redis-cli flushdb
sleep_safe 3

# We want the stored value to be the escaped string again, i.e. "\"VALUE\"".
# Using shell quoting so $SAVED_VALUE expands even though the redis value has quotes.
if [ -n "$SAVED_VALUE" ]; then
  try docker exec redis redis-cli set SerialNumber "\"$SAVED_VALUE\""
else
  log "SerialNumber was empty; skipping restore."
fi

# Set EnvironmentType to "\"Test\"" (escaped quotes around Test)
try docker exec redis redis-cli set EnvironmentType "\"Test\""

# Mirror the flag on disk
try mkdir -p /mntDAT/gmv-la/config/flags
printf 'Test\n' > /mntDAT/gmv-la/config/flags/EnvironmentType || log "ignored write error for flag file"

sleep_safe 3

# --- Bring lasorda back up ----------------------------------------------------
try docker start lasorda

log "Done."
