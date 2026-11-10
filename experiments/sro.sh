#!/bin/bash
# sro.sh — experimental prototype for serving a Simulator runtime from an
# external volume ("approach C" in docs/technical-assessment.md).
#
# This is an experiment harness, not the deliverable. It exists so that every
# step of an experiment is a reviewed, repeatable command rather than something
# typed by hand. It needs no root and never writes outside:
#   - <external volume>/SimRuntimes/
#   - /private/tmp/simruntime-offload-<uid>/                (mount points only)
#   - the link directory (default ~/Library/Developer/CoreSimulator/Profiles/Runtimes/)
#   - ~/Library/Application Support/simruntime-offload/      (manifest, installed copy)
#   - ~/Library/LaunchAgents/ and ~/Library/Logs/simruntime-offload/ (agent only)
#
# It never deletes or modifies an installed runtime. Removing the internal copy
# after staging is a separate, deliberate `xcrun simctl runtime delete`.
#
# Usage:
#   sro.sh [--dry-run] status
#   sro.sh [--dry-run] stage  <image-uuid>       copy a registered runtime image to the volume and verify it
#   sro.sh [--dry-run] attach <build>            attach the staged image read-only and link its runtime bundle
#   sro.sh [--dry-run] detach <build> [--force]  unlink and eject (refuses while any simulator is booted)
#   sro.sh enable  <build>                       add a staged runtime to the manifest that `sync` serves
#   sro.sh disable <build>                       remove it from the manifest
#   sro.sh [--dry-run] sync                      attach every manifest runtime whose volume is present;
#                                                remove the links of those whose volume is absent
#   sro.sh [--dry-run] eject                     detach every manifest runtime, then eject the volume: run before unplugging
#   sro.sh agent install|uninstall|status        per-user LaunchAgent that runs `sync` at login and on every mount
#
# The external volume is selected by APFS volume UUID, never by name or
# /dev/diskN:  export SRO_VOLUME_UUID=<uuid>   (see `diskutil info /Volumes/<name>`)
#
# Settings are remembered in ~/Library/Application Support/simruntime-offload/config
# once `agent install` or `enable` has run, so everyday commands (sync, eject,
# status) need no environment variables. These override the remembered values:
#   SRO_VOLUME_UUID   volume used by stage/attach/enable
#   SRO_MOUNT_ROOT    where images are mounted (default /private/tmp/simruntime-offload-<uid>)
#   SRO_LINK_DIR      where runtime links are created (default the per-user profile directory)

set -euo pipefail

dry_run=0
if [ "${1:-}" = "--dry-run" ]; then
  dry_run=1
  shift
fi

state_dir="$HOME/Library/Application Support/simruntime-offload"
manifest="$state_dir/runtimes.tsv"
config="$state_dir/config"
agent_label="dev.simruntime-offload.agent"
agent_plist="$HOME/Library/LaunchAgents/$agent_label.plist"
agent_script="$state_dir/sro.sh"
agent_binary="$state_dir/sro-agent"
agent_log_dir="$HOME/Library/Logs/simruntime-offload"
bundle_subpath="Library/Developer/CoreSimulator/Profiles/Runtimes"

# config_get <key>: print a remembered setting, or nothing. The file holds
# plain key=value lines and is read, never executed.
config_get() {
  [ -f "$config" ] || return 0
  sed -n "s/^$1=//p" "$config" | head -n 1
}

# config_set <key> <value>
config_set() {
  mkdir -p "$state_dir"
  touch "$config"
  local tmp
  tmp="$(mktemp -t sro-config)"
  grep -v "^$1=" "$config" >"$tmp" || true
  printf '%s=%s\n' "$1" "$2" >>"$tmp"
  mv "$tmp" "$config"
}

