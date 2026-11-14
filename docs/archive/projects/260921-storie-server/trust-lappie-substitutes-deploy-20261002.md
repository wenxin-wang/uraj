# storie 首次信任 lappie 的 substitutes

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
