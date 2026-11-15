#!/bin/sh
# Cost of putting a repo into a box by reflink: does the filesystem support
# it, how long does the copy take, how much new space does it use?
#
#   reflink.sh [REPO] [DEST_PARENT]
#
# REPO defaults to ~/src/uraj; DEST_PARENT defaults to
# ~/.local/share/contained-agent, where box state would live.  The copy is
# removed at the end.  `btrfs filesystem du` needs no root on btrfs.
set -eu

repo=${1:-$HOME/src/uraj}
parent=${2:-$HOME/.local/share/contained-agent}
dest=$parent/reflink-probe-$$
mkdir -p "$parent"
trap 'rm -rf "$dest"' EXIT

for p in "$repo" "$parent"; do
  printf '%-50s ' "$p"
  findmnt -no FSTYPE,SOURCE -T "$p"
done
same=no
[ "$(stat -c %d "$repo")" = "$(stat -c %d "$parent")" ] && same=yes
echo "same filesystem: $same"

echo "files: $(find "$repo" | wc -l), apparent size: $(du -sh --apparent-size "$repo" | cut -f1)"
echo "of which .git: $(du -sh --apparent-size "$repo/.git" | cut -f1)"

if cp -a --reflink=always "$repo/.git/HEAD" "$parent/.reflink-test-$$" 2>/dev/null
then
  rm -f "$parent/.reflink-test-$$"
  echo "reflink: supported"
  mode=always
else
  echo "reflink: NOT supported here; measuring a full copy"
  mode=never
fi

sync
start=$(date +%s.%N)
cp -a --reflink=$mode "$repo" "$dest"
end=$(date +%s.%N)
echo "copy time: $(awk "BEGIN{printf \"%.2f\", $end - $start}") s (cold/warm cache not controlled)"

if command -v btrfs >/dev/null; then
  btrfs filesystem du -s "$repo" "$dest" 2>/dev/null \
    || echo "btrfs filesystem du failed"
fi
start=$(date +%s.%N)
git -C "$dest" status --short >/dev/null
end=$(date +%s.%N)
echo "first git status in the copy: $(awk "BEGIN{printf \"%.2f\", $end - $start}") s (index stat cache is invalidated)"
