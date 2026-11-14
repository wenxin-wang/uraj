# Arknights automation on redroid

## Deployment with redroid

### Design

hypie's installed system runs `redroid-maa` under Docker (not the live
installer); storie declares the same service as a manual standby (see below).
Guix declares the container and its dependencies; Shepherd manages its
lifecycle.
Android's `/data` is bind-mounted from
`/var/lib/redroid/data/maa-houdini-13` on the system disk.  Other Android instances must have separate names, data
directories and IP addresses.  Guix generation rollback does not roll back
Android data: stop the instance and back up its data before image upgrades.

Use the Intel HD 630 for rendering, not the GTX 1080.  Resolve the Intel
render device by PCI identity rather than assuming `renderD128`.  The host
kernel must support Binder; use memfd instead of the removed ashmem driver.

### Networking

Production addressing (checked against current IPv4 routing tables on start):

| Object | Value |
|---|---|
| Docker net | redroid |
| Host bridge | br-redroid |
| Subnet | 10.203.0.0/24 |
| Gateway | 10.203.0.1 |
| redroid-maa | 10.203.0.2:5555 |

These are defaults in `(uraj services redroid)`.  If a LAN or VPN overlaps,
change the network's subnet/gateway and the instance address together.

Use a dedicated Docker bridge with an independent network namespace for
Android.  Do not use host networking: Android manages routes and networking
inside its namespace, and its ADB daemon must not listen on the host's LAN
interfaces.  Do not publish container ports.

Guix's shared [restricted-network service](../restricted-network/networks-guide.md) owns IPv4 forwarding and
nftables tables for egress masquerading and filtering.  Docker's automatic
iptables/ip6tables, IP forwarding and userland proxy management are disabled.
The default Docker bridge is disabled; the redroid network is explicitly
provisioned.  Rules must not flush or replace unrelated host/VPN rules.
Unsolicited forwarding into redroid is blocked; the host can connect
directly to the instance's private IP.  The private subnet must not overlap
the host's LAN or VPN routes.  Wi-Fi and Ethernet use the same routed design.

