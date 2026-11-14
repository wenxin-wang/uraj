# contained agent 与 Paseo 的秘密

> 迁移自 `secrets/README.org` 的 “contained agent 与 Paseo 的 GitHub token”、“contained agent 与 Paseo 的私有沙箱策略”、“Paseo 的 per-host YAML 配置”（2026-11-14，内容未改）。

## contained agent 与 Paseo 的 GitHub token

容器内的 agent 和 Paseo daemon 通过 HTTPS 推拉、用 `gh` 提 PR 需要
token。按能访问的仓库分三级，逐级包含：

| 级别 | token | 范围 |
|---|---|---|
| public | fine-grained，勾选你的每个公开仓库 | 你名下的公开仓库 |
| personal | fine-grained，All repositories | 你名下的全部仓库 |
| world | classic，`repo` 和 `workflow` scope | 你能访问的全部仓库 |

fine-grained 两级的权限为 `Contents`、`Pull requests`、`Workflows` 写：
可以推送（包括 workflow 文件）、创建和更新 PR，也能合并 PR、直推默认
分支，重要仓库应在 GitHub 上开分支保护。只有 world 能 fork、向别人的
仓库提 PR。token 进入有网络的容器后应视为可被外传，保护来自它的范围；
怀疑泄露时在 GitHub 上吊销并重新申请。

三级都存在 `shared/github.yaml` 的 `github.<级别>` 下，各主机复用。能解密
该文件就能读到全部级别；需要隔离的项目用自己的 `git-credential` 文件，
不放进这里。

GitHub 没有创建 token 的 API。在宿主机（不是容器内）的项目 Guix 环境中
对每个级别运行一次：

```sh
scripts/secrets/github_token.py public wenxin-wang
scripts/secrets/github_token.py personal wenxin-wang
scripts/secrets/github_token.py world wenxin-wang
```

脚本打开已预填的表单：public 和 personal 是 fine-grained 表单，填好了
名称、有效期和权限，仓库范围要手动选（public 选 Only select
repositories，宿主机 gh 已登录时脚本会列出要勾选的公开仓库；personal 选
All repositories）；world 是 classic 表单，填好了 scope，有效期自选。
把 token 粘贴回脚本（不回显），脚本核对 token 类型、所属用户和 classic
token 的 scope，成功后才写入密文，并打印过期时间。token 不会出现在命令行
参数里。首次创建文件只需公钥；更新已有文件需要管理员卡或本机 age
identity。fine-grained 默认有效期 366 天，`--days` 可改；到期后重新运行
同一命令即轮换。新建公开仓库后，在 GitHub 上编辑 public token 的仓库
范围即可（据称 token 值不变，未验证）。

`(uraj system secrets)` 的 `github-token-secrets` 把每级解密到
`/run/secrets/github/<级别>`，归主用户所有、权限 0400；密文文件尚不存在
时不声明任何 secret。运行 agent 或 Paseo 的 Guix System 主机都要声明。三个级别都写入后再提交并 reconfigure，否则缺少的
key 会让解密失败。

使用方：

- agent：`env/dotfiles/llm/contained-agent/.config/contained-agent/projects.scm`
  中项目写 `(github "personal")` 等，见 [docs/contained-agent/project-config-guide.md](../contained-agent/project-config-guide.md)。
- Paseo daemon：`~/.config/paseo/sandbox.scm` 写 `(github "world")`，见
  [docs/paseo/daemon-guide.md](../paseo/daemon-guide.md)。

launcher 在每次启动时读取 token 文件，不会改用宿主机自己的登录。
Guix System 上文件缺失时最多等 10 秒（开机时 agent 或 Paseo 可能先于
sops 解密启动），仍缺失则报错退出；foreign distro 没有 sops-guix 系统
服务，告警并不带 token 启动。只轮换 token（声明不变）时，
reconfigure 后还要重新解密：重启机器，或 `sudo herd restart sops-secrets`
（后者尚未在本仓库的主机上验证）。之后新启动的 agent 即可使用；Paseo
daemon 启动时挂载的是文件本身，sops 原地重写时新值可见，替换文件时需要
重启 daemon（未验证 sops-guix 采用哪种方式）。

