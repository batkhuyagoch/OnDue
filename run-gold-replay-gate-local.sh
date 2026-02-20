#!/usr/bin/env bash
set -euo pipefail

PROJECT="OnDue.xcodeproj"
SCHEME="OnDue"
TEST_NAME="OnDueTests/PolicyReplayHarnessTests/testGoldDatasetV1ReplayGateHasNoHardFailures"

SIMULATOR_NAME="$(python3 - <<'PY'
import re
import subprocess

out = subprocess.check_output(
    ["xcrun", "simctl", "list", "devices", "available"],
    text=True,
)
preferred = ("iPhone 17", "iPhone 16", "iPhone 15", "iPhone 14")
selected_name = None

lines = out.splitlines()
for model in preferred:
    for line in lines:
        if model not in line:
            continue
        if re.search(r"\(([0-9A-F-]{36})\)", line):
            selected_name = model
            break
    if selected_name:
        break

if not selected_name:
    for line in lines:
        if "iPhone" not in line:
            continue
        m = re.search(r"\s*(iPhone[^()]+)\s+\([0-9A-F-]{36}\)", line)
        if m:
            selected_name = m.group(1).strip()
            break

if not selected_name:
    raise SystemExit("No available iPhone simulator found.")

print(selected_name)
PY
)"

echo "Using simulator: ${SIMULATOR_NAME}"

xcodebuild test \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -destination "platform=iOS Simulator,name=${SIMULATOR_NAME},OS=latest" \
  -only-testing:"${TEST_NAME}"
