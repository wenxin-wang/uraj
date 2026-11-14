# dashboard 的 viewport 和 launcher 更新

With headed Chromium, agent-browser 0.38.2 can report a 1280 x 720 viewport
while streaming a shorter content area. This shifts mouse coordinates even
though the page is visible. Before handing over, the skill reads
`browser-profile run TASK eval '[innerWidth, innerHeight]'` and applies those
values with `browser-profile run TASK set viewport WIDTH HEIGHT` to synchronize
the dashboard without changing the page's current desktop layout. For a host
login session, use `browser-profile identity` instead of `run TASK`.

The updated launchers also remove browser launch defaults from the dashboard
process. In 0.38.2, those defaults can make menu commands such as Fit reopen a
managed browser without its profile. Restart a dashboard created by the old
launcher after updating; existing browser sessions can stay open. Once started
with the corrected environment, the bottom-right dimensions menu's `Fit` also
repairs the coordinate mismatch by resizing the page to the available area.

`browser-profile dashboard stop` stops the dashboard without closing the
browsers. On the host, the same commands view the host's login identity and
tasks, using the host wrapper's separate daemon directory. For an older Guix
installation, the skill describes starting the native executable with the
three launch defaults unset; the old launcher would reinsert the executable
default.