## contained agent 与 Paseo 的私有沙箱策略

`contained-agent` 的中央配置和 Paseo daemon 的策略都是 S 表达式文件。
不想放进公开仓库、又想随仓库管理的部分，按主机加密保存，整份文件作为
一个 YAML 字符串值：

| 用途 | 密文 | 解密到 |
|---|---|---|
| contained-agent 中央配置 | `hosts/<主机>/contained-agent.yaml` | `/run/secrets/contained-agent/projects.scm` |
| Paseo daemon 策略 | `hosts/<主机>/paseo.yaml` | `/run/secrets/paseo/sandbox.scm` |

```sh
sops secrets/hosts/lappie/contained-agent.yaml
```

```yaml
contained-agent:
  projects.scm: |
    (project "~/src/foo"
      (ssh-agent
        (identity "~/.ssh/dev-servers" (destinations "dev.example.com"))))
```

`paseo.yaml` 同理，键为 `paseo` 下的 `sandbox.scm`。语法分别见
[docs/contained-agent/project-config-guide.md](../contained-agent/project-config-guide.md) 与 [docs/paseo/daemon-guide.md](../paseo/daemon-guide.md)。

文件存在即声明：各主机的系统配置用 `sandbox-policy-secrets` 解密到上表
路径，归主用户所有、权限 0400；`contained-agent` 与 Paseo 服务程序在
构建时记下哪些主机有哪份策略，运行时在这些主机上最多等 10 秒，仍缺失
则报错退出，不会不带策略启动。新增、删除这些文件都要同时 reconfigure
system 和 Home。只改内容时 reconfigure system，再重新解密（重启或
`sudo herd restart sops-secrets`）；agent 下次启动读到新内容，Paseo daemon
需要重启。

`~/.config/contained-agent/projects.local.scm` 仍可与密文配置并用，子句
合并生效。Paseo 只用一份策略：某台主机有密文时，本机不能再有
`~/.config/paseo/sandbox.scm`，否则拒绝启动，以免它被悄悄忽略；其它
主机不受影响，照常使用各自的本地文件。

## Paseo 的 per-host YAML 配置

公开配置集中在 `env/paseo/config.yaml`，以 `hosts.<hostname>` 选择；
lappie、hypie、storie 引用同一个 YAML anchor。私密配置分别保存为
`hosts/<hostname>/paseo-config.yaml`，使用已有的主机 creation rule，
只授权本机 age recipient 和三把管理员 PGP key。

```sh
sops secrets/hosts/lappie/paseo-config.yaml
```

解密后的结构示例（`config.yaml` 是对象，不是字符串）：

```yaml
paseo:
  config.yaml:
    hostname: lappie
    overrides: {}
    delete: []
```

`agent-configuration-secrets` 声明上述子树，以 YAML 格式解密至
`/run/secrets/paseo/config.yaml`，归主用户所有，权限 0400。主机身份
必须匹配，私密层优先于公开层；明文只在 activation 时读取，不进入 store。
初始文件只有主机名和空 override，不包含迁移来的凭据。

Home 的系统 Shepherd 服务依赖对应的 `sops-secret-paseo/config.yaml`，
确保开机先解密再合并。单独执行 Home activation 时也会短暂等待文件，
缺失、主机不匹配或 YAML 错误都保留已有 config.json 并报错。
修改密文后先更新 system 声明/解密服务，再运行 Home activation；已有
解密文件不会因 Git 中的密文变化而自动刷新。配置合并不会自动重启 Paseo。
foreign distro 需要自行用 SOPS 解密并向 Home 指定该私密 YAML 路径。

合并、删除和路径展开规则见 [Paseo 文档](../paseo/daemon-guide.md) 与
[通用配置模块文档](../config/json-config-guide.md)。
