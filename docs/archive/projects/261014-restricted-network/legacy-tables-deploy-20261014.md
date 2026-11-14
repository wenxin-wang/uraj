# 从旧的 uraj_redroid 表迁移

When migrating redroid, the old `inet uraj_redroid` and `ip uraj_redroid_nat`
tables are not silently deleted.  Apply the new protection first, then remove
those exact legacy tables during a stopped-workload maintenance window, or
reboot into the new system configuration.  Keep unrelated tables intact.
The shared service manages only `restricted_network`.
