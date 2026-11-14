# Paseo

Paseo daemon 容器、broker、分支清理和 storie 上的 relay。

## 用法手册

- [daemon-guide](paseo/daemon-guide.md)：daemon 容器的布局、配置、挂载和验证。
- [broker-guide](paseo/broker-guide.md)：broker 的命令、环境策略、共享 SSH 服务和执行层。
- [branch-gc-guide](paseo/branch-gc-guide.md)：分支清理。
- [relay-guide](paseo/relay-guide.md)：storie 上的 Paseo relay。

## 过程文档

- [upgrade-0.15.4-measure-20261113](paseo/upgrade-0.15.4-measure-20261113.md)：从 0.11.4 升到 0.15.4 的记录和验证。
- [broker-design-20261017](paseo/broker-design-20261017.md)：broker 的原始设计，基于 Paseo 0.10.3。
- [broker-acceptance-measure-20261016](paseo/broker-acceptance-measure-20261016.md)：启用 broker 前的验收清单，已完成。
- [daemon-cutover-deploy-20261015](paseo/daemon-cutover-deploy-20261015.md)：daemon 的首次切换。
- [parent-death-measure-20261009](paseo/parent-death-measure-20261009.md)：parent-death 信号实验结果。
- [pid-namespace-debug-20261008](paseo/pid-namespace-debug-20261008.md)：Guix PID namespace 与 cgroup 的调查。
