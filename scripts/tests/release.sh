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
    ("Upload complete release as a draft", "draft-upload"),
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
cat > "$work/gh" <<'SH'
#!/bin/bash
set -euo pipefail
[[ "$1" == release && "$2" == create ]]
printf '%s\n' "$@" >> "$CALL_LOG"
if [[ "$SCENARIO" == upload-failure ]]; then
  echo "Fixture upload failure" >&2
  exit 1
fi
SH
chmod +x "$work/xcrun" "$work/gh"
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
echo "All macOS notarization regression checks passed"
export RUNNER_TEMP="$work" RELEASE_TAG="v2.3" RELEASE_NOTES="Unsigned Windows installation instructions"
touch "$work/first.msi" "$work/portable build.zip"
export ASSET_FILES
ASSET_FILES=$(printf '%s\n' "$work/first.msi" "$work/portable build.zip")
check draft-upload success 0 ""
[[ "$(sed -n '3p' "$CALL_LOG")" == "$RELEASE_TAG" ]]
[[ "$(sed -n '4p' "$CALL_LOG")" == "$work/first.msi" ]]
[[ "$(sed -n '5p' "$CALL_LOG")" == "$work/portable build.zip" ]]
grep -Fxq -- '--draft' "$CALL_LOG"
grep -Fxq -- '--verify-tag' "$CALL_LOG"
[[ "$(cat "$work/release-notes.md")" == "$RELEASE_NOTES" ]]
check draft-upload upload-failure 1 "Fixture upload failure"
ASSET_FILES="$work/missing.msi" check draft-upload success 1 "Missing release asset"
[[ ! -s "$CALL_LOG" ]]
echo "All draft release upload regression checks passed"
python3 -B -m unittest discover -s windows/packaging -p 'test_*.py'

ruby - <<'RUBY'
require 'yaml'

def check(condition, message)
  abort "FAIL: release workflow: #{message}" unless condition
end

def load_workflow(name)
  YAML.load_file(".github/workflows/#{name}.yml")
end

release = load_workflow('release')
build = load_workflow('windows-build')
validation = load_workflow('windows-foundation')
regressions = load_workflow('regressions')
jobs = release.fetch('jobs')
publisher = jobs.fetch('publish')
check(release.fetch('permissions') == {'contents' => 'read'}, 'Build permissions must be read-only')
check(publisher.fetch('permissions') == {'contents' => 'write'}, 'Only publisher needs write permission')
check(jobs.select { |_, job| job.dig('permissions', 'contents') == 'write' }.keys == ['publish'], 'Competing writer')
check(publisher.fetch('needs').sort == ['macos', 'windows'], 'Publish must wait for both platforms')
check(publisher.fetch('if') == "github.event_name == 'push' && startsWith(github.ref, 'refs/tags/')", 'Manual runs must never publish')
check(jobs.fetch('macos').fetch('if') == "github.event_name == 'push' || inputs.platform != 'windows'", 'Windows-only manual builds invoke macOS')
check(jobs.fetch('windows').fetch('if') == "github.event_name == 'push' || inputs.platform != 'macos'", 'macOS-only manual builds invoke Windows')
check(jobs.fetch('windows').fetch('uses') == './.github/workflows/windows-build.yml', 'Release must reuse validated Windows builds')
check(jobs.fetch('windows').fetch('with').fetch('sign') == false, 'Public Windows builds must be unsigned')
check(!jobs.fetch('windows').key?('secrets'), 'Public Windows builds must not consume signing secrets')
check(release.fetch('concurrency').fetch('cancel-in-progress') == false, 'Do not cancel an active release')
check(release.fetch('on', release[true]).dig('push', 'tags') == ['v*'], 'New version tags must trigger shared releases')
check(release.fetch('on', release[true]).dig('workflow_dispatch', 'inputs', 'platform', 'options').sort == ['all', 'macos', 'windows'], 'Missing manual platform choices')

