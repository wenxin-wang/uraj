# SSH askpass and GNOME Keyring

## Components

The desktop installs `ksshaskpass-with-qtkeychain` from `(uraj packages ssh)`.
It backports upstream commit
[46c7a429: Switch from KWallet to QtKeychain](https://invent.kde.org/plasma/ksshaskpass/-/commit/46c7a4294babcfed9f0db064e407416b8bfb5b47) onto Guix's ksshaskpass;
drop it when Guix ships a release with QtKeychain.
The patch adapts context and omits an identifier rename in a newer prompt
parser absent from 6.5.5.  It adds no local password-handling implementation.

The UI remains KDE/Qt.  QtKeychain uses libsecret in niri, so passwords are
stored in the session's GNOME Keyring rather than KWallet.  KDE sessions still
prefer KWallet; do not advertise a niri session as KDE through environment
variables.  Neither askpass nor this configuration launches a GNOME SSH agent.

`ssh-add -h` still decrypts keys on the host and loads the existing restricted
OpenSSH agent.  The coding-agent container receives that restricted socket,
not the host Secret Service bus or the password database.  GPG/card keys and
the existing gpg-agent configuration are independent of this password store.

## Foreign distro and Guix System

On foreign distros, retain the host `gnome-keyring-daemon`, its systemd units,
PAM integration and password files.  The foreign-desktop playbook installs
`gnome-keyring` and `libpam-gnome-keyring` on Debian-family hosts.  The Home
profile deliberately does not install a competing Guix GNOME Keyring daemon.
The host must expose `org.freedesktop.secrets` on the same user session bus
as askpass.  Installing the PAM package does not guarantee that a custom
display manager's PAM stack is configured; standard GDM integration is the
intended host setup.  Autologin/fingerprint login may still require unlocking
the keyring at first use.

On Guix System, the Home profile supplies GNOME Keyring and its GCR prompter.
The desktop's greetd PAM stack unlocks (or creates) the `login` keyring using
the login password; `passwd` updates that keyring's password alongside the
account password.  Both use optional PAM entries, so a keyring failure does
not reject a valid login.  A Home Shepherd initialization action runs
`gnome-keyring-daemon --start --components=secrets` after the graphical session
and its bus are ready.  This completes startup of the PAM-unlocked daemon
before its initialization timeout; it does not launch a separate SSH agent.
D-Bus activation remains available when PAM was not involved, with an unlock
prompt on first use.  Passwordless/autologin sessions cannot supply a login
password for automatic unlocking.

This PAM change needs a **system** reconfigure and a fresh greetd login.
An existing keyring labelled `default` is not the PAM `login` keyring: unlock
it once and select "Automatically unlock this on login" if offered, or use
Seahorse to make `Login` the default and save SSH passwords there again.

Home disables the old `gnome-keyring-ssh.desktop` autostart and masks
`gcr-ssh-agent.socket` / `gcr-ssh-agent.service`; an existing custom unit at
either mask path makes activation fail rather than be overwritten.  The masks
are activation-created and not removed with the Home service (`systemctl
--user unmask` reverts them).  The foreign niri-session wrapper stops GCR's SSH
units, leaving the host password daemon running, and replaces inherited
GCR/Keyring SSH socket paths with the existing gpg-agent socket; other agent
socket paths, including forwarded agents, are preserved.  Do not kill the
password daemon to switch askpass: it may hold the unlocked login keyring.

## Passwords and normal use

`SSH_ASKPASS` continues to resolve `ksshaskpass` from the Guix Home profile.
OpenSSH normally prefers a terminal when one is available.  To save a key's
password from a graphical host terminal, explicitly use askpass:

```sh
SSH_ASKPASS_REQUIRE=force contained-agent ssh-start /absolute/project/path
```

Choose the remember-password option in the dialog.  This reloads the project's
configured identities (or the shared broker agent, when selected by existing
policy); it does not broaden their destination constraints.  A restarted
broker needs the new Home environment and the same session D-Bus address.
Headless sessions still need an unlocked password store or an interactive
unlock elsewhere; no password is collected through Paseo.

### GitHub CLI from SSH

`gh auth setup-git` configures Git to ask `gh` for HTTPS credentials.  When
the token is in GNOME Keyring, `gh` also needs the desktop's session bus.
Without it, `gh auth status` can report an invalid token from `default`
even though the same account works in the desktop session.

The desktop Home profile's `65-session-bus.sh` fills an unset
`DBUS_SESSION_BUS_ADDRESS` in SSH login shells.  It first checks the usual
`$XDG_RUNTIME_DIR/bus` socket, then the bus address of the same user's
running niri process: Guix System uses `dbus-run-session` with a different
socket path.  Existing bus addresses are preserved.  This neither starts
a keyring nor unlocks one, and requires an existing desktop/user bus and
an accessible, unlocked keyring.

Old GCR/keyring SSH entries use different attributes from QtKeychain, so each
SSH password is saved again once.  QtKeychain 0.15 stores `user` (key path),
`server` (`ksshaskpass`) and `type` (`plaintext`: an item format, not an
unencrypted keyring).

## Validation

Build the backport:

```sh
guix build -L src/guix -L src/guile --no-grafts \
  -e '(@ (uraj packages ssh) ksshaskpass-with-qtkeychain)'
```

With that package plus `python`, `gnome-keyring`, `libsecret`, `dbus` and
`openssh` on PATH, run `python3 test/python/uraj/guix/keyring/askpass.py`.  It
uses a private HOME, session bus and password daemon, and checks password
lookup and `ssh-add -h` constraints, not the visible dialog or a real login.
