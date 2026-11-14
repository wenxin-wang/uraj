# lappie 从旧系统服务迁到 Home 服务

以下段落原在 [daemon-guide](../../../paseo/daemon-guide.md) 的 Layout 一节，2026-10-09 随 272f58d 写入，原文未改。

When migrating lappie, stop the old system `paseo` and `paseo-broker` (and any
manually started daemon) before starting their Home replacements. Reconfigure
the system, then log out and back into niri to load the new Home services and
session environment. Do not run both service owners against the same state.
