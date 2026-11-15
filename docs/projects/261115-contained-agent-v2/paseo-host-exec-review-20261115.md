# Paseo v0.15.4 route A 调研：daemon 在主机、agent 在 per-workspace 盒子内

范围：上游 `getpaseo/paseo`（v0.15.4）。只读源码，没有运行 daemon，没有联网。路径默认相对 `packages/server/src/`。标 **未确认** 的是只读代码推断不出、需要实测的点。

## 0. 先给结论

1. **git 全部通过 `spawn("git", …)` 执行，按 PATH 查找，没有 git 库，没有可配置路径。** PATH 前置的 `git` wrapper 能让它透明地走盒子。
   - 唯一的主机侧防护是 `-c core.fsmonitor=false`。hooks、clean/smudge filter、textconv、`core.sshCommand`、`credential.helper` 都没有禁用。
   - 所以不 wrap git 就一定会在主机跑盒子里的仓库配置。
2. **daemon 还会直接用 fs 读写盒子仓库**：`.git` 目录里的文件、`paseo.json`、worktree 元数据、文件浏览、diff 的 untracked 统计等。
   - 这只是读写数据，不执行代码，但**要求盒子的 workspace 目录在主机上以同一绝对路径可见**，比如 bind mount。
   - 一旦只放在盒子的私有文件系统里，worktree 创建、元数据、文件浏览、diff 都会失效。
3. **以下几项会在主机跑仓库内容，PATH wrapper 管不到**：
   - `paseo.json` 的 `worktree.setup` / `worktree.teardown`：主机 `bash -c`。
   - `scripts.*.portScript`：主机 `execFile`，命令来自仓库的 `paseo.json`。
   - 通用 ACP provider 的 `terminal/create`：默认 `terminal: true`，在主机 spawn，cwd 是 workspace。
   - `/usr/bin/which`、`<cli> --version` 的探测（只执行 PATH 上的 wrapper，风险可控）。
4. **provider 命令可以整条替换（`mode: replace`，argv 数组）**，daemon 会把 SDK 的参数追加在 argv 之后。
   - 每个 agent 的 `PASEO_AGENT_ID` / `PASEO_AGENT_CWD` 通过环境变量传给 provider 进程，wrapper 可以据此选盒子。
   - 终止靠主机侧对子进程树 SIGTERM/SIGKILL（tree-kill），wrapper 必须自己转发信号或让 `podman exec` 管。
5. **terminal 的 shell 只能通过 daemon 进程环境里的 `$SHELL` 换**，没有配置项。wrapper 的文件名最好叫 `zsh`，否则 zsh shell integration 不生效。

## 1. Git

### 1.1 调用方式

- 统一入口 `utils/run-git-command.ts`：`executeGitCommand`（约 :287）。
  - 实际 spawn 在 `run-git-command.ts:398-410`：`spawnProcess("git", ["-c","core.quotepath=false","-c","core.fsmonitor=false", ...args], {cwd, envOverlay, shell:false, stdio:[stdin?"pipe":"ignore","pipe","pipe"]})`。
  - 命令是字面量 `"git"`，没有配置项，也没有 `findExecutable`，由 Node `spawn` 按子进程 env 的 PATH 解析。
  - `spawnProcess`（`utils/spawn.ts:29-50`）的 env 是 `createExternalProcessEnv(process.env, overlay)`（`server/paseo-env.ts`），即**继承 daemon 全部环境**，只删掉 `PASEO_NODE_ENV`、`ELECTRON_RUN_AS_NODE` 等内部变量。
  - 在 `package.json` 里没有 simple-git、isomorphic-git、nodegit。
- 有 `CheckoutContext.runGitCommand` / `deps.runGitCommand`（`checkout-git.ts:941-947`、`workspace-git-service.ts`）这类注入点，但只是测试和内部注入，**没有面向用户的配置项**。
- 并发、超时、输出上限：`git-process-scheduler.ts`（`daemon.git` 持久化配置只管并发和速率）、默认超时 30s、输出上限 20MB（`run-git-command.ts:18-19`）。
- `--version` 诊断：`server/session/daemon/diagnostics.ts:241`。

### 1.2 传入的环境变量和参数

- `GIT_OPTIONAL_LOCKS=0`：只读调用（`checkout-git.ts:55`、`worktree.ts:54`）。
- `GIT_TERMINAL_PROMPT=0`：fetch（`worktree.ts:1898`）。
- `GIT_TERMINAL_PROMPT=0, GIT_ASKPASS="", GCM_INTERACTIVE=0`：被动 `fetch origin --prune`（`workspace-git-fetch.ts:34-40`）。
- `GIT_INDEX_FILE=<宿主 tmp>/paseo-all-changes-*/index`：见 1.4。
- `--literal-pathspecs`：`checkout-git.ts:3746-3798`。
- diff 带 `--no-ext-diff`（`checkout-git.ts:651`），但**没有 `--no-textconv`**，也没有 `--no-verify`。
- git 的 `-c` 注入只有上面两个，没有 `GIT_CONFIG_*`、`GIT_DIR`、`GIT_WORK_TREE`。

### 1.3 daemon 跑 git 的位置（按功能）

