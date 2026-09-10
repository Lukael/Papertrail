#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_path=${1:-"$repo_root/Papertrail.app"}
evidence_path=${2:-"$repo_root/Docs/Gate0H/evidence/current/finder-launch.json"}
binary_path="$app_path/Contents/MacOS/PapertrailApp"
info_path="$app_path/Contents/Info.plist"
python_path=${PYTHON_PATH:-$(command -v python3)}

case "$app_path" in
  "$repo_root/Papertrail.app") ;;
  *) printf '%s\n' "FAIL: app must be the bounded Gate 0H release bundle" >&2; exit 1 ;;
esac
test -d "$app_path"
test -x "$binary_path"
test -f "$info_path"
mkdir -p "$(dirname -- "$evidence_path")"

executable_sha=$(/usr/bin/shasum -a 256 "$binary_path" | /usr/bin/awk '{print $1}')
info_sha=$(/usr/bin/shasum -a 256 "$info_path" | /usr/bin/awk '{print $1}')
bundle_sha=$("$python_path" -c '
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
entries = []
for path in sorted(root.rglob("*")):
  if path.is_symlink(): raise SystemExit("bundle symlink is forbidden")
  if path.is_file():
    entries.append({"path": path.relative_to(root).as_posix(), "sha256": hashlib.sha256(path.read_bytes()).hexdigest(), "bytes": path.stat().st_size})
print(hashlib.sha256(json.dumps(entries, sort_keys=True, separators=(",", ":")).encode()).hexdigest())
' "$app_path")
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_path")
minimum_os=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$info_path")
/usr/bin/codesign --verify --deep --strict "$app_path"
signature=$(/usr/bin/codesign -dvv "$app_path" 2>&1 | /usr/bin/awk -F= '/^Signature=/{print $2; exit}')

app_pid=""
open_pid=""
cleanup() {
  if test -n "$app_pid" && /bin/kill -0 "$app_pid" 2>/dev/null; then
    /bin/kill -TERM "$app_pid" 2>/dev/null || true
  fi
  if test -n "$open_pid" && /bin/kill -0 "$open_pid" 2>/dev/null; then
    /bin/kill -TERM "$open_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

isolated_root=$(mktemp -d "${TMPDIR:-/tmp}/papertrail-finder-smoke.XXXXXX")
cleanup_root() { rm -rf "$isolated_root"; }
trap 'cleanup; cleanup_root' EXIT INT TERM

/usr/bin/open -n -W "$app_path" --args \
  --papertrail-application-support "$isolated_root/Application Support" &
open_pid=$!

attempt=0
while test "$attempt" -lt 100; do
  for candidate in $(/usr/bin/pgrep -f "PapertrailApp" 2>/dev/null || true); do
    command=$(/bin/ps -p "$candidate" -o command= 2>/dev/null || true)
    if test "$command" = "$binary_path --papertrail-application-support $isolated_root/Application Support"; then
      app_pid=$candidate
      break
    fi
  done
  test -n "$app_pid" && break
  if ! /bin/kill -0 "$open_pid" 2>/dev/null; then
    break
  fi
  attempt=$((attempt + 1))
  /bin/sleep 0.1
done

test -n "$app_pid"
/bin/kill -0 "$app_pid"
observed_command=$(/bin/ps -p "$app_pid" -o command=)
test "$observed_command" = "$binary_path --papertrail-application-support $isolated_root/Application Support"

/bin/kill -TERM "$app_pid"
termination_attempt=0
while /bin/kill -0 "$app_pid" 2>/dev/null && test "$termination_attempt" -lt 100; do
  termination_attempt=$((termination_attempt + 1))
  /bin/sleep 0.1
done
test "$termination_attempt" -lt 100

set +e
wait "$open_pid"
open_status=$?
set -e
test "$open_status" -eq 0
cleanup_root
trap - EXIT INT TERM

generated_at=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)
"$python_path" -c '
import json, os, sys, tempfile
path, generated, app, binary, executable_sha, info_sha, bundle_sha, bundle_id, minimum_os, signature, pid, command, status = sys.argv[1:]
value = {
  "status": "passed",
  "generatedAt": generated,
  "launchSurface": "LaunchServices via bounded /usr/bin/open -n -W",
  "historicalGate0AHarness": False,
  "bundle": {
    "path": app,
    "identifier": bundle_id,
    "executablePath": binary,
    "executableSHA256": executable_sha,
    "infoPlistSHA256": info_sha,
    "bundleTreeSHA256": bundle_sha,
    "minimumMacOS": minimum_os,
    "signature": signature,
    "codesignVerification": "codesign --verify --deep --strict passed"
  },
  "observation": {
    "processPID": int(pid),
    "exactProcessCommand": command,
    "processObservedAlive": True,
    "terminationSignal": "TERM (isolated test library only)",
    "processExitedWithinSeconds": 10,
    "openWaitExitStatus": int(status)
  }
}
directory = os.path.dirname(path)
descriptor, temporary = tempfile.mkstemp(prefix=".finder-launch.", suffix=".tmp", dir=directory)
try:
  with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
    json.dump(value, handle, indent=2, sort_keys=True)
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
  os.replace(temporary, path)
finally:
  if os.path.exists(temporary): os.unlink(temporary)
' "$evidence_path" "$generated_at" "$app_path" "$binary_path" "$executable_sha" "$info_sha" "$bundle_sha" "$bundle_id" "$minimum_os" "$signature" "$app_pid" "$observed_command" "$open_status"

printf '%s\n' "PASS: Gate 0H LaunchServices opened, observed, and cleanly terminated the exact release app"
printf '%s\n' "Evidence: $evidence_path"
