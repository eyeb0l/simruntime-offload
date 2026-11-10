#!/bin/bash
# sro.sh — experimental prototype for serving a Simulator runtime from an
# external volume ("approach C" in docs/technical-assessment.md).
#
# This is an experiment harness, not the deliverable. It exists so that every
# step of an experiment is a reviewed, repeatable command rather than something
# typed by hand. It needs no root and never writes outside:
#   - <external volume>/SimRuntimes/
#   - /private/tmp/simruntime-offload-<uid>/                (mount points only)
#   - ~/Library/Developer/CoreSimulator/Profiles/Runtimes/   (one symlink per runtime)
#
# It never deletes or modifies an installed runtime. Removing the internal copy
# after staging is a separate, deliberate `xcrun simctl runtime delete`.
#
# Usage:
#   sro.sh [--dry-run] status
#   sro.sh [--dry-run] stage  <image-uuid>     copy a registered runtime image to the volume and verify it
#   sro.sh [--dry-run] attach <build>          attach the staged image read-only and link its runtime bundle
#   sro.sh [--dry-run] detach <build> [--force]  unlink and eject (refuses while any simulator is booted)
#
# The external volume is selected by APFS volume UUID, never by name or
# /dev/diskN:  export SRO_VOLUME_UUID=<uuid>   (see `diskutil info /Volumes/<name>`)

set -euo pipefail

dry_run=0
if [ "${1:-}" = "--dry-run" ]; then
  dry_run=1
  shift
fi

# The mount point must be readable by sandboxed Xcode helpers. CoreDeviceService
# (which drives Xcode's live device view) is App-Sandboxed and cannot read the
# user's Library outside its container; mounted there, the runtime works from
# simctl and xcodebuild but Xcode reports the device as unavailable. Its
# sandbox does include /private/tmp, which also needs no privileges.
# Override with SRO_MOUNT_ROOT to test other locations.
mount_root="${SRO_MOUNT_ROOT:-/private/tmp/simruntime-offload-$(id -u)}"
profiles_dir="$HOME/Library/Developer/CoreSimulator/Profiles/Runtimes"
bundle_subpath="Library/Developer/CoreSimulator/Profiles/Runtimes"

die() {
  echo "error: $*" >&2
  exit 1
}

note() {
  echo "==> $*"
}