| 功能 | 位置 | 典型命令 |
|---|---|---|
| 判定 git 仓库、repo root、分支、HEAD | `checkout-git.ts:981-1100` | `rev-parse --git-dir / --show-toplevel / --abbrev-ref HEAD / HEAD / --git-path / --git-common-dir / --absolute-git-dir` |
| 工作区状态、摘要 | `checkout-git.ts:1379`、`2582`、`2932` | `status --porcelain`、`diff --shortstat`、`ls-files -z --others --exclude-standard` |
| diff（uncommitted/base/all） | `checkout-git.ts:528-800`、`3500-3610` | `diff --name-status`、`diff --patch`、`merge-base`、`ls-tree`、`update-index --index-info`（stdin） |
| 文件内容对比 | `git-file-contents.ts:15` | `cat-file --batch`（`runGitCommandBytes`，stdin 输入，输出为二进制） |
| 查看历史文件、提交 | `checkout-git.ts:606`、`2313`、`2410-2551` | `show <ref>:<path>`、`rev-list`、`log` |
| 分支列表、重命名、切换 | `checkout-git.ts:1214`、`1243`、`1642`、`502-512` | `for-each-ref`、`branch -m`、`branch --format`、`checkout [-b --track]` |
| remote、push 目标 | `checkout-git.ts:1392-1453`、`1607` | `config --get`、`remote get-url --push`、`symbolic-ref refs/remotes/origin/HEAD` |
| commit | `checkout-git.ts:3728-3730` | `add -A`、`commit -m`（**会跑 pre-commit、commit-msg 等 hook**） |
| 撤销、回滚 | `checkout-git.ts:3746-3798` | `reset -q HEAD --`、`checkout -q --`、`clean -fd -q --` |
| merge、pull、push、PR 分支 | `checkout-git.ts:3822-4297` | `merge [--squash] [--abort]`、`pull`、`push [-u]`、`config branch.*.remote`、`update-ref`、`check-ref-format` |
| 被动 fetch | `workspace-git-fetch.ts:34` | `fetch origin --prune`，另有 refs 快照 |
| worktree 创建 | `worktree.ts:1391` | `worktree add <path> …`，随后 `config remote.*.url / push / branch.*.pushRemote` |
| worktree 列表、归属验证 | `worktree.ts:1025`、`1101`、`1960` | `worktree list --porcelain` |
| worktree 归档、删除 | `worktree.ts:1215`、`1231` | `worktree remove --force`、`worktree prune`；失败后主机 `rm -rf` |
| 获取远端分支、PR 分支 | `worktree.ts:1896`、`1912` | `fetch`、`show-ref` |
| 项目配置提交状态 | `server/session/project-config/worktree-setup-commit-status.ts`（5 处） | 同上 |
| 目录建议、文件浏览 | `utils/directory-suggestions.ts`、`server/file-explorer/service.ts`（4 处） | 未逐条核对 |
| 插件 managed source | `server/plugins/managed-source.ts`（7 处） | clone 等，cwd 在 paseo home 下，不在盒子 |

**未发现 stash 的 daemon 实现**：`checkout-git.ts:78-79` 只有 `stash-push`/`stash-pop` 的类型标签，没有找到对应的 git 调用。

### 1.4 直接 fs 读写 `.git`（不经过 git 进程）

这些都需要主机能以同一绝对路径看到盒子仓库：

- `utils/worktree-metadata.ts:147-163`、`:400-440`：读 `<wt>/.git` 文件（`gitdir: ...`），读写 `<gitdir>/paseo/worktree.json`（版本、baseRef、runtime port 等）。
- `utils/worktree.ts:1015-1038`：`resolveMetadataOwnedWorktree` 依赖该 marker 加 `git worktree list` 证明归属。
- `checkout-git.ts:1066`：`readFile(resolve(cwd, rev-parse --git-path <rebase-merge/head-name>))`。
- `checkout-git.ts:1566-1594`：检查 `MERGE_HEAD`、`rebase-merge`、`rebase-apply`。
- `workspace-git-service.ts:2137`：读 `<gitdir>/commondir`。
- `workspace-git-service.ts:1378`、`1503`、`1780`：对 `<wt>/.git` 和工作区做文件监听（native recursive watcher），用于触发刷新。
- `checkout-git.ts:2846-2865`：untracked 文件行数统计，直接 `stat` 加 `readFile`。
- `checkout-git.ts:3556-3575`（`prepareAllChangesIndex`）：
  - 在主机 `tmpdir()` 下 `mkdtemp`，
  - 用 `rev-parse --git-path index` 返回的路径做主机 `copyFile`，
  - 再用 `GIT_INDEX_FILE=<宿主 tmp>` 跑 `git update-index`（stdin 输入）。

  经 wrapper 时：`rev-parse` 输出的是盒子内路径，而 `GIT_INDEX_FILE` 指向主机 tmp。两者都要求这些路径在主机和盒子里相同，否则 diff 的「all changes」模式失败。需要共享 `/tmp`，或把 `paseo-all-changes-*` 目录映射进盒子。

### 1.5 PATH wrapper 能否透明重定向

**能，但要处理这些点：**

- 主机上的 `cwd` 必须存在（`spawn` 的 cwd），wrapper 用 `$PWD` 判断属于哪个盒子。判断依据可以是 `cwd` 前缀映射 `workspace → box`，不属于任何盒子的（如 plugin 源码目录）fall through 到真 git。
- wrapper 必须自己加 `podman exec -i -w "$PWD"`：
  - **需要 `-i`**：`cat-file --batch`、`update-index --index-info` 靠 stdin。
  - **不能带 `-t`**。
  - 必须是**二进制安全**的，`runGitCommandBytes` 读 stdout 原始字节。
- 环境变量：daemon 的 `GIT_OPTIONAL_LOCKS`、`GIT_TERMINAL_PROMPT`、`GIT_ASKPASS`、`GCM_INTERACTIVE`、`GIT_INDEX_FILE` 是 `envOverlay`，wrapper 要把这几个白名单转发进盒子（`podman exec -e`）。**不要**转发整个主机环境。
- 输出里出现的绝对路径（`rev-parse --show-toplevel`、`--git-common-dir`、`worktree list --porcelain`）会被 daemon 当主机路径使用（realpath、fs 读取、归属判断），所以盒子内路径必须与主机相同。
- 退出码有意义：`acceptExitCodes`、`rev-parse --verify --quiet` 的 1 等，wrapper 要原样透传。
- 信号：超时用 `child.kill("SIGKILL")` 杀 wrapper 进程（`run-git-command.ts:353`）。`podman exec` 在 wrapper 被 SIGKILL 后**不一定杀盒子内的 git 进程**，会留下 `index.lock` 风险。**未确认**，需要实测；稳妥的做法是 wrapper 用 `exec podman exec …` 且开 `--sig-proxy`，SIGKILL 则无法转发。
- **性能**：daemon 有频繁轮询（工作区观察、被动 fetch、状态刷新），每次 spawn 一个 `podman exec` 开销大，`git-process-scheduler` 的并发配置要调。
- 探测：`findExecutable("git")` 没有用到；git 的 `--version` 只在诊断里跑一次。

