# agents 网络改名为 static-agent

The former `agents` / `br-agents` network is now named
`static-agent` / `br-static-agent`.  Reserve `br-agent` for the future
contained-agent bridge so its permissions can be configured independently.
The singular spelling keeps `br-static-agent` within Linux's 15-character
interface-name limit while retaining the `br-` plus network-name convention.
An existing deployment must follow the offline topology migration below;
changing the declaration does not rename a live Docker bridge.
