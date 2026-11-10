#!/bin/bash
# Collects a read-only diagnostic baseline of the Simulator runtime storage
# configuration. Nothing here modifies system state.
#
# Usage: scripts/collect-baseline.sh <output-dir> [external-volume-mount-point]
#
# Output is sanitised: the user name, home directory, host name and hardware
# serial numbers are redacted. Volume and image UUIDs are kept because they are
# the stable identifiers the project relies on.

set -u

out="${1:?usage: collect-baseline.sh <output-dir> [external-volume-mount-point]}"
ext="${2:-}"
mkdir -p "$out"

user_name="$(id -un)"
host_short="$(hostname -s 2>/dev/null || echo unknown-host)"
host_full="$(hostname 2>/dev/null || echo unknown-host)"

sanitise() {
  sed -E \
    -e "s#${HOME}#~#g" \
    -e "s#/Users/${user_name}#~#g" \
    -e "s#${host_full}#<host>#g" \
    -e "s#${host_short}#<host>#g" \
    -e "s#[[:<:]]${user_name}[[:>:]]#<user>#g" \
    -e 's#(Serial Number[^:]*: *).*#\1<redacted>#' \
    -e 's#("?kUSBSerialNumberString"?[ =]+")[^"]*#\1<redacted>#g' \
    -e 's#("?USB Serial Number"?[ =]+")[^"]*#\1<redacted>#g'
}

# capture <file> <command...>: record the command line and its sanitised output.
capture() {
  local file="$out/$1"
  shift
  {
    printf '$ %s\n' "$*"
    "$@" 2>&1
    printf '\n[exit status: %s]\n' "$?"
  } | sanitise >"$file"
}

capture_sh() {
  local file="$out/$1"
  shift
  {
    printf '$ %s\n' "$1"
    /bin/bash -c "$1" 2>&1
    printf '\n[exit status: %s]\n' "$?"
  } | sanitise >"$file"
}

cs_root=/Library/Developer/CoreSimulator
cs_fw=/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A

# --- Versions ---------------------------------------------------------------
capture_sh versions.txt '
sw_vers
uname -srm
sysctl -n machdep.cpu.brand_string
xcode-select -p
xcodebuild -version
printf "CoreSimulator.framework: "
defaults read '"$cs_fw"'/Resources/Info.plist CFBundleVersion
csrutil status'

# --- Runtimes and devices ----------------------------------------------------
capture runtimes-disk-images.txt xcrun simctl runtime list -v
capture runtimes.txt xcrun simctl list runtimes -v
capture runtime-match.txt xcrun simctl runtime match list
# Device names are user-chosen and may reveal project names, so only the
# identifier and state are kept.
capture_sh devices.txt 'xcrun simctl list devices | sed -E "s/^(    ).*( \\([0-9A-F-]{36}\\) \\(.*)$/\\1<device name>\\2/"'

# --- Storage layout ----------------------------------------------------------
capture_sh coresimulator-system-tree.txt '
ls -laO@ '"$cs_root"'
for d in Images Images/mnt Images/Inbox Volumes Cryptex Cryptex/Images Cryptex/Personalization Caches Caches/dyld Profiles; do
  echo; echo "## '"$cs_root"'/$d"; ls -laO '"$cs_root"'/$d
done
echo; echo "## images.plist"; plutil -p '"$cs_root"'/Images/images.plist'

capture_sh mobileasset-runtime-assets.txt '
for t in iOS appleTVOS watchOS xrOS; do
  d=/System/Library/AssetsV2/com_apple_MobileAsset_${t}SimulatorRuntime
  [ -d "$d" ] || continue
  echo "## $d"; ls -laO "$d"
  for a in "$d"/*.asset; do
    [ -d "$a" ] || continue
    echo; echo "### $a"
    plutil -p "$a/Info.plist"
    ls -laRO "$a/AssetData"
    du -sh "$a"
  done
done'

capture_sh coresimulator-user-tree.txt '
ls -la ~/Library/Developer/CoreSimulator
du -sh ~/Library/Developer/CoreSimulator/* 2>/dev/null
ls -la ~/Library/Developer/CoreSimulator/Profiles 2>&1
defaults read com.apple.CoreSimulator 2>&1'

capture_sh protection.txt '
echo "## SIP rootless entries"
grep -n -E "AssetsV2|CoreSimulator" /System/Library/Sandbox/rootless.conf
echo; echo "## firmlinks"
grep -n -E "AssetsV2|^/Library" /usr/share/firmlinks
echo; echo "## flags and extended attributes"
ls -ldO@ /Library/Developer '"$cs_root"' '"$cs_root"'/Images '"$cs_root"'/Volumes '"$cs_root"'/Cryptex /System/Library/AssetsV2
echo; echo "## device numbers (same number = same volume)"
stat -f "%d %N" / /System/Volumes/Data '"$cs_root"' /System/Library/AssetsV2 ~/Library/Developer/CoreSimulator'

# --- Disks --------------------------------------------------------------------
capture disks.txt diskutil list
# nullfs mounts are per-app wrappers unrelated to this project and can reveal
# which applications are installed.
capture_sh mounts.txt 'mount | grep -v "(nullfs"'
capture_sh free-space.txt 'df -h | grep -v "\.app/"'
capture apfs.txt diskutil apfs list

if [ -n "$ext" ]; then
  capture external-volume.txt diskutil info "$ext"
  whole="$(diskutil info "$ext" 2>/dev/null | awk -F': *' '/APFS Physical Store/ {print $2}' | sed -E 's/s[0-9]+$//')"
  if [ -n "$whole" ]; then
    capture external-disk.txt diskutil info "$whole"
  fi
fi

# --- Responsible processes and services ---------------------------------------
capture_sh services.txt '
echo "## processes"
ps axo pid,ppid,user,comm | grep -E "simdiskimaged|CoreSimulator|cryptexd|mobileassetd|diskarbitrationd|diskimagesiod" | grep -v grep
echo; echo "## launchd: simdiskimaged"
launchctl print system/com.apple.CoreSimulator.simdiskimaged 2>&1 | sed -n "1,20p"
echo; echo "## entitlements: simdiskimaged"
codesign -d --entitlements - '"$cs_fw"'/Resources/bin/simdiskimaged 2>&1
echo; echo "## entitlements: CoreSimulatorService"
codesign -d --entitlements - '"$cs_fw"'/XPCServices/com.apple.CoreSimulator.CoreSimulatorService.xpc 2>&1'

echo "Baseline written to $out"
ls -1 "$out"
