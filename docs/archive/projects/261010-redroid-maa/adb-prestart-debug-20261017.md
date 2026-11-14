# 先启动 ADB server 的原因

Start the ADB server explicitly before MaaCore: in the first live test,
letting MaaCore spawn it left a communication pipe open in the background
server and delayed connection by a minute. Prestarting it connected in one
second.
