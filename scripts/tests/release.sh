#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

python3 - "$work" <<'PY'
import pathlib
import sys

workflow = pathlib.Path(".github/workflows/release.yml").read_text()
for name, filename in [
    ("Validate notarization credentials", "credentials"),
    ("Notarize and staple", "notarize"),
]:
    step = workflow.split(f"      - name: {name}\n", 1)[1]
    lines = step.split("        run: |\n", 1)[1].splitlines()
    body = []
    for line in lines:
        if line and not line.startswith("          "):
            break
        body.append(line[10:])
    script = "\n".join(body)
    if filename == "notarize":
        script = script[script.index("notarize() {"):script.index("\n# Notarize the zipped")]
        script += '\nnotarize "fixture.zip"\n'
    pathlib.Path(sys.argv[1], filename + ".sh").write_text(script)
PY

cat > "$work/xcrun" <<'SH'
#!/bin/bash
set -euo pipefail
echo "$*" >> "$CALL_LOG"
case "$2" in
  history)
    if [[ "$SCENARIO" == unauthorized ]]; then
      echo "HTTP 401: Invalid credentials" >&2
      exit 1
    fi
    echo '{"history":[]}'
    ;;
  submit)
    if [[ "$SCENARIO" == submit-failure ]]; then
      echo "HTTP 401: Invalid credentials" >&2
      exit 1
    fi
    echo '{"id":"fixture-id"}'
    ;;
  wait) ;;
  *) exit 1 ;;
esac
SH
chmod +x "$work/xcrun"
export PATH="$work:$PATH" CALL_LOG="$work/calls"
export APPLE_ID="test@example.invalid" APPLE_TEAM_ID="TESTTEAM"
export APPLE_APP_PASSWORD="test-placeholder"

check() {
  local script=$1 scenario=$2 expected_status=$3 expected_message=$4 status=0
  export SCENARIO=$scenario
  : > "$CALL_LOG"
  bash -e "$work/$script.sh" > "$work/output" 2>&1 || status=$?
  if [[ "$status" != "$expected_status" ]] ||
      { [[ -n "$expected_message" ]] && ! grep -Fq "$expected_message" "$work/output"; } ||
      grep -Eq 'Traceback|JSONDecodeError' "$work/output"; then
    cat "$work/output" >&2
    echo "FAIL: $script ($scenario)" >&2
    exit 1
  fi
}

APPLE_APP_PASSWORD="" check credentials missing 1 "Set APPLE_ID"
[[ ! -s "$CALL_LOG" ]]
check credentials unauthorized 1 "Apple notarization authentication failed"
grep -Fq "HTTP 401" "$work/output"
check credentials success 0 ""
grep -Fq "notarytool history" "$CALL_LOG"
check notarize submit-failure 1 "Notarization submission failed for fixture.zip"
grep -Fq "HTTP 401" "$work/output"
! grep -Fq "notarytool wait" "$CALL_LOG"
check notarize success 0 "Submitted fixture.zip as fixture-id"
grep -Fq "notarytool wait fixture-id" "$CALL_LOG"
echo "All release regression checks passed"