### 1.6 `gh` / forge CLI

- `services/github-service.ts:2779`、`2800`：`findExecutable("gh")`，即 `/usr/bin/which -a gh`（`executable-resolution.ts:26`）加每个候选 `gh --version` 探测（`:71`）。
- 真正调用走 `createForgeCliRunner`（`services/forge-cli-command.ts:104-111`）：`execCommand("gh", args, {cwd, envOverlay:{GIT_TERMINAL_PROMPT:"0"}, maxBuffer:10MB, timeout:30s})`，按 PATH 解析，**没有 stdin**。
- 用到的子命令：`gh pr view/list/merge`、`gh api graphql -f query=…`、`gh api repos/<slug>/pulls -X POST -f title= -f head= -f base= -f body=`（`github-service.ts:2497-2503`，创建 PR）、`gh api …/check-runs`、`gh api …/actions/jobs/<id>/logs`、`gh repo view --json owner,name,parent`、`gh auth status --hostname`。
- 输出是 JSON，由 zod 解析（`parseCliJsonOutput`）。路径无关，但依赖 cwd 里的 git remote 来解析 repo。
- 同类：`glab`（`gitlab-service.ts:262`）、`tea`（`gitea-service.ts:414`、`1193`）、`ssh -G`（`utils/ssh-hostname.ts:41`）。
- gh 的认证（`~/.config/gh`）：wrapper 放进盒子就是盒子里的凭据，这是好事；但 `gh auth status` 的探测也会进盒子。
- `gh api graphql -f query=…` 的参数可能很长或含换行，wrapper 要保留 argv 原样。

## 2. 终端

- 用 `node-pty`（`terminal/terminal.ts:821`），在独立的 **terminal worker 进程**里（`terminal/terminal-worker-process.ts`、`terminal-worker-launch.ts`）。worker 被 detach，daemon 重启后仍存活。
- shell 选择：`terminal.ts:264-274`，**只读 `env.SHELL`，否则 `/bin/sh`**（POSIX）。`createTerminal` 里 `shell ?? resolveDefaultTerminalShell({env: baseEnv})`（`:768`）。
  - `shell` 参数在 session 控制器创建终端时**没有从客户端传入**（`terminal-session-controller.ts:592` 只传 `cwd, workspaceId, name, command, args, rows, cols`）。
  - 没有 daemon 配置项。`baseEnv` 来自 daemon 进程环境（`worker-terminal-manager.ts:144-146`）。
  - 所以唯一入口是**给 daemon 进程设 `SHELL=<wrapper>`**。**注意 worker 是长寿命进程，`baseEnv` 在 worker 启动时按 daemon 的环境快照**，改 `SHELL` 后要重启 worker（**未确认**重启条件）。
- 客户端 `create_terminal` 请求可带 `command`/`args`（`terminal-session-controller.ts:592-597`）：此时不走 shell，直接 `execve`（`assertTerminalCommandCanStart` 用 PATH 解析，`terminal.ts:723-760`）。**这条路径绕过 `$SHELL`**，命令由 PATH 解析，所以 wrapper 目录在 PATH 前面也能拦，但**直接 execve 的任意命令在主机执行**，没有盒子重定向。Web/CLI 是否会发这种请求：**未确认**。
- 终端环境（`terminal.ts:449-480`）：继承 daemon 环境，加 `TERM`、`TERM_PROGRAM=kitty`、`PASEO_WORKSPACE_ID`、`PASEO_HOOK_CLI`，并**把 paseo CLI 目录前置到 PATH**（`prependPaseoCliToPath`）。
- **cwd**：`pty.spawn({cwd})`，必须在主机存在。shell wrapper 用 `$PWD` 选盒子。
- **zsh integration**：`terminal.ts:469`，只有 `basename(shell) === "zsh"` 才会设 `ZDOTDIR` 指向主机 `tmpdir()/<user>-paseo-zsh-<pid>/`（含 `.zshenv`、`paseo-integration.zsh`）。
  - 它提供 OSC 633 命令结束、标题跟踪。`shell-integration/` 里**只有 zsh**。
  - 影响：脚本类 workspace script 靠 `terminal.onCommandFinished` 判定结束（`worktree-bootstrap.ts:643-647`），没有集成就不会标记 stopped。
  - 建议 wrapper 文件名取 `zsh`，转发 `ZDOTDIR`、`PASEO_ZSH_ZDOTDIR`，并把该运行时目录挂进盒子。**未确认**：集成脚本在盒子内 zsh 版本下是否可用。
- agent 通过 MCP 创建终端（`agent/tools/paseo-tools.ts` 的 `create_terminal`，约 :896）也走同一个 `terminalManager`，所以同样经 `$SHELL`。

## 3. paseo.json 的 scripts / setup / lifecycle

配置结构：`packages/protocol/src/paseo-config-schema.ts:29-95`。读取器：`utils/paseo-config-file.ts`（主机 fs，限 256KB，必须是普通文件）。

