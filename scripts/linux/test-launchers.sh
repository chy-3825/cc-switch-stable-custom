#!/bin/bash
set -u

script_dir="$(cd "$(dirname "$0")" && pwd)"
fixtures="$script_dir/test-fixtures"
guard="$script_dir/clash-verge-guarded"
cc_launcher="$script_dir/cc-switch-launcher"
test_root="$(mktemp -d)"
test_log="$test_root/actions.log"

cleanup() {
  trap - EXIT HUP INT TERM
  if [ -n "${first_guard_pid:-}" ]; then
    kill -TERM "$first_guard_pid" 2>/dev/null || true
    wait "$first_guard_pid" 2>/dev/null || true
  fi
  if [ -n "${cc_launcher_pid:-}" ]; then
    kill -TERM "$cc_launcher_pid" 2>/dev/null || true
    wait "$cc_launcher_pid" 2>/dev/null || true
  fi
  rm -rf -- "$test_root"
}
trap cleanup EXIT HUP INT TERM

fail() {
  echo "launcher test failed: $*" >&2
  exit 1
}

wait_for_file() {
  local path="$1" attempt=0
  while [ ! -e "$path" ]; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 100 ] || fail "timed out waiting for $path"
    sleep 0.02
  done
}

wait_for_pattern() {
  local pattern="$1" path="$2" attempt=0
  until grep -Fqx "$pattern" "$path" 2>/dev/null; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 100 ] || fail "timed out waiting for $pattern in $path"
    sleep 0.02
  done
}

handler_path="$test_root/applications/clash-verge-handler.desktop"

common_guard_env=(
  "CLASH_GUARD_RUNTIME_DIR=$test_root/runtime"
  "CLASH_GUARD_LAUNCHER_PATH=$guard"
  "CLASH_GUARD_BINARY=$fixtures/fake-clash"
  "CLASH_GUARD_UI_EXE=/definitely/not/a/real/clash-ui"
  "CLASH_GUARD_SUDO=$fixtures/fake-sudo"
  "CLASH_GUARD_SYSTEMCTL=$fixtures/fake-systemctl"
  "CLASH_GUARD_GSETTINGS=$fixtures/fake-gsettings"
  "CLASH_GUARD_XDG_MIME=$fixtures/fake-xdg-mime"
  "CLASH_GUARD_APPLICATIONS_DIR=$test_root/applications"
  "CLASH_GUARD_PROTOCOL_REPAIR_ATTEMPTS=4"
  "CLASH_GUARD_PROTOCOL_REPAIR_INTERVAL=0.02"
  "FAKE_CLASH_HANDLER_PATH=$handler_path"
  "LAUNCHER_TEST_LOG=$test_log"
)

mkdir -p "$test_root/runtime/clash-verge-ui-leases"
printf '0\n' > "$test_root/runtime/clash-verge-ui-leases/$$"

env "${common_guard_env[@]}" \
  "FAKE_CLASH_EXIT_FILE=$test_root/first.exit" "$guard" &
first_guard_pid=$!
wait_for_file "$test_root/runtime/clash-verge-ui-leases/$first_guard_pid"
wait_for_pattern "Exec=$guard %u" "$handler_path"
[ ! -e "$test_root/runtime/clash-verge-ui-leases/$$" ] \
  || fail "stale/PID-reused lease was not pruned"

touch "$test_root/second.exit"
env "${common_guard_env[@]}" \
  "FAKE_CLASH_EXIT_FILE=$test_root/second.exit" "$guard" &
second_guard_pid=$!
wait "$second_guard_pid" || fail "second guard failed"
wait_for_pattern "Exec=$guard %u" "$handler_path"

if grep -q '^systemctl stop ' "$test_log"; then
  fail "short-lived second launch stopped the primary core"
fi

touch "$test_root/first.exit"
wait "$first_guard_pid" || fail "first guard failed"
first_guard_pid=""

[ "$(grep -c '^systemctl stop ' "$test_log")" -eq 1 ] \
  || fail "the last UI did not stop the service exactly once"
[ "$(grep -c '^gsettings set org.gnome.system.proxy mode none$' "$test_log")" -eq 2 ] \
  || fail "proxy was not disabled once at first startup and once at final exit"
[ ! -d "$test_root/runtime/clash-verge-ui-leases" ] \
  || fail "lease directory remains after final exit"
[ "$(grep -c '^xdg-mime default clash-verge-handler.desktop x-scheme-handler/' "$test_log")" -ge 4 ] \
  || fail "protocol defaults were not repaired after Clash rewrote its handler"

cc_exit_file="$test_root/cc.exit"
env DISPLAY= \
  CC_SWITCH_BINARY="$fixtures/fake-cc-switch" \
  CC_SWITCH_SYSTEMCTL="$fixtures/fake-systemctl" \
  CC_SWITCH_SUDO="$fixtures/fake-sudo" \
  CC_SWITCH_CLASH_PORT=1 \
  CC_SWITCH_CLASH_WAIT_ATTEMPTS=1 \
  FAKE_CC_EXIT_FILE="$cc_exit_file" \
  LAUNCHER_TEST_LOG="$test_log" \
  "$cc_launcher" &
cc_launcher_pid=$!

attempt=0
until grep -q '^cc-switch started ' "$test_log"; do
  attempt=$((attempt + 1))
  [ "$attempt" -lt 100 ] || fail "CC Switch child did not start"
  sleep 0.02
done
kill -TERM "$cc_launcher_pid"
wait "$cc_launcher_pid" || fail "CC launcher signal forwarding failed"
cc_launcher_pid=""
grep -q '^cc-switch signalled$' "$test_log" \
  || fail "CC launcher did not forward TERM to its child"

echo "launcher integration tests passed"
