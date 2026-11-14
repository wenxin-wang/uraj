# 飞书 SDK 解析失败的排查

如果日志出现 `Cannot find package '@larksuiteoapi/node-sdk' imported from /app/dist/...`，说明运行时从该路径无法解析飞书 SDK，即使
`config validate` 成功也不能证明插件可加载。检查构建阶段是否安装了
该版本飞书插件声明的运行依赖，以及最终镜像是否保留了依赖和有效的
符号链接。修复镜像构建后，先通过上面的离线导入检查，再更新下面部署
配置中的 image ID；只替换 tag 不会改变固定 image ID 的服务。

不要为了在线补装依赖而取消整个容器的只读设置。若同时出现 Doctor
的 `EROFS` 错误，仍需定位其写入路径；SDK 导入成功不代表维护或迁移
已经成功。日志也可能在 `/var/log/messages`，可用
`sudo grep 'openclaw/' /var/log/messages | tail -n 80` 查看。