| 项 | 执行位置和方式 | 位置 |
|---|---|---|
| `worktree.setup`（字符串或数组） | **主机** `bash -c <cmd>`，cwd=worktree，`execFile` 或 `spawnProcess`，env=daemon 环境加 `PASEO_SOURCE_CHECKOUT_PATH/PASEO_ROOT_PATH/PASEO_WORKTREE_PATH/PASEO_BRANCH_NAME/PASEO_WORKTREE_PORT`，删掉 `BASH_ENV` | `worktree.ts:412-440`、`444-560`、`632-690` |
| `worktree.teardown` | 同上，**主机 bash**，在 archive/delete 前执行 | `worktree.ts:735-790`、`1206` |
| `worktree.terminals[]`（`{name, command}`） | 开 node-pty 终端（经 `$SHELL`），再 `send("<command>\r")` | `worktree-bootstrap.ts:316-345` |
| `scripts.<name>.command` | 开 node-pty 终端（经 `$SHELL`），再 `send("<command>\r")`；service 类还要登记 service-proxy | `worktree-bootstrap.ts:518-720` |
| `scripts.<name>.port` / `worktree.servicePorts.portScript` | **主机** `execFile(<portScript>, [scriptName, workspaceId, branch, cwd], {shell:false})`，命令字符串就是 argv[0]（不是 shell 字符串）；要求 stdout 只有一个端口 | `server/workspace-service-port-allocator.ts:28-75` |

结论：

- `bash` 是写死的（`utils/string-command-shell.ts:44-47`），没有配置项。`PATH` 上放一个 `bash` wrapper 可以拦（`spawnProcess("bash", …)` 按 PATH 解析），但**会连带破坏其他用到 bash 的主机侧流程**，且 wrapper 要区分「盒子内 workspace 的 setup」和「主机侧其他用途」。cwd 前缀判定可行，但这是一个高风险点，不推荐直接依赖。
- 更稳妥：**禁用或不使用 `worktree.setup/teardown/portScript`**，或把它们改成由盒子内部逻辑（比如盒子启动时）执行。但仓库里的 `paseo.json` 是 agent 可写的内容，所以**只要 daemon 会读盒子内仓库的 `paseo.json`，这些字段就是主机代码执行入口**。需要决定怎样阻止：例如 daemon 读到的 `paseo.json` 与盒子内文件隔离，或接受 `bash` wrapper。
- `worktree.setup` 的调用方：`worktree-bootstrap.ts`、`worktree-session.ts`（创建 worktree 后自动跑）。**创建 worktree 时 agent 无需参与，仓库里已有的 `paseo.json` 就会触发。**
- 脚本经 `$SHELL` 终端执行，服务代理转发到 `127.0.0.1:<port>`（`service-proxy.ts`），盒子要么用 host 网络，要么发布这个端口。**未确认**端口选择与盒子网络模式的交互。

## 4. 文件浏览、读写、上传、图片

- **文件浏览器** `server/file-explorer/service.ts`：全用 fs API 在主机直接读写。
  - `readdir`（:167）、`handle.readFile`（:271）、流式读（:341）、写文件用临时文件加 rename（:525）、重命名、移动、删除（:661-780）。
  - **符号链接**：`resolveScopedPath`（:826-842）先 `realpath` 根，再 `realpath` 目标，并 `assertWithinWorkspace(canonicalRoot, canonicalPath)`；越界（符号链接指向工作区外）会被拒绝。删除用 `lstat` 保证删链接不删目标。
  - 打开用 `READ_FILE_OPEN_FLAGS`（:253 附近）；有 TOCTOU 的 `stat` 前后校验（`handle.stat({bigint:true})`）。
  - 因此：盒子内的符号链接指向「盒子内部路径」时，在主机上 `realpath` 会解析成主机上的真实路径。如果盒子里写了 `link -> /etc/passwd`，主机侧会得到 `/etc/passwd` 并因越界而拒绝，不会泄露。**但**符号链接指向 workspace 内部的话是正常的。
- **上传** `server/file-upload/index.ts`：写到 `<PASEO_HOME>/uploads/<upload_id>/<sanitized-name>`（:64、:126-127），在主机。
  - `agent/prompt-attachments.ts:116-123` 把 **主机路径** 写进 prompt（`Path: <host path>`），agent 需要去读这个路径。
  - 盒子里的 agent 要能读到，需要把 `<PASEO_HOME>/uploads` 以**相同路径只读挂入盒子**。
- **图片附件**：prompt 里的图片以 base64 内联（`prompt-attachments.ts:9,34`；Claude 的 `toSdkUserMessage` 里 `type:"image", source:{type:"base64"}`），**不落盘**，不需要共享路径。
- **下载**：`server/file-download/token-store.ts`，token 加主机 fs 流式读。
- **项目图标**：`utils/project-icon.ts`（`readdir`、`readFile`）读工作区里的图标，主机直接读。
- **项目配置**：`paseo.json` 读写（主机 fs，`paseo-config-file.ts`）。

结论：盒子的 workspace 必须主机可见（同路径）；这些操作本身只读写数据，不执行内容。

## 5. Provider 启动

### 5.1 命令配置

- 配置结构：`packages/protocol/src/provider-config.ts:19-66`。
  - `ProviderOverride.command: string[]`（argv，整条替换）、`env: Record<string,string>`、`options`、`disallowedTools` 等。
  - 内部还有旧的 `{mode: "default"|"append"|"replace", argv|args}` 形式（`ProviderCommandSchema`）。
  - 内置 id：`claude/codex/copilot/opencode/pi/omp`（`:68`），自定义的用 `extends: "acp"` 或内置 id。
- 解析：`server/agent/provider-launch-config.ts:84-105`（`resolveProviderLaunch`）。`replace` 时 `command = argv[0]`，`args = argv.slice(1)`。
- 可用性检查：`checkProviderLaunchAvailable` 用 `findExecutable`，即 `which -a` 加 `<cmd> --version` 探测（`provider-launch-config.ts:60-72`、`executable-resolution.ts:145-175`）。**wrapper 必须能在不带盒子的情况下响应 `--version` 并退出 0**。

### 5.2 Claude（最关键）

