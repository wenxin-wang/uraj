# 运行中给盒子加设备实测（2026-11-15）

TODO 第 9 步。问题：设备作为权限集，能不能在盒子运行中由用户级的盒子管理服务加上、
撤掉，盒子里的进程能不能用，agent 自己能不能造设备。

## 做法

在 lappie 上以普通用户运行 `exp/contained-agent-v2-grants_20261115/devices.sh`：

- 经 `contained-podman` 主机服务起一个小盒子（catatonit、uid 1000、keep-id），用
  crun 的 annotation `run.oci.keep_original_groups=1` 保留主机用户的附加组。
  `--group-add keep-groups` 经远程 API 不支持，会直接报错。
- 用 `nsmount.py`（和 [grants-measure-20261115](grants-measure-20261115.md) 同一个
  挂载方法，目标不存在时建一个空文件）把 `/dev/kvm` 和 `/dev/dri/renderD128` 挂进
  运行中的盒子。
- 盒子里的 `devprobe.py` 打开设备，各发一个 ioctl：KVM 创建虚拟机，DRM 读驱动版本。

lappie 上 `/dev/kvm` 是 `root:kvm 0660`，人的用户不在 `kvm` 组；render node 是
`root:video 0666`。

## 结果

| 项 | 结果 |
|---|---|
| 盒子进程的附加组 | 保留了主机用户的 7 个组；在盒子里显示为 65534（未映射），内核按原组检查 |
| 授权前打开 `/dev/kvm` | 不存在 |
| agent 自己 `mknod` | 失败 |
| 运行中挂 `/dev/kvm` | 挂上了；打开报 Permission denied，因为用户不在 `kvm` 组 |
| 运行中挂 render node | 挂上了，盒子里读出 `amdgpu 3.64` |
| 撤掉 `/dev/kvm` | 原位置只剩占位空文件，ioctl 报 ENOTTY |

## 结论

- 设备可以在运行中加、撤，不用 root，agent 自己造不出设备节点。
- 盒子里能不能用设备，取决于主机用户本身有没有权限：附加组能带进盒子，但主机用户
  没有的权限，盒子也没有。在盒子里用 KVM，要先在主机配置里把用户加进 `kvm` 组。
- 撤销和挂载一样，收不回已经打开的 fd。

## 没测到的

- KVM 真正起虚拟机（要先加 `kvm` 组）。
- Mesa 实际用 GPU 还要 `/sys/dev/char` 和 GPU 的 sysfs 目录，这次只测了 ioctl。
- 撤掉后留下的占位文件，正式实现应一起删掉。
