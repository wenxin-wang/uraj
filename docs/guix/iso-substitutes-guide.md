# Live ISO 的内网 substitutes

## Live ISO 的内网 substitutes

运行 `maak -f env/guix/os/maak.scm build-iso [配置路径]` 时，ISO 会信任
构建机的 `/etc/guix/signing-key.pub`，并开启 Avahi 自动发现。
公钥不存在时直接跳过，ISO 仍可正常构建；存在时需要可读。
私钥不会加入 ISO。

desktop/server 的共享配置发布本机 store：HTTP TCP 8080，并通过
Avahi 广播。现有机器需要先 reconfigure 到新配置才会启动发布服务。
如果从其他发行版构建 ISO，需要在那台构建机另外运行 Avahi 和
`guix publish --advertise`（监听内网地址，端口 8080）。

在同一局域网中放行发布端 TCP 8080，以及双方 UDP 5353/mDNS；启动
ISO 后，`guix system init` 或 `guix system reconfigure` 就能发现并
使用构建机现存、路径匹配的 substitutes。构建机须保持在线，且产物
未被 GC。缺少的产物仍可能需要外网或本地构建。

构建机公钥仅加入 live 系统的信任配置；普通系统配置不会读取或信任
它。storie 另行显式信任仓库中的 `keys/lappie-signing-key.pub`，并开启
substitute 自动发现，以便安装后继续使用 lappie 的构建产物。

在 lappie 的仓库根目录构建自定义 Docker（两端使用相同的仓库和 lock）：

```sh
guix time-machine -C env/guix/channels-lock.scm -- build -L src/guix \
  -e '(@ (uraj packages docker) docker-full)'
```

已有 storie 系统首次启用此配置时，先同步仓库，再在 storie 上执行：

```sh
sudo guix archive --authorize < env/guix/os/keys/lappie-signing-key.pub
# 将下方地址替换为 lappie 当前的内网地址；首次部署显式指定发布端。
sudo -E guix time-machine -C env/guix/channels-lock.scm -- \
  system reconfigure -L src/guix -L src/guile env/guix/os/storie.scm \
  --substitute-urls='http://172.31.0.133:8080 https://mirror.sjtu.edu.cn/guix-bordeaux https://mirror.sjtu.edu.cn/guix https://bordeaux.guix.gnu.org https://ci.guix.gnu.org https://substitutes.nonguix.org'
```

后续通过 Avahi 发现 lappie，无需固定其 IP。若 lappie 重新生成签名密钥，
需核对并更新仓库中的公钥。