# The mount point must be readable by sandboxed Xcode helpers. CoreDeviceService
# (which drives Xcode's live device view) is App-Sandboxed and cannot read the
# user's Library outside its container; mounted there, the runtime works from
# simctl and xcodebuild but Xcode reports the device as unavailable. Its
# sandbox does include /private/tmp, which also needs no privileges.
mount_root="${SRO_MOUNT_ROOT:-$(config_get mount_root)}"
[ -n "$mount_root" ] || mount_root="/private/tmp/simruntime-offload-$(id -u)"
profiles_dir="${SRO_LINK_DIR:-$(config_get link_dir)}"
[ -n "$profiles_dir" ] || profiles_dir="$HOME/Library/Developer/CoreSimulator/Profiles/Runtimes"
SRO_VOLUME_UUID="${SRO_VOLUME_UUID:-$(config_get volume_uuid)}"

die() {
  echo "error: $*" >&2
  exit 1
}

timestamps=0
note() {
  if [ "$timestamps" -eq 1 ]; then
    echo "[$(date '+%H:%M:%S')] ==> $*"
  else
    echo "==> $*"
  fi
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

# attach_image <build> <image path>: mount the image read-only and link its
# runtime bundle. Shared by `attach` and `sync`.
attach_image() {
  local build="$1" image="$2"
  local mount_point link
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
  run mkdir -p "$mount_point"
  # The default link directory is ours to create; any other (system) location
  # must already exist and be writable.
  case "$profiles_dir" in
    "$HOME"/*) run mkdir -p "$profiles_dir" ;;
    *) [ -d "$profiles_dir" ] && [ -w "$profiles_dir" ] || die "link directory $profiles_dir is missing or not writable" ;;
  esac
  # `diskutil image attach` uses the kernel-backed DiskImages2 stack. The older
  # `hdiutil attach` (deprecated on macOS 27) funnels every read through one
  # user-space helper and collapses under the concurrent I/O of a simulator
  # boot: measured at 881 reads/s against 6,704 on the same SSD.
  run diskutil image attach --readOnly --nobrowse --mountPoint "$mount_point" "$image" ||
    die "could not attach $image (from the login agent, \"Operation not permitted\" means it has not been allowed access to removable volumes)"

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

cmd_attach() {
  local build="${1:?usage: sro.sh attach <build>}"
  attach_image "$build" "$(staged_image "$build")"
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

# --- Manifest ----------------------------------------------------------------
# One line per runtime to serve: <build> TAB <volume UUID> TAB <image path
# relative to the volume root>. Kept on the internal disk so that `sync` can
# tell which links are ours, and clean them up, while the volume is absent.

cmd_enable() {
  local build="${1:?usage: sro.sh enable <build>}"
  local image volume_root relative
  image="$(staged_image "$build")"
  volume_root="$(dirname "$(store_dir)")"
  relative="${image#"$volume_root"/}"
  mkdir -p "$state_dir"
  touch "$manifest"
  if awk -F'\t' -v b="$build" '$1 == b {found = 1} END {exit !found}' "$manifest"; then
    die "$build is already in the manifest"
  fi
  printf '%s\t%s\t%s\n' "$build" "$SRO_VOLUME_UUID" "$relative" >>"$manifest"
  config_set volume_uuid "$SRO_VOLUME_UUID"
  note "Enabled $build ($relative on volume $SRO_VOLUME_UUID)"
}

cmd_disable() {
  local build="${1:?usage: sro.sh disable <build>}"
  [ -f "$manifest" ] || die "the manifest is empty"
  local tmp
  tmp="$(mktemp -t sro-manifest)"
  awk -F'\t' -v b="$build" '$1 != b' "$manifest" >"$tmp"
  mv "$tmp" "$manifest"
  note "Disabled $build (its mount and link, if any, are untouched; use detach)"
}

# sync_one <build> <volume uuid> <relative image path>
sync_one() {
  local build="$1" uuid="$2" relative="$3"
  local mount_point link volume_root image
  mount_point="$mount_root/$build"
  link="$profiles_dir/offload-$build.simruntime"

  volume_root="$(diskutil info "$uuid" 2>/dev/null | sed -n 's/^ *Mount Point: *//p')"
  image="$volume_root/$relative"

  if [ -n "$volume_root" ] && [ -f "$image" ]; then
    if mount | grep -qF " on $mount_point ("; then
      if [ -L "$link" ] && [ -e "$link" ]; then
        echo "$build: already attached"
      else
        echo "$build: mounted but not linked; leaving it alone (use detach, then sync)"
      fi
    else
      attach_image "$build" "$image"
    fi
    return
  fi

  # The volume, or the image on it, is absent. A dangling link makes every
  # simctl invocation print a warning, so remove ours.
  if [ -L "$link" ] && [ ! -e "$link" ]; then
    note "$build: volume absent; removing dangling link $link"
    run rm "$link"
  else
    echo "$build: volume absent; nothing to do"
  fi
}

cmd_sync() {
  [ -s "$manifest" ] || { echo "manifest is empty; nothing to sync"; return; }
  timestamps=1
  echo "--- sync $(date '+%Y-%m-%d %H:%M:%S')"

  # launchd starts the agent for every mount, including the ones sync itself
  # makes. A lock keeps runs from overlapping; a stale lock is taken over.
  local lock="$state_dir/sync.lock"
  if ! mkdir "$lock" 2>/dev/null; then
    local holder
    holder="$(cat "$lock/pid" 2>/dev/null || true)"
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
      echo "another sync (pid $holder) is running; exiting"
      return
    fi
    echo "taking over a stale lock"
  fi
  echo "$$" >"$lock/pid"
  # shellcheck disable=SC2064  # expand now: the path must not change later
  trap "rm -rf '$lock'" EXIT

  local build uuid relative failures=0
  # The manifest is read on descriptor 3 so that no command run in the loop can
  # consume the remaining lines from standard input.
  while IFS=$'\t' read -r build uuid relative <&3; do
    [ -n "$build" ] || continue
    # One runtime failing must not stop the others.
    if ! (sync_one "$build" "$uuid" "$relative"); then
      echo "$build: sync failed"
      failures=$((failures + 1))
    fi
  done 3<"$manifest"
  note "sync finished"
  [ "$failures" -eq 0 ] || exit 1
}

# eject: everything needed before unplugging, in one command. Detaches every
# runtime in the manifest and then ejects the volume(s) they live on.
#
# Unlike `detach`, this forces an unmount that is still refused after the
# retries: the user has said they are about to remove the disk, and pulling it
# with a runtime still mounted is worse than a forced unmount of an idle one.
cmd_eject() {
  [ -s "$manifest" ] || die "the manifest is empty; nothing to eject"
  local booted
  booted="$(booted_device_count)"
  [ "$booted" = "0" ] ||
    die "$booted simulator(s) are booted; quit Xcode's run or use: xcrun simctl shutdown all"

  local build uuid relative link volumes=""
  while IFS=$'\t' read -r build uuid relative <&3; do
    [ -n "$build" ] || continue
    link="$profiles_dir/offload-$build.simruntime"
    if mount | grep -qF " on $mount_root/$build ("; then
      (cmd_detach "$build" --force) ||
        die "could not detach $build; the disk is still in use — do not unplug it"
    elif [ -L "$link" ]; then
      note "Removing $link"
      run rm "$link"
    fi
    case " $volumes " in
      *" $uuid "*) ;;
      *) volumes="$volumes $uuid" ;;
    esac
  done 3<"$manifest"

  for uuid in $volumes; do
    if diskutil info "$uuid" 2>/dev/null | grep -q 'Mounted: *Yes'; then
      note "Ejecting volume $uuid"
      run diskutil eject "$uuid" ||
        die "the volume is still in use by something else — do not unplug it"
    fi
  done
  note "Done. The disk can be unplugged; plugging it back in re-attaches the runtimes."
}

