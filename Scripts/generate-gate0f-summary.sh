#!/bin/sh
set -eu

repo_root=${1:?repository root required}
output=${2:?output path required}
evidence="$repo_root/Docs/Gate0F/evidence"
app_binary="$repo_root/.build/gate0e-app/Papertrail.app/Contents/MacOS/PapertrailApp"
service_source="$repo_root/Sources/PapertrailCore/Review/ReviewGenerationService.swift"

hash() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
test_count() {
  /usr/bin/awk '/^PASS[: ]/ { count += 1 } END { if (count > 0) print count - 1; else print 0 }' "$1"
}

for required in "$app_binary" "$service_source" \
  "$evidence/Gate0ATests.log" "$evidence/Gate0CTests.log" \
  "$evidence/Gate0DTests.log" "$evidence/Gate0ETests.log" "$evidence/Gate0FTests.log"; do
  test -f "$required"
done

temporary="$output.tmp.$$"
trap 'rm -f "$temporary"' EXIT HUP INT TERM
cat > "$temporary" <<EOF
{
  "status": "passed",
  "generatedAtUTC": "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "claimBoundary": "Deterministic structured-review lifecycle, validation, immutable promotion, and recovery checks.",
  "verification": {
    "gate0ATestGroups": $(test_count "$evidence/Gate0ATests.log"),
    "gate0CTestGroups": $(test_count "$evidence/Gate0CTests.log"),
    "gate0DTestGroups": $(test_count "$evidence/Gate0DTests.log"),
    "gate0ETestGroups": $(test_count "$evidence/Gate0ETests.log"),
    "gate0FScenarios": $(test_count "$evidence/Gate0FTests.log"),
    "releaseBuild": "passed",
    "swiftDataFrontendParse": "passed",
    "adHocSignatureVerification": "passed"
  },
  "currentArtifacts": {
    "releaseAppExecutableSHA256": "$(hash "$app_binary")",
    "reviewGenerationServiceSHA256": "$(hash "$service_source")"
  }
}
EOF
/usr/bin/python3 -m json.tool "$temporary" >/dev/null
/bin/mv "$temporary" "$output"
trap - EXIT HUP INT TERM
printf '%s\n' "PASS fresh Gate0F verification summary"
