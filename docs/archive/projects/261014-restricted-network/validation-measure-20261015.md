# 共享服务的验证结果

Validation: 105 Scheme assertions and 45 packet checks passed, including the
redroid profile, inherited LAN DNS, unrestricted interface selection and
empty-list egress denial.  Ruff checks passed and the generated Guix
provisioning program was built successfully.  Both generated entry points
also passed the isolated module-loading test.  No live system reconfiguration
was performed.

The VPN bypass has mock runtime tests (added once, refused when a foreign
rule holds the priority, absent by default, and capture detected with or
without it).  It was also run with real `ip` in a user/network namespace with
a simulated strongSwan table 220: before, the subnet resolved via table 220;
after two runs, through its bridge.
