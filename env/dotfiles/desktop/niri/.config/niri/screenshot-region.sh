#!/bin/sh
# Interactive region selection via niri's screenshot UI, then open the
# result in swappy for annotation. The saved path comes from niri's
# ScreenshotCaptured IPC event; cancelling the UI (Esc) produces no event.
dir="$HOME/Pictures/Screenshots"
mkdir -p "$dir"

tmp=$(mktemp)
niri msg event-stream > "$tmp" 2>/dev/null &
sub=$!
sleep 0.5
niri msg action screenshot

# Give the user up to ~60s to draw the region.
i=0
while ! grep -q "Screenshot captured:" "$tmp" && [ "$i" -lt 200 ]; do
    sleep 0.3
    i=$((i + 1))
done
kill "$sub" 2>/dev/null
file=$(grep -m1 "Screenshot captured:" "$tmp" | sed -n 's/.*saved to \(.*\)$/\1/p')
rm -f "$tmp"
[ -n "$file" ] && exec swappy -f "$file"
