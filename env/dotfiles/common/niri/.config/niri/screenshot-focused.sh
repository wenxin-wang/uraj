#!/bin/sh
# Annotate the focused output: grim captures it to ~/Pictures/Screenshots,
# then swappy opens the file for annotation. In swappy: Ctrl+S saves,
# Ctrl+C copies to the clipboard, Esc quits without saving.
out=$(niri msg -j workspaces | python3 -c 'import json, sys
ws = json.load(sys.stdin)
print(next((w["output"] for w in ws if w["is_focused"]), ""))')
[ -n "$out" ] || exit 1
dir="$HOME/Pictures/Screenshots"
mkdir -p "$dir"
file="$dir/$(date +%Y%m%d-%H%M%S).png"
grim -o "$out" "$file" || exit 1
exec swappy -f "$file"
