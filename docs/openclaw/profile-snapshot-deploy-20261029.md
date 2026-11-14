# OpenClaw Profile 快照方案上线

> 旧文档：只读，不再更新。现状见 [browser-guide.md](browser-guide.md)。

## Profile 快照方案上线

镜像 `sha256:bf69eb314709f5de2106b2dcc72a2f8ef53adb4e66c1ac6160c91f06fa7ed2f7`
已通过 storie 冒烟测试：两个任务浏览器同时运行，快照存储数据成功复制。
storie 的沙箱构建上下文和 `skills` 随部署更新；启动时在引擎中自动构建镜像。
专用 skill 声明如下：

```scheme
(skills
 `(("agent-browser"
    ,(local-file (project-path "scripts/openclaw/skills/agent-browser")
                 #:recursive? #t))))
```

部署并重建沙箱后，首次执行 `browser-profile login about:blank` 会迁移旧 profile；
执行 `browser-profile publish` 即可把现有登录发布为初始快照。迁移前需正常关闭
所有旧 agent-browser session；不要删除锁文件强行复制。Gateway 加载上述专用 skill，
通用命令参考仍从镜像中 `agent-browser skills get core` 读取，不改变桌面 skill。