# --- LaunchAgent ---------------------------------------------------------------
# A per-user agent, not a daemon: everything it does is unprivileged.
# StartOnMount makes launchd run it whenever any filesystem is mounted, so a
# volume that arrives after login is handled without polling.

cmd_agent() {
  local action="${1:-status}"
  local domain
  domain="gui/$(id -u)"
  case "$action" in
    install)
      mkdir -p "$state_dir" "$agent_log_dir" "$(dirname "$agent_plist")"
      config_set mount_root "$mount_root"
      config_set link_dir "$profiles_dir"
      [ -z "$SRO_VOLUME_UUID" ] || config_set volume_uuid "$SRO_VOLUME_UUID"
      # The agent runs a copy, so moving or editing the working tree cannot
      # change what launchd executes.
      cp "$0" "$agent_script"
      chmod 755 "$agent_script"
      # launchd must start our own executable rather than /bin/bash: a
      # background job's access to a removable volume is attributed to the job's
      # program, and for a platform binary it is refused without a prompt.
      local source_dir
      source_dir="$(cd "$(dirname "$0")" && pwd)"
      [ -f "$source_dir/agent/sro-agent.swift" ] || die "agent/sro-agent.swift not found next to $0"
      local source_sum
      source_sum="$(sha256_of "$source_dir/agent/sro-agent.swift")"
      if [ -x "$agent_binary" ] && [ "$(cat "$agent_binary.source-sha256" 2>/dev/null)" = "$source_sum" ]; then
        note "Agent launcher is up to date; keeping it (and its consent)"
      else
        note "Building the agent launcher"
        xcrun swiftc -O -o "$agent_binary" "$source_dir/agent/sro-agent.swift"
        codesign --force --sign - --identifier "$agent_label" "$agent_binary"
        printf '%s\n' "$source_sum" >"$agent_binary.source-sha256"
      fi
      cat >"$agent_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$agent_label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$agent_binary</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>SRO_MOUNT_ROOT</key>
    <string>$mount_root</string>
    <key>SRO_LINK_DIR</key>
    <string>$profiles_dir</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>StartOnMount</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>$agent_log_dir/agent.log</string>
  <key>StandardErrorPath</key>
  <string>$agent_log_dir/agent.log</string>
