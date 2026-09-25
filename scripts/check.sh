#!/usr/bin/env bash
# Full local verification. Requires Xcode, an iOS Simulator, Docker, Supabase CLI, Python 3.
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."

for check_tool in xcodebuild xcrun docker supabase python3; do
  command -v "$check_tool" >/dev/null || { echo "Missing required tool: $check_tool" >&2; exit 1; }
done
docker info >/dev/null 2>&1 || { echo "Start Docker before running these checks." >&2; exit 1; }

mkdir -p build
check_logs="$(mktemp -d "${PWD}/build/check.XXXXXX")"
check_fixture="whoisintownrightnowTests/LocalSupabase.json"
check_had_fixture=false
check_wrote_fixture=false
check_started_stack=false
if [[ -f "$check_fixture" ]]; then
  cp "$check_fixture" "$check_logs/fixture-backup.json"
  check_had_fixture=true
fi
cleanup() {
  if $check_wrote_fixture; then
    if $check_had_fixture; then
      mv "$check_logs/fixture-backup.json" "$check_fixture"
    else
      rm -f "$check_fixture"
    fi
  fi
  if $check_started_stack; then
    supabase stop > "$check_logs/supabase-stop.log" 2>&1 || true
  fi
}
trap cleanup EXIT

if ! supabase status >/dev/null 2>&1; then
  check_started_stack=true
  echo "Starting this repository's local Supabase stack..."
  if ! supabase start -x realtime,imgproxy,mailpit,postgres-meta,studio,edge-runtime,logflare,vector,supavisor > "$check_logs/supabase-start.log" 2>&1; then
    echo "Supabase could not start. Details: $check_logs/supabase-start.log" >&2
    exit 1
  fi
fi
supabase migration up --local > "$check_logs/migrations.log" 2>&1
echo "Checking account isolation, settings conflicts, Auth, and Storage..."
python3 -u Tests/account_backend_test.py
python3 -u Tests/contacts_backend_test.py
check_wrote_fixture=true
supabase status -o json > "$check_fixture" 2> "$check_logs/supabase-status.log"

check_simulator="${SIMULATOR_ID:-}"
if [[ -z "$check_simulator" ]]; then
  check_simulator="$(xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = [d for group in json.load(sys.stdin)["devices"].values() for d in group if "iPhone" in d["name"]]
devices.sort(key=lambda d: d["state"] != "Booted")
if not devices:
    sys.exit("Install an iPhone Simulator in Xcode first.")
print(devices[0]["udid"])
')"
fi
echo "Building and running Swift tests on simulator $check_simulator..."
if ! xcodebuild -project whoisintownrightnow.xcodeproj -scheme whoisintownrightnow \
  -configuration Debug -destination "platform=iOS Simulator,id=$check_simulator" \
  -derivedDataPath build/DerivedData -resultBundlePath "$check_logs/tests.xcresult" \
  -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  test > "$check_logs/simulator.log" 2>&1; then
  tail -60 "$check_logs/simulator.log"
  exit 1
fi
echo "Building unsigned Release for iPhone..."
if ! xcodebuild -project whoisintownrightnow.xcodeproj -scheme whoisintownrightnow \
  -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build > "$check_logs/release.log" 2>&1; then
  tail -60 "$check_logs/release.log"
  exit 1
fi
echo "Checking signal geometry..."
xcrun swiftc -parse-as-library Models.swift Tests/SignalConnectionTests.swift -o "$check_logs/signal-tests"
"$check_logs/signal-tests"
echo "All checks passed. Logs and XCTest results: $check_logs"
