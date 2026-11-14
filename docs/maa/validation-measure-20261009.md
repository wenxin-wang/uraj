# MAA validation status

## Validation status

The network implementation now uses the shared restricted-network service;
see [its tests and migration instructions](../restricted-network/networks-guide.md).  The following records describe
the earlier redroid-specific implementation and are historical, not proof of
the new policy's deployment on hypie.

The service graph and subnet/network drift checks have automated tests:

```sh
guix repl -L src/guix -L src/guile test/guix/uraj/services/redroid.scm
guix repl -L src/guix test/guix/uraj/build/redroid.scm
```

The nftables rules were also loaded twice in an isolated user/network
namespace: syntax and repeated application passed, and an unrelated table
survived.  This does not yet verify forwarding packets or Android networking.
The static entrypoint compiled with warnings treated as errors.  In an
isolated user/mount namespace it successfully bind-mounted the modprobe
sysctl read-only (confirmed in mountinfo) and reached `exec /init`; the test
namespace intentionally has no Android init.  It preserves procfs mount
safety flags.  These early validation records predate the current Android 13 deployment;
see the runtime evidence above for the current scope.

On 2026-10-09, SSH to `wenxin@hypie.home.labbies.wenxinwang.me` confirmed
Guix System with kernel `7.2.6`, binderfs, and Intel's render device at
`pci-0000:00:02.0-render -> renderD128`.  The `10.203.0.0/24` subnet does not
overlap the observed LAN, local or VPN routes.  The host has roughly 205 GiB
free on the system disk and a running Guix daemon.  `wenxin` needs a sudo
password, but the configured `guix-deploy` account accepts the same SSH key
and its documented passwordless Guix/Guile deployment entrypoints work.
A clean repository snapshot plus only the redroid changes
is staged at `/tmp/uraj-redroid-20261009` for a build before activation.