</dict>
</plist>
PLIST
      plutil -lint "$agent_plist" >/dev/null
      launchctl bootout "$domain/$agent_label" 2>/dev/null || true
      launchctl bootstrap "$domain" "$agent_plist"
      note "Installed $agent_label (log: $agent_log_dir/agent.log)"
      ;;
    uninstall)
      launchctl bootout "$domain/$agent_label" 2>/dev/null || true
      rm -f "$agent_plist" "$agent_script" "$agent_binary" "$agent_binary.source-sha256"
      note "Uninstalled $agent_label (manifest, mounts and links are untouched)"
      ;;
    status)
      if launchctl print "$domain/$agent_label" >/dev/null 2>&1; then
        launchctl print "$domain/$agent_label" | grep -E '^\s*(state|runs|last exit code) =' || true
      else
        echo "agent not loaded"
      fi
      if [ -f "$manifest" ]; then cat "$manifest"; else echo "(no manifest)"; fi
      ;;
    *) die "usage: sro.sh agent install|uninstall|status" ;;
  esac
}

case "${1:-}" in
  status) cmd_status ;;
  stage) shift; cmd_stage "$@" ;;
  attach) shift; cmd_attach "$@" ;;
  detach) shift; cmd_detach "$@" ;;
  enable) shift; cmd_enable "$@" ;;
  disable) shift; cmd_disable "$@" ;;
  sync) cmd_sync ;;
  eject) cmd_eject ;;
  agent) shift; cmd_agent "$@" ;;
  *)
    sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'
    exit 64
    ;;
esac