- 通过 `@anthropic-ai/claude-agent-sdk` 的 `query()`，daemon 提供自己的 `spawnClaudeCodeProcess`（`providers/claude/query.ts:58-110`）。
- 命令解析 `resolveClaudeSpawnCommand`（:31-55）：`replace` 时
  `command = argv[0]`，`args = [...argv.slice(1), ...spawnOptions.args]`，即**SDK 的参数追加在你的 argv 后面**。
  - 所以 `["/path/box-claude"]` 或 `["podman","exec","-i","-w", ...]` 都可行，但 `-w` 的目录必须在 wrapper 里算（argv 是静态的，没有 cwd 占位符）。
  - **未确认**：SDK 对非 `.js` 的 `pathToClaudeCodeExecutable` 是否一律当原生可执行文件处理（决定 `spawnOptions.args` 里是否带脚本路径首参数）。daemon 在 `resolved.command === "node"|"bun"` 时才改用自身 node（`query.ts:70`）。
- `spawnProcess(command, args, {cwd: spawnOptions.cwd, env…, shell:false, stdio:["pipe","pipe","pipe"], signal})`（:85-95）：
  - **cwd = agent cwd（主机路径）**，必须在主机存在。
  - env = 继承 daemon 整个 `process.env`，加 provider `env`，加 `launchEnv`（`PASEO_AGENT_ID`、`PASEO_AGENT_CWD`，见 `agent-manager.ts:5612-5617`），加 `CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS=1`（`agent.ts:3641-3652`）。**wrapper 必须白名单转发，否则 daemon 环境里的密钥会进盒子。**
  - SDK 还会塞 `--mcp-config <json>`（含 daemon 的 MCP URL `http://…/mcp/agents?callerAgentId=…`，`runtime-mcp-config.ts:41-50`）、`--settings`、`--resume`/`--session-id`、`--permission-mode` 等。盒子必须能访问 daemon 的 MCP 监听地址（回环地址在容器里不通，需要 host 网络或 `host.containers.internal`）。**未确认**实际 URL 的 host 部分如何计算。
- **模型发现、版本、登录探测**也会 spawn 同一个命令：
  - `claude/model-discovery.ts:59`，`cwd: os.homedir()`。
  - `claude/agent.ts:1918-1945`，`<cmd> --version`，要求输出匹配 `X.Y.Z (Claude Code)`，否则丢弃。
  - `resolveClaudeAuth`，约 :1950 起。
  - 这些**没有 `PASEO_AGENT_CWD`**，wrapper 要有「无盒子」的回退路径，比如落到一个固定的探测盒子，或直接跑主机 claude。
- **停止 / 中断**：
  - 中断是 SDK 控制消息（`query.interrupt()`），不发信号。
  - 关闭 / 重启用 `terminateWithTreeKill(child, …)`（`agent.ts:3036`、`3494`、`4454`；`utils/tree-kill.ts`）：对 **子进程 pid 用 `tree-kill` 包发 SIGTERM，超时后 SIGKILL**，失败回退 `child.kill`。**不是进程组**（claude 的 spawn 没有 `detached`）。
  - wrapper 若是 `exec podman exec …`，信号发给 `podman exec` 客户端，`podman exec` 会尝试转发（TERM/INT 等，SIGKILL 不可转发）。盒子内残留进程需要盒子自己清理。
- **读 transcript**（主机直接读）：
  - 路径：`$CLAUDE_CONFIG_DIR 或 ~/.claude` / `projects` / `<encode(realpath(cwd))>` / `<sessionId>.jsonl`（`claude/project-dir.ts:19-95`）。`encode` 把非字母数字替换为 `-`，超 200 字符加哈希后缀。
  - 找不到就**扫描所有 project 目录按 sessionId 找**（`project-dir.ts:55-72`）。
  - `CLAUDE_CONFIG_DIR` 取的是**daemon 自己的 `process.env` 加 provider 的 `env`**（`agent.ts:1747-1752`、`5547-5551`）。所以把盒子内 claude 的配置目录通过共享目录映射到主机，并在 provider `env` 里设 `CLAUDE_CONFIG_DIR=<该宿主目录>`，daemon 就能读到。
  - 还要求盒子内 claude 看到的 cwd 与主机 cwd 的 encode 结果一致（同路径即可）；不一致时会退化为按 sessionId 全局扫描。
  - 读：`transcript-history.ts:140`、`agent.ts:6903`；列出可导入会话 `agent.ts:1763-1790`、`6650-6700`；rewind 通过 SDK `forkSession` 加自定义 `sessionStore`，**在主机 `appendFile` 写 transcript**（`rewind.ts:20-60`）。
  - 以上仅是数据读写；唯一风险是 transcript 在主机被解析（JSON.parse，无执行）。
- `--settings` 的路径读取：`agent.ts:650-670`（主机 `readFile(path.resolve(cwd, …))`），来自 provider options，不是仓库。

### 5.3 Codex

- `codex-app-server-agent.ts:7300-7320`：`spawnProcess(launchPrefix.command, [...args, "app-server"], {detached: true, baseEnv: buildCodexAppServerEnv(runtimeSettings, launchEnv)})`，**没有 cwd**（继承 daemon cwd），cwd 通过 JSON-RPC 的 thread 参数传。
- wrapper 要读 `PASEO_AGENT_CWD`（launchEnv 里有，进入 baseEnv）来选盒子。**未确认** app-server 是 per-agent 还是共享（影响盒子选择）。
- 命令替换：`resolveCodexLaunchPrefix(runtimeSettings)`，同一套 `command` 配置。
- `detached: true`：子进程自成进程组，tree-kill 对 pid 发信号。
- 主机读 `$CODEX_HOME 或 ~/.codex` 下的 prompts、skills（`:639`、`4173`、`5129-5143`）以及 `<cwd>/.codex/skills`（`:795-802`）。

### 5.4 OpenCode：共享与独占

