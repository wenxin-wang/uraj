# contained-agent

在 `guix shell --container` 里运行 coding agent（Codex、Claude Code、OpenCode、Pi）。

## 用法手册

- [overview-guide](contained-agent/overview-guide.md)：组件、怎么启动、威胁模型、agent 做不到什么。
- [project-config-guide](contained-agent/project-config-guide.md)：项目条目、中央配置、凭据、批准和继承批准。
- [container-guide](contained-agent/container-guide.md)：容器的挂载、工作目录、Git、direnv。
- [agent-specs-guide](contained-agent/agent-specs-guide.md)：agent spec 和各 coding agent 的状态。
- [ssh-agent-guide](contained-agent/ssh-agent-guide.md)：项目 SSH agent。
- [podman-guide](contained-agent/podman-guide.md)：项目专用的 Podman 运行时。
- [browser-guide](contained-agent/browser-guide.md)：浏览器任务，人接管 agent 的浏览器。
- [guix-daemon-guide](contained-agent/guix-daemon-guide.md)：可选的 guix-daemon 访问。
- [pitfalls-guide](contained-agent/pitfalls-guide.md)：已知的坑。
- [development-guide](contained-agent/development-guide.md)：修改和测试 contained-agent。

## 过程文档

- [harbor-measure-20261025](contained-agent/harbor-measure-20261025.md)：Harbor 在 Podman 运行时里的验收。
- [open-items-design-20261012](contained-agent/open-items-design-20261012.md)：当时的待办。
