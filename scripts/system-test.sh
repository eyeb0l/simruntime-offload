#!/bin/bash
#
# System test: the whole life of one runtime, on a real machine.
#
#   scripts/system-test.sh <path-to-simruntime-offload> <build> <volume-uuid>
#
# <build> must be a runtime that is installed on the internal disk and is not
# offloaded. Use one you can afford to lose: download a spare with
#   xcodebuild -downloadPlatform iOS -buildVersion <version>
# The test offloads it, boots a simulator from it, restores it, offloads it
# again and restores it again, checking the state of the machine after every
# step. It ends with the runtime installed on the internal disk, as it began,
# and nothing of it left on the volume.
#
# It never names any other runtime in a command, and it checks at the end that
# the others are as they were. It refuses to start while a simulator is booted.
#
# What it cannot test, and a person must: `eject` followed by unplugging and
# replugging the disk, a restart with and without the disk, and what Xcode's
# windows show. See docs/system-test-checklist.md.
#
# This is also how a new macOS or Xcode version is validated before it is
# added to the compatibility table: run it with --allow-unvalidated-version
# appended to the command line.

set -u
set -o pipefail

if [ $# -lt 3 ]; then
  sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'
  exit 64
fi

tool="$1"
build="$2"
volume_uuid="$3"
shift 3
extra=("$@")   # e.g. --allow-unvalidated-version

mount_root="/private/tmp/simruntime-offload-$(id -u)"
mount_point="$mount_root/$build"
shared_links="/Library/Developer/DeviceKit/Runtimes"
user_links="$HOME/Library/Developer/CoreSimulator/Profiles/Runtimes"
link_name="offload-$build.simruntime"
inboxes=("/Library/Developer/CoreSimulator/Cryptex/Images/Inbox" "/Library/Developer/CoreSimulator/Images/Inbox")

step=0
failures=0
started=$(date +%s)

say()  { printf '\n== %s\n' "$*"; }
pass() { printf '   ok    %s\n' "$*"; }
fail() { printf '   FAIL  %s\n' "$*"; failures=$((failures + 1)); }
die()  { printf '\nSTOPPED: %s\n' "$*" >&2; exit 1; }

# check "<description>" <command...>: the command must succeed.
check() {
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$what"; else fail "$what"; fi
}
# check_not "<description>" <command...>: the command must fail.
check_not() {
  local what="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$what"; else pass "$what"; fi
}

run_tool() { "$tool" "$@" ${extra[@]+"${extra[@]}"}; }

# A step that must succeed; the test cannot go on meaningfully if it does not.
must() {
  local what="$1"; shift
  step=$((step + 1))
  say "Step $step: $what"
  local t0; t0=$(date +%s)
  if ! "$@"; then
    die "step $step ($what) failed. The machine is in whatever state the tool's own message describes; \`$tool list\` and \`$tool doctor\` will show it."
  fi
  printf '   (%s s)\n' "$(( $(date +%s) - t0 ))"
}

json() { xcrun python3 -c "$1"; }

internal_state() {   # prints the state of the build's internal image, or nothing
  xcrun simctl runtime list -j | json "
import json, sys
for image in json.load(sys.stdin).values():
    if image.get('build') == '$build': print(image.get('state', ''))"
}
is_internal_ready() { [ "$(internal_state)" = "Ready" ]; }
is_internal()       { [ -n "$(internal_state)" ]; }

runtime_bundle() {   # where CoreSimulator says the build's runtime is, if listed and available
  xcrun simctl list runtimes -j | json "
import json, sys
for runtime in json.load(sys.stdin)['runtimes']:
    if runtime.get('buildversion') == '$build' and runtime.get('isAvailable'): print(runtime['bundlePath'])"
}
served_from_volume()  { case "$(runtime_bundle)" in "$mount_point"/*) return 0 ;; *) return 1 ;; esac; }
served_internally()   { local b; b="$(runtime_bundle)"; [ -n "$b" ] && case "$b" in "$mount_root"/*) return 1 ;; *) return 0 ;; esac; }

is_mounted()  { mount | grep -qF " on $mount_point ("; }
has_link()    { [ -L "$shared_links/$link_name" ] || [ -L "$user_links/$link_name" ]; }
inboxes_empty() {
  local inbox
  for inbox in "${inboxes[@]}"; do
    [ -z "$(ls -A "$inbox" 2>/dev/null)" ] || return 1
  done
}
any_booted()  { xcrun simctl list devices booted | grep -q "(Booted)"; }

volume_root() {
  diskutil info -plist "$volume_uuid" 2>/dev/null | json "
import plistlib, sys
print(plistlib.loads(sys.stdin.buffer.read()).get('MountPoint', ''))"
}
image_dir()          { printf '%s/SimRuntimes/%s' "$(volume_root)" "$build"; }
image_on_volume()    { ls "$(image_dir)"/*.dmg >/dev/null 2>&1; }
image_matches_sums() { ( cd "$(image_dir)" && shasum -a 256 -c SHA256SUMS ); }

# Everything about the other runtimes that must not change.
others() {
  run_tool list | grep -v "$build" || true
  xcrun simctl list runtimes | grep -v "$build" || true
}

wait_for() {   # wait_for <seconds> <command...>
  local limit="$1"; shift
  local i
  for ((i = 0; i < limit; i++)); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

check_offloaded() {
  check "internal copy is gone"                       check_not_internal
  check "the daemon's inboxes are empty"              inboxes_empty
  check "image is on the volume"                      image_on_volume
  check "image matches its recorded checksum"         image_matches_sums
  check "image is attached at $mount_point"           is_mounted
  check "runtime is linked"                           has_link
  check "CoreSimulator lists the runtime from the volume" wait_for 15 served_from_volume
}
check_not_internal() { ! is_internal; }

check_restored() {
  check "CoreSimulator reports the internal image ready"  wait_for 30 is_internal_ready
  check "the daemon's inboxes are empty"                  inboxes_empty
  check_not "image is no longer attached at $mount_point" is_mounted
  check_not "runtime is no longer linked"                 has_link
  check "CoreSimulator lists the runtime from the internal disk" wait_for 20 served_internally
}

boot_a_device() {
  local type device ok=0
  type="$(xcrun simctl list runtimes -j | json "
import json, sys
for runtime in json.load(sys.stdin)['runtimes']:
    if runtime.get('buildversion') == '$build': print(runtime['supportedDeviceTypes'][0]['identifier'])")"
  local runtime_id
  runtime_id="$(xcrun simctl list runtimes -j | json "
import json, sys
for runtime in json.load(sys.stdin)['runtimes']:
    if runtime.get('buildversion') == '$build': print(runtime['identifier'])")"
  device="$(xcrun simctl create "sro-system-test-$$" "$type" "$runtime_id")" || return 1
  if xcrun simctl boot "$device" && xcrun simctl bootstatus "$device" >/dev/null 2>&1 \
     && xcrun simctl launch "$device" com.apple.Preferences >/dev/null; then
    pass "a new device booted from $(runtime_bundle | cut -c1-48)… and launched Settings"
    local open_files
    open_files="$(lsof 2>/dev/null | grep -c "$mount_point/")"
    if [ "$open_files" -gt 0 ]; then pass "$open_files files open under the offload mount"; else fail "no files open under the offload mount"; fi
  else
    fail "a new device did not boot and launch Settings"; ok=1
  fi
  xcrun simctl shutdown "$device" >/dev/null 2>&1
  xcrun simctl delete "$device" >/dev/null 2>&1
  return $ok
}

# ---------------------------------------------------------------------------

say "Preconditions"
[ -x "$tool" ] || die "$tool is not an executable"
any_booted && die "a simulator is booted; shut it down first"
run_tool doctor >/dev/null || die "\`$tool doctor\` does not pass; run it to see why"
pass "doctor passes"
is_internal_ready || die "build $build is not installed on the internal disk (see \`$tool list\`)"
pass "build $build is installed on the internal disk"
[ -n "$(volume_root)" ] || die "no mounted volume has the UUID $volume_uuid"
pass "the volume is mounted at $(volume_root)"
image_on_volume && die "$(image_dir) already holds an image; this test wants to start clean"
is_mounted && die "$mount_point is already a mount point"
pass "nothing of this build is on the volume"
others_before="$(others)"

dry_run_offload() {
  run_tool offload "$build" --volume "$volume_uuid" --dry-run || return 1
  check "the dry run changed nothing" is_internal_ready
  check_not "the dry run copied nothing" image_on_volume
}
must "offload --dry-run" dry_run_offload

first_offload() {
  local output
  output="$(run_tool offload "$build" --volume "$volume_uuid")" || { printf '%s\n' "$output"; return 1; }
  printf '%s\n' "$output" | grep -v '^  [0-9]*%$'
  if printf '%s\n' "$output" | grep -q "^Copying "; then pass "copied the image"; else fail "expected a copy"; fi
  check_offloaded
}
must "offload" first_offload

must "boot a simulator from the offloaded runtime" boot_a_device

sync_is_idempotent() {
  local before after
  before="$(mount | grep -c "$mount_root/")"
  run_tool sync || return 1
  after="$(mount | grep -c "$mount_root/")"
  if [ "$before" = "$after" ]; then pass "sync changed no mounts"; else fail "sync changed the mounts ($before -> $after)"; fi
  check "runtime is still served from the volume" served_from_volume
}
must "sync, when there is nothing to do" sync_is_idempotent

offload_twice_refused() {
  if run_tool offload "$build" --volume "$volume_uuid"; then fail "a second offload was not refused"; return 1; fi
  pass "a second offload was refused"
  check "and changed nothing" served_from_volume
}
must "offload again is refused" offload_twice_refused

dry_run_restore() {
  run_tool restore "$build" --dry-run || return 1
  check "the dry run changed nothing" served_from_volume
  check_not "the dry run imported nothing" is_internal
}
must "restore --dry-run" dry_run_restore

first_restore() {
  run_tool restore "$build" || return 1
  check_restored
  check "the image was kept on the volume" image_on_volume
  check "and still matches its checksum" image_matches_sums
}
must "restore, keeping the image" first_restore

second_offload() {
  local output
  output="$(run_tool offload "$build" --volume "$volume_uuid")" || { printf '%s\n' "$output"; return 1; }
  printf '%s\n' "$output"
  if printf '%s\n' "$output" | grep -q "^Copying "; then fail "copied again instead of reusing the image"; else pass "reused the image already on the volume"; fi
  check_offloaded
  check "exactly one image in the build's directory" test "$(ls "$(image_dir)"/*.dmg | wc -l | tr -d ' ')" = 1
}
must "offload again, reusing the image left on the volume" second_offload

second_restore() {
  local dir; dir="$(image_dir)"
  run_tool restore "$build" --delete-image || return 1
  check_restored
  check_not "the image was deleted from the volume" test -e "$dir"
}
must "restore --delete-image" second_restore

say "Afterwards"
if [ "$(others)" = "$others_before" ]; then
  pass "every other runtime is as it was"
else
  fail "something about the other runtimes changed:"
  diff <(printf '%s\n' "$others_before") <(printf '%s\n' "$(others)") | sed 's/^/         /'
fi
check "doctor still passes" run_tool doctor
check_not "no simulator was left booted" any_booted

printf '\n%s steps in %s s. ' "$step" "$(( $(date +%s) - started ))"
if [ "$failures" -eq 0 ]; then
  printf 'PASSED.\n'
  exit 0
fi
printf '%s check(s) FAILED.\n' "$failures"
exit 1