steps = publisher.fetch('steps')
downloads = steps.select { |step| step['uses'] == 'actions/download-artifact@v4' }
check(downloads.map { |step| step.fetch('with').fetch('name') }.sort == [
  'PickleballScreensaver-macos', 'Windows-release-themes', 'Windows-release-win-arm64', 'Windows-release-win-x64'
], 'Publisher must download exact package artifacts, not diagnostics')
upload = steps.find { |step| step.fetch('run', '').include?('gh release create') }
check(upload.fetch('run').include?('--draft --verify-tag'), 'Upload must stay private and never create a tag')
check(!upload.fetch('run').include?('--clobber'), 'Do not overwrite release assets')
check(upload.fetch('run').include?('"${assets[@]}"'), 'Upload must pass the exact audited file list')
check(upload.fetch('env').fetch('ASSET_FILES') == '${{ steps.assets.outputs.files }}', 'Upload must use audited inventory')
check(steps.first.fetch('uses') == 'actions/checkout@v4', 'Publisher must use the tagged source')
check(steps[1].fetch('run').include?('check-new'), 'Refuse existing releases before uploads')
check(steps.last.fetch('run') == 'gh release edit "$RELEASE_TAG" --draft=false --latest', 'Public promotion must be last')
publishers = [release, build, validation].flat_map do |workflow|
  workflow.fetch('jobs').values.flat_map { |job| job.fetch('steps', []) }.select { |step| step.fetch('run', '').include?('gh release create') }
end
check(publishers.length == 1, 'Only Release may own publication')

check(build.fetch('permissions') == {'contents' => 'read'}, 'Reusable Windows build may not publish')
check(validation.fetch('permissions') == {'contents' => 'read'}, 'Validation may not publish')
check(validation.fetch('jobs').fetch('windows').fetch('uses') == './.github/workflows/windows-build.yml', 'Validation must use the same build as releases')
native = build.fetch('jobs').fetch('native-windows')
matrix = native.dig('strategy', 'matrix', 'include')
check(matrix.map { |item| [item['runner'], item['rid'], item['architecture']] }.sort == [
  ['windows-11-arm', 'win-arm64', 'Arm64'], ['windows-2025', 'win-x64', 'X64']
], 'Both native architectures must be checked')
native_steps = native.fetch('steps')
check(native_steps.any? { |step| step.fetch('run', '').include?('test-native-packages.ps1') }, 'Missing MSI lifecycle gates')
check(native_steps.any? { |step| step.fetch('run', '').include?('test-render.ps1') }, 'Missing rendering gates')
check(native_steps.any? { |step| step.fetch('run', '').include?('tests/Pickleball.Windows.Tests') }, 'Missing native apphost gates')
check(native_steps.any? { |step| step.fetch('run', '').include?('release.py version') }, 'Package versions must be derived')
check(!File.read('.github/workflows/windows-build.yml').include?('1.6.0'), 'Hard-coded release version')
package_upload = native_steps.find { |step| step.dig('with', 'name') == '${{ inputs.artifact-prefix }}-${{ matrix.rid }}' }
check(!package_upload.fetch('with').fetch('path').match?(/native-tests|\.png|\.log/), 'Test data leaks into release packages')
check(!package_upload.key?('if'), 'Packages must upload only after successful gates')
diagnostics = native_steps.find { |step| step.dig('with', 'name') == '${{ inputs.artifact-prefix }}-${{ matrix.rid }}-diagnostics' }
check(diagnostics.fetch('if') == 'always()', 'Keep failed-build diagnostics')
check(build.fetch('jobs').fetch('portable-core').fetch('steps').any? { |step| step.fetch('run', '').include?('restricted to main') }, 'Candidate signing lost main-only guard')
check(build.fetch('jobs').fetch('portable-core').fetch('steps').any? { |step| step.fetch('run', '').include?('tools/parity/compare.py') }, 'Missing Swift parity gate')
['push', 'pull_request'].each do |event|
  check(regressions.fetch('on', regressions[true]).fetch(event).fetch('paths').include?('.github/workflows/release.yml'), 'Release changes must trigger regression checks')
end
puts 'All shared-release workflow checks passed'
RUBY
