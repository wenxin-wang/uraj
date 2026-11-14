# 启用 PAM 登录和旧条目的迁移

This PAM change needs a **system** reconfigure and a fresh greetd login; Home
reconfigure alone cannot install it or recover a password from a past login.
An existing keyring labelled `default` is preserved.  Merely giving it the
same password as the account does not make it the PAM `login` keyring.  After
the first PAM-enabled login, unlock that existing keyring and select
"Automatically unlock this on login" if offered: its password is then stored
in the unlocked `login` keyring.  Alternatively use Seahorse to make `Login`
the default and save SSH passwords there again.  Changing the default does
not move existing entries, and no keyring files need to be deleted or renamed.

Home disables the old `gnome-keyring-ssh.desktop` autostart and masks
`gcr-ssh-agent.socket` / `gcr-ssh-agent.service`.  An existing custom unit at
either mask path causes activation to fail rather than overwrite it.  These
masks are activation-created; removing the Home service later does not remove
them automatically (use `systemctl --user unmask` when intentionally reverting).
The foreign niri-session wrapper reloads the user manager and stops GCR's SSH
units, leaving the host password daemon running.  It also replaces inherited
GCR/Keyring SSH socket paths with the existing gpg-agent socket.  Other agent
socket paths, including forwarded agents, are preserved.

Reconfigure Home and update the foreign-desktop `keyring,session` tasks, then
log out and back in.  Home activation alone does not stop an already running
SSH component inside an older host keyring daemon.  Do not kill the password
daemon merely to switch askpass: it may hold the unlocked login keyring.

Old GCR/keyring SSH entries use different attributes from QtKeychain, so expect
to enter and save each SSH password once again.  Existing keyring files are
not deleted or migrated.  QtKeychain 0.15 uses `user` (key path), `server`
(`ksshaskpass`) and `type` (`plaintext`, meaning text rather than binary data).
The latter is an item format, not a request to store the keyring unencrypted.
