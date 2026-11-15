#!/bin/bash
# End-to-end test of the privileged mount path using a throwaway 64 MB NTFS image.
# Safe: never touches real disks. Prompts once for your sudo password.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/.build/debug/ntfsmac"; [ -x "$CLI" ] || { (cd "$ROOT" && swift build); }
IMG="$(mktemp -d)/selftest.ntfs"
truncate -s 64m "$IMG"
"$ROOT/build/prefix/sbin/mkntfs" -F -Q -L NTFSSELFTEST "$IMG" >/dev/null
DEV="$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$IMG" 2>/dev/null | awk 'NR==1{print $1}')"
ID="$(basename "$DEV")"
cleanup() { sudo "$CLI" unmount "$ID" >/dev/null 2>&1 || true; diskutil eject "$DEV" >/dev/null 2>&1 || true; rm -f "$IMG"; }
trap cleanup EXIT
echo "image attached as $DEV"
"$CLI" list
MP="$(sudo "$CLI" mount "$ID" | sed 's/.*at //')"
echo "mounted at: $MP"
echo "hello" > "$MP/test.txt" && mkdir "$MP/folder" && cp /etc/hosts "$MP/folder/hosts"
[ "$(cat "$MP/test.txt")" = "hello" ] && echo "write/read OK (as your user, not root)"
ls -ld "$MP/test.txt"
sudo "$CLI" unmount "$ID"
echo "PASS"
