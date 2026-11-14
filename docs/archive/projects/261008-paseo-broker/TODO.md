# Paseo broker 进度

全部完成。

1. ~~清理边界调查~~ 已完成。10/08 读 Guix 源码并做实验：PID 1 退出会清掉整个
   namespace，只杀外层进程不够；结论暂定，见
   [pid-namespace-debug-20261008](pid-namespace-debug-20261008.md)。
2. ~~parent-death 实验~~ 已完成。10/09 结论：首版选可信的 PID namespace supervisor，
   不用 cgroup guardian，见 [parent-death-measure-20261009](parent-death-measure-20261009.md)；
   测试 `parent-death-namespace.py`。
3. ~~broker 首版~~ 已完成。10/09，`broker.py`、`agent-supervisor.c`、`paseo-broker.scm`
   和集成测试，共享 SSH 服务同时加入；1e624f0。当时的试用步骤和验证记录见
   [trial-procedure-deploy-20261009](trial-procedure-deploy-20261009.md)、
   [first-validation-measure-20261009](first-validation-measure-20261009.md)。
4. ~~环境变量转发~~ 已完成。10/10 broker 可把策略里指名的变量传给 agent，63bdeb0。
5. ~~执行层~~ 已完成。10/16 `daily`、`system`、`host`，PR #18；10/17 `host` 的临时文件
   和执行记录分开，34dc499。
6. ~~验收~~ 已完成。10/16 写验收清单，见
   [broker-acceptance-measure-20261016](broker-acceptance-measure-20261016.md)；
   11/14 人确认已全部做完。逐项记录未确认。
7. ~~设计文档整理~~ 已完成。10/17，见 [broker-design-20261017](broker-design-20261017.md)。
8. ~~host 层 cgroup v2~~ 已完成。10/17 每次执行一个 cgroup，递归 `cgroup.kill`，
   重启时先对账再接纳新执行，PR #24。
9. ~~Pi 和 OpenCode~~ 已完成。10/22 Pi 三层、OpenCode 仅 `host`，PR #42；10/23 改用内置
   `opencode` ID，PR #46。
10. ~~后续修改~~ 已完成。11/01 `paseo-broker ssh-refresh`，PR #78；11/04 launcher 不用
    重启 broker，PR #86；11/10 relay 重启参数不再被丢掉（涉及 broker 之外的服务），
    PR #92；11/12 授权根目录加 `~/spaces`，PR #94。