- v0.15.4 有 v1（`opencode-agent.ts`、`opencode/server-manager.ts`）和 v2（`opencode/v2/*`）两套。
- **选择逻辑（v2）** `opencode/v2/service-selection.ts:10-27` 和 `runtime.ts:75-100`：
  1. 显式外部服务（`PASEO_OPENCODE_SERVER_URL` 等环境变量）→ `explicit`。
  2. 否则读 `$XDG_STATE_HOME/opencode/service.json` 发现本机已有服务 → `discovered`（要求 host 是本机地址）。
  3. 否则 `owned`：自己 spawn `<opencode> serve --hostname 127.0.0.1 --port 0`（`runtime.ts:261`；v1 是 `serve --port <allocated>`，`server-manager.ts:73`）。
- `owned` 下的分支（`runtime.ts:93-100`）：
  - 默认：所有 agent **共用一个 `serve`**（`this.current`）。
  - `input.env` 或 `input.dedicated` 有值 → **每次启动一个独立 `serve`**（`startTracked(input.env)`）。
- 什么时候是独占（`requiresDedicatedV2Server`，`opencode/v2/configuration.ts:75-130`；v1 的 `opencode-agent.ts:352-359`）：
  - 配置了自定义 `mcpServers`，或
  - `launchContext.env` 里有 `PASEO_AGENT_ID`、`PASEO_AGENT_CWD` 之外的 key（例如插件 `agent.open.before` 钩子加的 env）。
  - 在共享服务模式（explicit/discovered）下这两种情况会直接报错（`runtime.ts:156-170`）。
- **serve 进程的 cwd 是一个中性的 OpenCode home**（`server-manager.ts:323`、`344`），**不是 workspace**；workspace 通过 API 的 `directory` 参数传（`opencode/v2/session.ts:132`、`opencode-agent.ts:1069`）。
- 对 route A 的含义：
  - 共享 `serve` 无法按 workspace 隔离：一个主机进程服务所有 workspace，其工具调用在该进程里运行。
  - 想 per-盒子，必须是独占 `serve`，且 wrapper 要能从 env 知道盒子：`launchContext.env` 里非保留 key 会进 `startServer(launchEnv)` 的环境（`server-manager.ts:341`）。这要靠插件钩子注入，**内置路径没有 per-agent 自定义 env 的入口**（**未确认**是否有其他来源）。
  - 另外 `serve` 监听 `127.0.0.1:<port>`，daemon 从主机回环访问：盒子内的 serve 需要把端口发布到主机回环（或 host 网络），而端口是 v1 由 daemon 分配、v2 是 `--port 0` 从 stdout 解析 `server listening on http://127.0.0.1:N`（`runtime.ts:320`），wrapper 要原样透传 stdout。
  - OpenCode 还装了「bridge 插件」（`bridge-plugin.mjs`，`PASEO_OPENCODE_BRIDGE_*`），用于 Paseo 原生工具；独占 serve 里要能回连 daemon。

### 5.5 通用 ACP provider

- 配置：`providers.<id> = {extends: "acp", label, command: [...], env}`（`provider-config.ts:90-104`；`providers/generic-acp-agent.ts:30-120`），`provider: "acp"`。内置的 `cursor/kimi/kiro/copilot` 是 ACP 的特化。
- 启动：`acp-agent.ts:2893-2925`（会话进程，`cwd = config.cwd`，env 带 `launchEnv`）和 `:1394-1440`（探测/模型列表，`cwd: process.cwd()`，即 **daemon 的 cwd**，没有 workspace 信息，要靠 launchEnv 里的 `PASEO_AGENT_CWD`；探测阶段 **未确认** 是否带 launchEnv）。
- **ACP client 能力（`acp-agent.ts:301-308`）**：`fs.readTextFile=false`、`fs.writeTextFile=false`、**`terminal=true`**。
  - `terminal=true` 时 agent 发 `terminal/create`，daemon 在**主机**执行（`acp-agent.ts:2785-2830`）：`spawnProcess(command, args, {cwd: params.cwd ?? config.cwd, shell: …})`。命令是 agent 给的，**这是主机任意命令执行**，PATH wrapper 管不到。
  - **缓解**：provider `options.clientCapabilities = {terminal:false}`（`acp-options.ts:6-16`，`acp-agent.ts:1029`、`1087`），这样 agent 退回自己的内置 shell 工具（在盒子内）。**必须配置。**
  - 如果打开了 `fs.*`，`readTextFile/writeTextFile`（`:2768-2783`）会在主机以 agent 给的绝对路径读写，没有 workspace 范围检查。保持 false。
- ACP agent 相比原生适配器丢失或弱化的能力：
  - `DEFAULT_ACP_CAPABILITIES`（`acp-agent.ts:282-293`）：`supportsRewindConversation/Files/Both = false`（原生 Claude 有 rewind）。
  - `supportsNativePaseoTools` 对 ACP 没有设置（只有 opencode 带 bridge、omp 为 true），所以靠 MCP 给 Paseo 工具。
  - 会话历史、模型目录、feature 选项靠 ACP 协议和 `configFeatureOptions` 等可选解析器，各 agent 不一；通常没有 Claude 的子 agent 面板、后台任务、context usage、fast mode 等。
  - 细节：**未确认**具体缺失清单，以上为从能力标志和代码差异做的推断。

## 6. 其他在主机执行二进制的地方