hypie sets `vpn-bypass-priority` to 200 because fwd2home is a full tunnel
that would otherwise capture the bridge subnet (see
[the VPN bypass](../restricted-network/networks-guide.md#lifecycle-and-migration)).
Reconfiguration does not restart the running service; apply such changes
with `sudo herd restart restricted-network`, then start the dependent
redroid instance again.

Only `inet restricted_network` and `ip restricted_network` are replaced,
atomically.  Stopping the network services retains protection; it never
deletes other instances' network.  Unrelated firewall tables are retained.
An existing host firewall can still reject forwarding: its policy must also
permit the intended traffic.  Containers may initiate public TCP/UDP
connections, but cannot access LAN/VPN/private destinations or host services.
DNS on TCP/UDP 53 is restricted to the configured resolver.  Host-started
ADB connections and their replies are allowed.  Containers on the same bridge
are not isolated from one another at layer 2; only trusted Android instances
should share it.

The `network` field of `redroid-configuration` holds a `restricted-network`
record, defaulting to `%redroid-network`.  The redroid service contributes
this record directly to `restricted-network-service-type`.

```scheme
(service restricted-network-service-type)
(service redroid-service-type
  (redroid-configuration
    (network
     (restricted-network
       (inherit %redroid-network)
       (egress-interfaces #t)))
    (auto-start? #f)))
```

Set the embedded network's `egress-interfaces` to `#t` or the actual uplink
list; the empty default permits no new outbound traffic.  Public LAN/VPN
prefixes and public addresses that hairpin to private services must be added
to the policy's `blocked-destinations`.  The container network name comes
from the same record.  Docker's `--dns` options and Android's numbered DNS
boot arguments both use its policy's `dns-servers` list, which defaults to
`'("114.114.114.114")`.  Redroid requires an explicit nonempty IPv4 list: `host`
snapshots are unavailable when its Android boot arguments are generated.
Egress follows the host's forwarding/routing policy; host-only proxy settings
are not automatically used by Android.  Split-tunnel VPN behavior needs
device testing.

### Control plane

`maa-cli`, MaaCore and adb run outside Android under a separate scheduled
job at 02:00, 05:00, 11:00, 14:00 and 21:00 Asia/Shanghai. They connect to the
private Android IP on port 5555. The game must already be manually logged in.
Changing the controller to mower later does not require replacing Android
or its persistent data.

### Implementation and first deployment

- `src/guix/uraj/services/redroid.scm`: Docker settings, public-only network
  policy contribution and Android instance service.
- `src/guix/uraj/build/redroid.scm`: Android runtime checks.
- `env/guix/os/hypie.scm`: Docker, `restricted-network-service-type` (with
  the fwd2home bypass) and the redroid service, any egress interface.
- `env/guix/os/storie.scm`: the redroid service as a standby
  (`auto-start? #f`), next to storie's own networks.

The production container starts automatically under Shepherd.  Its own
Shepherd service, rather than Guix's OCI service, prepares every `docker run`:
it waits for dockerd to answer, builds the layered image if needed, and
removes a container still named `redroid-maa`; stop waits for the removal.

The layered image is built from the official Android 13 amd64 base, pinned to
`sha256:524987f1fc489f6018e2c9d0dd622e5eccea13eb896417cb4bfb26bc3fea9afd`
(`redroid/redroid:13.0.0-latest`, checked 2026-10-17).
A `uraj.context` store-path label rebuilds it when either payload or recipe
changes. Build steps have no network access; Docker may fetch the pinned
base before executing them.

### ARM translation

hypie selects `redroid-houdini` and `native-bridge-library "libhoudini.so"`.
The package pins the Android 13 payload selected by waydroid_script at
[commit 2f8f088](https://github.com/supremegamers/vendor_intel_proprietary_houdini/commit/2f8f088671182e17e67321e098e8411a3972a628),
HPE UKW1.260829.001 / Houdini 14.0.0 GoogleGame com1.3. The archive is
SHA-256 checked, and the binaries are neither patched nor stripped.
The expected 64-bit library hash is
`5ef64035ec89bca3d5e33b9f3b6556f98f6c11d11957387d403ae4a4d7cc40ec`.

The package installs the native bridge and its ARM guest libraries. It omits
ARM executable runners and binfmt_misc registration, which would affect the
host and is not required for app native-library translation. Explicit boot
properties select Houdini, ARM ABIs and their x86 mappings. The base image's
NDK translation libraries, guest trees, linker configurations and init script
are removed before copying Houdini into the image. A Guix-built static
BusyBox performs this build step: Android's own shell cannot run before APEX
is mounted.
The temporary BusyBox and preparation script are then removed.

Houdini requires the default system linker namespace to permit
`/system/${LIB}/arm64` and `/system/${LIB}/arm`. An init service adds these
paths at the end of the generated `[system]` section, idempotently. The
image build inserts it before both explicit `start zygote` and
`class_start main`; official redroid leaves `ro.crypto.state` unset and uses
the latter path. Init waits for `uraj.houdini.linker.ready` to become `1`.
A missing/duplicate system section or failed helper leaves zygote blocked
for diagnosis instead of silently booting without the correction.

### Host checks

Verified on hypie: login and the MAA daily tasks; battle was tested once
(TR-1 loading), on the Codysk Android 13 base only.

Before first use, on hypie:

```sh
grep binder /proc/filesystems
ls -l /dev/dri/by-path/pci-0000:00:02.0-render
ip -4 route show table all
```

The kernel must provide Binder and binderfs (`grep binder /proc/filesystems`;
load `binder_linux` if it is a module).  No Binder DKMS module or ashmem
driver is installed by this service.
The Intel device is bind-mounted at `/dev/dri/intel-render` inside Android.
The container is privileged, as in the upstream deployment recipe.  The
`modprobe` sysctl is global: Android's `init.rc` sets it to an empty string at
early-init, which disables module autoloading on the host too (upstream
[issue #932](https://github.com/remote-android/redroid-doc/issues/932)).
The service therefore loads the host's `fuse` module, which Android needs,
at boot.

A small statically linked entrypoint therefore binds a copy of
`/system/etc/init/hw/init.rc` without that `write`, read-only, then executes
`/init androidboot.hardware=redroid ...`.  If the image has no such command,
or any step fails, Android is not started.  The entrypoint also bind-mounts
`/proc/sys/kernel/modprobe` read-only, but this alone is not enough: Android 13's
first-stage init mounts a new procfs over `/proc`, hiding it.  OCI mounts at
that `/proc` path are rejected by runc, hence the entrypoint.
The helper is built from `src/guix/uraj/packages/aux-files/redroid-init.c`.
It avoids depending on Android's shell/APEX libraries before init has run.

Deploy with the commands in the [deploy guide](../guix/deploy-guide.md),
then:

```sh
sudo herd start redroid-maa
sudo herd status redroid-maa
sudo docker logs --tail 100 redroid-maa
sudo docker network inspect redroid
sudo nft list table inet restricted_network
sudo nft list table ip restricted_network
```

Install/use `adb` and `scrcpy` as client-side tools for manual checks:

```sh
guix shell adb scrcpy
adb connect 10.203.0.2:5555
adb -s 10.203.0.2:5555 shell getprop sys.boot_completed
adb -s 10.203.0.2:5555 shell dumpsys SurfaceFlinger
scrcpy -s 10.203.0.2:5555
adb -s 10.203.0.2:5555 install /path/to/arknights.apk
```

Require boot completion `1`, Intel/Mesa hardware rendering rather than a
software renderer, working DNS and game login, and intact host networking.
Compare the host `/proc/sys/kernel/modprobe` before and after starting the
container; it must stay the Guix modprobe wrapper, never empty.

```sh
oci-digest docker.io/redroid/redroid:13.0.0-latest   # tag moved upstream?
sudo docker images --digests redroid/redroid          # on hypie
```

For remote scrcpy, tunnel ADB through SSH instead of exposing it on the LAN:
`remote-maa` (`env/dotfiles/desktop/apps/.local/bin`) runs on another machine
that can SSH to hypie (or another host set by `REMOTE_MAA_HOST`); `adb` and
`scrcpy` come from the desktop home profile (scrcpy from the small-guix
channel, since Guix lacks it).

```sh
remote-maa login                     # scrcpy: log in to the game once
remote-maa install arknights.apk     # install or update from a local APK
remote-maa upgrade                   # download the official APK, install it
remote-maa status                    # boot state and game version
remote-maa adb shell ...             # anything else
remote-maa connect                   # keep the forward open for other tools
remote-maa hack-fsync                # fsync off in Android (restarts it)
remote-maa hack-fsync 0              # fsync back, then sync the host
```

The game's resource download calls fsync after every 8 KiB write.  On
storie's Btrfs each takes 5–17 ms, capping the download at 1–4 MB/s with
11–20 times write amplification; without it the download reached about
20 MB/s, limited by CPU.  `hack-fsync` preloads a libc-free shim into
zygote, from which every app forks: a wrapper bind-mounted over
`/system/bin/app_process64` sets `LD_PRELOAD`, then zygote restarts.  This
also closes the game.  `install` and `upgrade` turn it on for the
installation unless it already is.

While it is on, a host crash can lose or corrupt Android's recent writes;
`sync` on the host still flushes them.  The anti-cheat may notice the
library in the game's mappings, with unknown consequences.  Recreating the
container also removes the shim.  A file system with cheap fsync for the
game's data would avoid both risks, but is not implemented.

MAA's StartUp task neither installs the game nor enters credentials, and can
only switch between accounts that are already logged in, so the first login
is manual.  The session persists in the data directory.

### storie standby

storie (Celeron J6412, UHD Gen11, 15 GiB) carries the same redroid and MAA
services as a manual standby, with `auto-start? #f` for `redroid-maa`.
Every host's scheduled run first tries a TCP connection to the instance's
ADB port, and skips the run (exit 0, one line in mcron's log) unless it
connects within 5 s.  `sudo herd start redroid-maa` on storie takes over;
`sudo herd stop redroid-maa` hands back to hypie and stays stopped across
reboots.  Stop it before hypie returns: two clients on one account log each
other out.

Its Android data is a fresh directory, not a copy of hypie's: log in and
download the game resources once, with
`REMOTE_MAA_HOST=storie.home.labbies.wenxinwang.me remote-maa login`.  The
redroid network reuses `10.203.0.0/24`; storie's `static-agent` network is
`10.204.0.0/24`.  Restarting `restricted-network` also restarts its
dependents, such as openclaw.  The CPU is roughly half of hypie's i5-7500.

### References

- [redroid deployment and boot parameters](https://github.com/remote-android/redroid-doc)
- [Docker firewall behavior](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
- [maa-cli](https://github.com/MaaAssistantArknights/maa-cli)
