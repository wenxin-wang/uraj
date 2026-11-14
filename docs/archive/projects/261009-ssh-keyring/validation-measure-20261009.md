# 验证记录

The tests use a private temporary HOME, session bus and password daemon.  They
exercise both direct unlocking and PAM-style `--login` followed by the
session's `--start --components=secrets`.  Each test
stores a disposable password with Secret Service, reads it using the actual
askpass binary, loads an encrypted SSH key with `ssh-add -h`, and verifies that
an unbound signing request is refused.  Qt's offscreen backend avoids touching
the desktop.  This validates password lookup and key constraints, not the
visible save/cancel dialog or an actual host login.  The desktop configuration
tests additionally check the generated greetd/passwd PAM entries, their
optional control flags and the Home initialization service.