| 位置 | 内容 | 与 workspace 的关系 |
|---|---|---|
| `executable-resolution/executable-resolution.ts:26`、`:71` | `/usr/bin/which -a <name>`，再对每个候选跑 `<path> --version`（5s 超时） | 对 `gh/glab/tea/ssh/provider 命令/npm` 都会执行 PATH 上的候选，wrapper 必须秒回 `--version` |
| `services/gitlab-service.ts`、`gitea-service.ts` | `glab`、`tea` | 同 gh |
| `utils/ssh-hostname.ts:41` | `ssh -G <host>` | 读 `~/.ssh/config` |
| `server/session/daemon/diagnostics.ts:241、412`、`npm-global-cli.ts:73` | 诊断 `git/node/npm` 等 `--version` | 与 workspace 无关 |
| `server/plugins/managed-source/npm.ts`、`preparation-build.ts:41`、`managed-source.ts` | 插件安装（`npm`、`git clone`、构建） | 在 paseo home 下，与 workspace 无关 |
| `terminal/terminal-worker-launch.ts:50`、`terminal-worker-process.ts:101` | 启动 terminal worker（`process.execPath`） | 与 workspace 无关 |
| `server/daemon-instance.ts:272` | 自重启/supervisor 子进程 | 与 workspace 无关 |
| `server/speech/audio.ts` 等 | 音频（ffmpeg 等），模型下载 | 与 workspace 无关 |
| `terminal/agent-hooks/*` | 终端里的 agent 钩子调用 `paseo hooks …` CLI（在终端里，也就是盒子内） | 终端内 |

- **没有找到**语言服务器、格式化器、`open`/`xdg-open`、编辑器启动这类主机侧执行（对 `editor` 的 grep 命中集中在任务/forge 文本，非进程启动；**未逐条确认**）。
- 另外：`providers/opencode-agent.ts:1810`、`opencode/runtime-client.ts:97`（`--version`）、`diagnostic-utils.ts`（`$SHELL -lc type -a <bin>`，约 :312，探测二进制，主机 shell）。

## 7. Agent 创建的 worktree

- **路径约定**：`<worktreesBaseRoot>/<projectHash>/<slug>`。
  - `worktreesBaseRoot` 默认 `<PASEO_HOME>/worktrees`（`worktree.ts:841-851`），可由配置的 `worktrees.root`（`config.ts:630` 的 `resolveWorktreesRoot`）覆盖，支持 `~` 和相对路径。
  - `projectHash = deriveShortAlphanumericHash(repoRoot)`：`repoRoot` 来自 `git rev-parse --git-common-dir` 再对结果做主机 `realpath`，取其 dirname（若 basename 是 `.git`），sha256 前 8 字节转 base36 取 8 位（`worktree.ts:814-837`）。
  - 创建：`createWorktree`（`worktree.ts:1362-1440`）：`mkdir -p` 主机、`git worktree add <path> …`、`config` push/track remote、写 `paseo/worktree.json`、`seedPaseoConfigFile`（主机 `copyFile paseo.json`，ENOENT 被吞）。
- **归属判定** `isPaseoOwnedWorktreeCwd`（`worktree.ts:949-1013`），依次：
  1. 元数据证明：从 cwd 向上找包含 `.git` 且 git 管理目录里有 `paseo/worktree.json` 的目录，并且该路径出现在 `git worktree list --porcelain` 里（`resolveMetadataOwnedWorktree`，:1015-1038；`worktree-metadata.ts:342-360`）。支持放在任意路径（插件放置）。
  2. 路径形状：`relative(worktreesBaseRoot, realpath(cwd))` 至少两段，即 `<hash>/<slug>[/…]` → 允许。注释明确说 `<hash>/<slug>` 前缀是 Paseo 私有，仅凭形状就足够证明，即使 git 已忘记它。
  3. 否则 `allowed:false`。
- 调用点：`workspace-archive-service.ts:341`、`worktree/commands.ts:127`、`workspace-recovery-service.ts:173`、`auto-archive-on-merge/archive-if-safe.ts:72`、`create-agent-lifecycle-dispatch.ts:175`。
- **归档/删除** `deletePaseoWorktree`（`worktree.ts:1155-1250`，由 `workspace-archive-service.ts:456` 调用）：
  1. 校验归属（或调用方断言的 `registryProven`）。
  2. `assertWorktreeBelongsToRepo`（git 校验）。
  3. 目录存在则**主机** `bash -c` 执行 `worktree.teardown`（见 3 节）。
  4. `git worktree remove <path> --force`（失败吞掉）。
  5. **主机 `rm -rf`**（`removeDirectoryWithRetries`，重试 5 次，delays 0/100/300/700/1500ms）。
  6. `git worktree prune`。
- route A 含义：
  - worktree 要放进盒子且主机可见：路径 `<worktreesBase>/<hash>/<slug>` 必须在主机和盒子里是同一路径；把 `<worktreesBase>` 配成盒子的共享挂载目录，让 hash 稳定（`realpath` 在主机算，所以仓库根路径在主机需存在）。
  - 归档的 `rm -rf` 和 `paseo.json` 读取在主机，作用于盒子可写的数据，是破坏性操作但不执行代码；teardown 是执行。
  - 「盒子内 git 看到的 worktree 路径」与主机 `realpath` 结果不一致时（符号链接、挂载点），归属判定与 hash 会错位。

## 8. 评估

假设已做：PATH 前置 `git`/`gh` wrapper（按 cwd 路由，未命中回退真命令）、`SHELL=<名为 zsh 的 wrapper>`、各 provider `command` 替换成盒子启动器、provider `options.clientCapabilities.terminal=false`。

### 8.1 仍会在主机对盒子内容执行代码

