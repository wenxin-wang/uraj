# NFS 局域网共享

已完成的历史项目，按 `git log` 重建；时间线以提交日期为准，没有提交可查的事实
写“未确认”。

## 目标

storie 把 `/core-data` 和 `/media-data` 以 NFS 导出给家里的局域网；lappie 和
hypie 按需自动挂载，路径和 storie 上一致。现状见
[storie-network-guide](../../../guix/storie-network-guide.md)。

## 背景

- 旧的 NFS 服务跑在容器里（`storie.scm` 的注释写 container 100、172.31.255.6）；
  Guix System 上改为宿主直接提供。
- 家里的 IPv6 前缀是动态的，所以只授权 IPv4 源网段。

## 主要决定

- 10/21：放行当前家里局域网的 NFS 访问；lappie、hypie 用 Guix 的 `autofs`
  按需挂载（dd11354，#39）。同日检查了顶层目录属主，见
  [nfs-measure-20261021](nfs-measure-20261021.md)。
- 10/25：autofs 条目的 fstype 用 `nfs4`，把 `nfs-utils` 放进系统 profile 以提供
  `mount.nfs4`；改成直接挂载，客户端和 storie 路径一致（cb73982，#50）。
- 10/28：沙箱可以访问 autofs 挂载（01ab745，#58：沙箱和后到的挂载）。

## 待定

无。

## 文档

- [TODO](TODO.md)：进度。
- [nfs-measure-20261021](nfs-measure-20261021.md)：顶层目录属主的检查记录。
