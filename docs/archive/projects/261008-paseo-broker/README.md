# Paseo broker

已完成的历史项目，按 `git log` 和迁移前的 org 文档重建；时间线以提交日期为准，
没有提交可查的事实写“未确认”。

## 目标

daemon 在容器里，provider（Claude、Codex、Pi、OpenCode）要在主机上用
contained-agent 启动，并且会话结束或任何一方崩溃后，不留下孤儿进程。现状见
[broker-guide](../../../paseo/broker-guide.md)。

## 背景

- [paseo-daemon-container](../261004-paseo-daemon-container/README.md) 把 daemon 放进了
  容器，容器里没有 Guix daemon，也不该持有 agent 的凭据。agent 需要由主机上的一个服务代为启动。
- Paseo 只能把 provider 的启动命令换成一个程序，所以 broker 提供转发用的客户端，
  经 Unix socket 把请求和标准输入输出交给 broker。
- 清理边界是难点：Guix 的 `guix shell --container` 没有给每次执行单独的 cgroup。
  设计和实验见 [pid-namespace-debug-20261008](pid-namespace-debug-20261008.md)、
  [parent-death-measure-20261009](parent-death-measure-20261009.md) 和
  [broker-design-20261017](broker-design-20261017.md)。

## 主要决定

- 10/08：Guix 容器的 PID 1 退出时内核会清掉整个 PID namespace，但只杀外层 Guix 进程不够；
  方案先留作暂定（pid-namespace-debug 末段）。
- 10/09：首版用每次执行一个外层 PID namespace 的可信 init（`agent-supervisor`），
  带 PDEATHSIG 和 pidfd 检查，不要求 cgroup（parent-death-measure、1e624f0）。
- 10/09：broker 自己保留 askpass 和桌面变量，不接受 provider 客户端指定（1e624f0 的文档）；
  10/10 起允许由策略指名额外的环境变量传给 agent（63bdeb0）。
- 10/09：长驻的 `contained-agent ssh-service` 为所有会话准备项目 SSH agent（1e624f0）。
- 10/16：provider 配置加执行层 `daily`、`system`、`host`（#18）。`system` 当时只是
  占位，没有额外权限，现在仍是。
- 10/17：`host` 层改用每次执行一个 cgroup v2 清理后代（#24）。此前 host 模式保留主机的
  PID namespace，脱离的后代进程无法由 namespace 拆除保证清理。cgroup 只是清理手段，
  不是安全边界。
- 10/22–10/23：Pi 加三层；OpenCode 只有 `host` 层，因为 Paseo 用一个共享的
  `opencode serve`（#42、#46）。
- 11/04：broker 每次执行解析 Home 的 `~/.local/bin/contained-agent`，更新 launcher 不用重启
  broker（#86）。
- 11/12：broker 的授权根目录加入 `~/spaces`（#94）。

## 待定

无。验收清单记在 [broker-acceptance-measure-20261016](broker-acceptance-measure-20261016.md)，
2026-11-14 人确认已完成，broker 已长期使用；清单本身不是实测结果，逐项的测试记录未确认。

## 文档

- [TODO](TODO.md)：进度。
- [pid-namespace-debug-20261008](pid-namespace-debug-20261008.md)：Guix PID namespace 与 cgroup 的调查。
- [parent-death-measure-20261009](parent-death-measure-20261009.md)：parent-death 信号实验结果。
- [trial-procedure-deploy-20261009](trial-procedure-deploy-20261009.md)：试用包的构建、加载和回退步骤。
- [first-validation-measure-20261009](first-validation-measure-20261009.md)：首版的验证记录。
- [broker-acceptance-measure-20261016](broker-acceptance-measure-20261016.md)：启用 broker 前的验收清单。
- [broker-design-20261017](broker-design-20261017.md)：设计（基于 Paseo 0.10.3，部分已被实现取代）。