| 功能 | 原因 | 缓解 |
|---|---|---|
| `worktree.setup` / `worktree.teardown` | `bash -c`，写死 `bash`（`string-command-shell.ts:44`），仓库的 `paseo.json` 控制内容 | 加 `bash` wrapper（按 cwd 路由，风险较高）；或 daemon 读到的 `paseo.json` 与 agent 可写文件隔离；或打补丁 |
| `scripts.*.portScript` | `execFile(<repo 指定的程序>, …, {cwd})` | 同上，或不使用；也可 wrapper 无法拦（命令是任意路径） |
| ACP `terminal/create` | 默认开启 | `clientCapabilities.terminal=false` |
| 客户端 `create_terminal` 带 `command`/`args` | 直接 `execve`，绕过 `$SHELL` | 不使用；**未确认**客户端是否会发 |
| `findExecutable` 的 `--version` 探测 | 执行 PATH 上的候选 | 候选就是 wrapper，可接受；wrapper 不要执行盒子内容 |
| OpenCode 共享 `serve` | 单个主机进程，对所有 workspace 的 `directory` 执行工具 | 必须走独占 serve 加 wrapper，或不用 OpenCode |
| Codex app-server 若 wrapper 未覆盖（`detached`，无 cwd） | 命令替换必须包含 | 靠 `PASEO_AGENT_CWD` 路由 |
| 直接 fs 读写（文件浏览、transcript、`.git` 文件、`paseo.json`） | 只读写数据，无执行 | 无需缓解；注意越界符号链接（已由 `realpath` 范围检查挡住）、特殊文件（FIFO/设备，**未确认**是否有检查） |
| 主机侧对盒子数据的解析 | JSON/zod、diff 文本、`worktree list` 输出 | 解析器漏洞是理论风险，不是配置执行 |
| 文件监听 | 主机 inotify | 无执行 |

### 8.2 会坏或需要特殊处理的功能

- **盒子的 workspace 不在主机可见路径上** → 以下全部失效：worktree 元数据读写、归属判定、`MERGE_HEAD`/rebase 状态检测、文件浏览、untracked 统计、`paseo.json`、`git worktree add` 后的 `seedPaseoConfigFile`、归档的 `rm -rf`、文件监听（工作区刷新）、转录路径推导。
- **diff 的 `all changes` 模式**：`GIT_INDEX_FILE` 指向主机 `tmpdir()/paseo-all-changes-*`，盒子里的 git 访问不到（除非共享 `/tmp` 或做路径映射）。
- **git 进程超时**：SIGKILL 的是 wrapper，盒子内 git 可能残留并留下 `index.lock`（**未确认**）。
- **性能**：频繁 `podman exec`；被动 fetch、轮询、状态刷新会放大，需调 `daemon.git` 并发/速率。
- **终端 shell integration**（命令结束检测、标题）：仅当 wrapper 名为 `zsh` 且转发 `ZDOTDIR`/`PASEO_ZSH_ZDOTDIR` 并共享其运行时目录时可用；否则脚本结束状态、终端标题退化。
- **盒子网络**：agent 需要访问 daemon MCP；daemon 需要访问盒子内 `opencode serve` 端口和 service-proxy 的 `127.0.0.1:<port>`。需要 host 网络或端口发布。
- **上传文件**：prompt 里是主机路径，需要把 `<PASEO_HOME>/uploads` 同路径只读挂入盒子。
- **provider 探测**（模型发现 cwd=`$HOME`、`--version`、auth）：wrapper 必须能在没有 `PASEO_AGENT_CWD` 时工作。
- **环境泄漏**：Claude SDK、git、gh、Codex 都会继承 daemon 整个环境；wrapper 必须用白名单转发。
- **terminal worker 的 `SHELL` 快照**：改 `SHELL` 需重启 worker（**未确认**）。

### 8.3 需要的 wrapper 清单（粗略）

1. `git`：按 `$PWD` 前缀路由到盒子，否则 exec 真 git；转发 stdin/stdout/stderr/退出码；白名单环境 `GIT_OPTIONAL_LOCKS`、`GIT_TERMINAL_PROMPT`、`GIT_ASKPASS`、`GCM_INTERACTIVE`、`GIT_INDEX_FILE`；不带 `-t`；`-w "$PWD"`。
2. `gh`（以及按需 `glab`、`tea`）：同上；`--version`、`auth status` 要快。
3. `zsh`（终端 shell）：设 `SHELL` 指向它；按 `$PWD` 选盒子；`podman exec -it`；转发 `TERM`、`ZDOTDIR`、`PASEO_*`；处理 resize（`node-pty` 的 SIGWINCH 由 `podman exec -t` 转发）。
4. `claude` 启动器（provider `command` 替换）：读 `PASEO_AGENT_CWD`（回退 `$PWD`），`podman exec -i -w`；白名单环境；信号转发；无参数 `--version` 的回退；`CLAUDE_CONFIG_DIR` 指向共享目录。
5. `codex` 启动器：同上，读 `PASEO_AGENT_CWD`；因为无 cwd，不能用 `$PWD`。
6. `opencode` 启动器（若使用）：必须独占 serve，盒子由非保留 env 变量选择；端口回传；不推荐。
7. 通用 ACP 启动器（若使用）：读 `PASEO_AGENT_CWD`，探测阶段无 workspace 时回退；配 `terminal:false`。
8. 可选：`bash` wrapper（拦 `worktree.setup/teardown`），以及对 `portScript` 的处理。优先考虑改 daemon 或配置规避，而不是拦 `bash`。
9. 非 wrapper 的配套：盒子的 workspace 与 worktree 根目录主机可见同路径；共享 `/tmp` 或 diff 临时目录；`<PASEO_HOME>/uploads` 只读挂入；转录目录共享。

### 8.4 未确认清单（汇总）

- SDK 对 wrapper 脚本是否按原生可执行文件传参（决定 `replace` 的 argv 拼接是否正确）。
- 终端 worker 重启时机与 `SHELL` 快照。
- 客户端/CLI 是否会发带 `command`/`args` 的 `create_terminal`。
- OpenCode 是否有内置的 per-agent env 来源（用于独占 serve 路由）。
- Codex app-server 是 per-agent 还是共享。
- ACP 探测阶段是否带 `launchEnv`；ACP 缺失能力的完整清单。
- 盒子内 zsh 对 Paseo shell integration 脚本的兼容性。
- `git` 被 SIGKILL 后盒子内进程残留。
- MCP URL host 的计算方式（盒子能否访问）。
- 文件浏览对 FIFO/设备等特殊文件的处理。