# run <command...>: execute, or print when --dry-run is in effect.
run() {
  if [ "$dry_run" -eq 1 ]; then
    printf 'would run:'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

# Resolve the store directory on the external volume from its UUID. Fails
# unless that exact volume is mounted, so a different disk with the same name
# is never used by mistake.
store_dir() {
  [ -n "${SRO_VOLUME_UUID:-}" ] || die "SRO_VOLUME_UUID is not set"
  local info mount_point
  info="$(diskutil info "$SRO_VOLUME_UUID" 2>/dev/null)" ||
    die "no volume with UUID $SRO_VOLUME_UUID is attached"
  mount_point="$(printf '%s\n' "$info" | sed -n 's/^ *Mount Point: *//p')"
  [ -n "$mount_point" ] || die "volume $SRO_VOLUME_UUID is attached but not mounted"
  printf '%s/SimRuntimes\n' "$mount_point"
}

sha256_of() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# Read one field of one registered image from `simctl runtime list -j`.
image_field() {
  local uuid="$1" field="$2" json
  json="$(mktemp -t sro-runtimes)"
  xcrun simctl runtime list -j >"$json"
  plutil -extract "$uuid.$field" raw -o - "$json" 2>/dev/null || true
  rm -f "$json"
}

staged_image() {
  local build="$1" dir
  dir="$(store_dir)/$build"
  [ -d "$dir" ] || die "no staged image for build $build in $(store_dir)"
  local image
  image="$(find "$dir" -maxdepth 1 -name '*.dmg' -type f | head -n 1)"
  [ -n "$image" ] || die "no .dmg in $dir"
  printf '%s\n' "$image"
}

booted_device_count() {
  xcrun simctl list devices booted | grep -c '(Booted)' || true
}

cmd_status() {
  note "Registered runtime images"
  xcrun simctl runtime list
  echo
  note "Runtimes known to CoreSimulator"
  xcrun simctl list runtimes
  echo
  note "Staged images"
  if [ -n "${SRO_VOLUME_UUID:-}" ] && diskutil info "$SRO_VOLUME_UUID" >/dev/null 2>&1; then
    local store
    store="$(store_dir)"
    if [ -d "$store" ]; then
      find "$store" -maxdepth 2 -name '*.dmg' -type f -exec ls -lh {} \;
    else
      echo "(none: $store does not exist)"
    fi
  else
    echo "(external volume not attached, or SRO_VOLUME_UUID unset)"
  fi
  echo
  note "Offload mounts"
  mount | grep -F "$mount_root" || echo "(none)"
  echo
  note "Runtime links"
  if [ -d "$profiles_dir" ]; then
    ls -l "$profiles_dir"
  else
    echo "(none: $profiles_dir does not exist)"
  fi
}

cmd_stage() {
  local uuid="${1:?usage: sro.sh stage <image-uuid>}"
  local path build
  path="$(image_field "$uuid" path)"
  build="$(image_field "$uuid" build)"
  [ -n "$path" ] && [ -n "$build" ] || die "no registered image with identifier $uuid"

  # MobileAsset runtimes register the AssetData directory; the image is the
  # single .dmg in its Restore subdirectory. Imported runtimes register the
  # image file itself.
  local source
  if [ -d "$path" ]; then
    local count
    count="$(find "$path/Restore" -maxdepth 1 -name '*.dmg' -type f | wc -l | tr -d ' ')"
    [ "$count" = "1" ] || die "expected exactly one .dmg in $path/Restore, found $count"
    source="$(find "$path/Restore" -maxdepth 1 -name '*.dmg' -type f)"
  else
    source="$path"
  fi
  [ -r "$source" ] || die "cannot read $source"

  local dest_dir dest size_kb free_kb
  dest_dir="$(store_dir)/$build"
  dest="$dest_dir/$(basename "$source")"
  [ ! -e "$dest" ] || die "$dest already exists"

  size_kb="$(du -k "$source" | awk '{print $1}')"
  free_kb="$(df -k "$(dirname "$(store_dir)")" | awk 'NR==2 {print $4}')"
  [ "$free_kb" -gt $((size_kb + 1048576)) ] ||
    die "not enough free space on the external volume (need ${size_kb} KiB plus 1 GiB headroom)"

  note "Staging build $build: $source -> $dest"
  run mkdir -p "$dest_dir"
  # -X drops extended attributes so a quarantine flag can never follow the image.
  run cp -X "$source" "$dest.partial"

  if [ "$dry_run" -eq 1 ]; then
    echo "would verify SHA-256 and UDIF checksum, then rename into place"
    return
  fi

  note "Verifying copy (SHA-256 of source and destination)"
  local sum_source sum_dest
  sum_source="$(sha256_of "$source")"
  sum_dest="$(sha256_of "$dest.partial")"
  if [ "$sum_source" != "$sum_dest" ]; then
    rm -f "$dest.partial"
    die "checksum mismatch after copy; partial file removed"
  fi
  mv "$dest.partial" "$dest"
  printf '%s  %s\n' "$sum_dest" "$(basename "$dest")" >"$dest_dir/SHA256SUMS"

  note "Verifying image structure (hdiutil verify)"
  hdiutil verify "$dest"
  note "Staged. SHA-256 $sum_dest"
}

cmd_attach() {
  local build="${1:?usage: sro.sh attach <build>}"
  local image mount_point link
  image="$(staged_image "$build")"
  mount_point="$mount_root/$build"
  link="$profiles_dir/offload-$build.simruntime"

  if mount | grep -qF " on $mount_point ("; then
    die "$mount_point is already mounted"
  fi
  # After a reboot the mount is gone (and /private/tmp is emptied) but the
  # symlink survives, dangling. Replace it; refuse anything else in the way.
  if [ -L "$link" ] && [ ! -e "$link" ]; then
    note "Removing stale link $link"
    run rm "$link"
  elif [ -L "$link" ] || [ -e "$link" ]; then
    die "$link already exists"
  fi

  note "Attaching $image read-only at $mount_point"
  # /private/tmp is world-writable: refuse a mount root someone else created.
  if [ -e "$mount_root" ] && [ "$(stat -f %u "$mount_root")" != "$(id -u)" ]; then
    die "$mount_root exists and is not owned by you"
  fi
  run mkdir -p -m 700 "$mount_root"
  run mkdir -p "$mount_point" "$profiles_dir"
  # `diskutil image attach` uses the kernel-backed DiskImages2 stack. The older
  # `hdiutil attach` (deprecated on macOS 27) funnels every read through one
  # user-space helper and collapses under the concurrent I/O of a simulator
  # boot: measured at 881 reads/s against 6,704 on the same SSD.
  run diskutil image attach --readOnly --nobrowse --mountPoint "$mount_point" "$image"

  if [ "$dry_run" -eq 1 ]; then
    echo "would link the .simruntime bundle found under $mount_point/$bundle_subpath to $link"
    return
  fi

  local bundle
  bundle="$(find "$mount_point/$bundle_subpath" -maxdepth 1 -name '*.simruntime' | head -n 1)"
  if [ -z "$bundle" ]; then
    diskutil eject "$mount_point" || true
    die "no .simruntime bundle in the image; ejected again"
  fi

  # The link is created only after the mount exists, so the directory change
  # that CoreSimulator observes always refers to a resolvable bundle.
  ln -s "$bundle" "$link"
  note "Linked $link -> $bundle"
}

cmd_detach() {
  local build="${1:?usage: sro.sh detach <build> [--force]}"
  local force="${2:-}"
  local mount_point link booted
  mount_point="$mount_root/$build"
  link="$profiles_dir/offload-$build.simruntime"

  booted="$(booted_device_count)"
  [ "$booted" = "0" ] ||
    die "$booted simulator(s) are booted; shut them down first (xcrun simctl shutdown all)"

  # 1. Unregister. CoreSimulator notices the directory change and unloads the
  #    runtime; it also unloads when asked to approve the unmount below.
  if [ -L "$link" ]; then
    note "Removing $link"
    run rm "$link"
    run /bin/sleep 1
  fi

  if ! mount | grep -qF " on $mount_point ("; then
    echo "$mount_point is not mounted"
    return
  fi

  # 2. The per-user SimLaunchHost helper keeps liblaunch_sim.dylib mapped from
  #    every runtime it has loaded. Restarting it releases the mapping; it is
  #    relaunched on demand. Doing this first avoids the bus-error crash the
  #    helper suffers when a runtime is unmounted underneath it, which is what
  #    happens when Xcode itself deletes a runtime.
  note "Restarting SimLaunchHost"
  run launchctl kickstart -k "user/$(id -u)/com.apple.CoreSimulator.SimLaunchHost-arm64"

  # 3. Try a normal eject. It succeeds if nothing else holds the volume.
  local device whole
  device="$(mount | grep -F " on $mount_point (" | awk '{print $1}')"
  whole="$(diskutil info "$device" | awk -F': *' '/APFS Physical Store/ {print $2}' | sed -E 's/s[0-9]+$//')"
  note "Ejecting $mount_point"
  if [ "$dry_run" -eq 1 ]; then
    run diskutil eject "$mount_point"
    return
  fi
  # `simctl shutdown` returns before every simulator process has exited,
  # notably when a debugger is attached. Retry for a while so that a process
  # still on its way out is never mistaken for a persistent holder.
  local attempt
  for attempt in 1 2 3 4 5 6; do
    if diskutil eject "$mount_point" >/dev/null 2>&1; then
      note "Ejected (attempt $attempt)"
      return
    fi
    /bin/sleep 2
  done

  # 4. After simulators have run from the volume, root-owned diagnostics
  #    (observed: spindump) keep its binaries mapped indefinitely, and only a
  #    forced unmount releases it. Forced only on request.
  [ "$force" = "--force" ] ||
    die "the volume is still busy (commonly spindump holding simulator binaries); re-run with --force"
  note "Forcing unmount of $mount_point"
  diskutil unmount force "$mount_point"
  [ -z "$whole" ] || diskutil eject "$whole"
}

case "${1:-}" in
  status) cmd_status ;;
  stage) shift; cmd_stage "$@" ;;
  attach) shift; cmd_attach "$@" ;;
  detach) shift; cmd_detach "$@" ;;
  *)
    sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
    exit 64
    ;;
esac
