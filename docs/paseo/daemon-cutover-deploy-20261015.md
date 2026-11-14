# Paseo daemon: first transition

> 旧文档：只读，不再更新。现状见 [daemon-guide.md](daemon-guide.md)。

## First transition and operation

Finish active sessions before switching: broker/daemon shutdown ends provider
processes. Close the desktop app and stop its old daemon, or on storie stop
the old system service **before** reconfiguration:

```sh
sudo herd stop paseo
```

Reconfigure the corresponding Guix System as usual. Reboot selects the new
service graph. When applying without reboot, load the new Shepherd service
definitions through the normal reconfiguration workflow before starting them:

```sh
sudo herd start paseo
sudo herd status paseo-broker
sudo herd status paseo
tail -n 100 /var/log/paseo/broker.log   # no sudo for log-readers
tail -n 100 /var/log/paseo/paseo.log
```

On a desktop machine, also stop any manually loaded trial/user broker before
starting the system broker. Normal system Homes no longer register duplicate
user broker services. Foreign Home uses `herd` without `sudo` and user logs.
The broker runtime directory is `~/.local/state/paseo-broker`, independent of
elogind/login lifetime; `PASEO_BROKER_DIRECTORY` overrides it for isolated tests.

After a broker upgrade, start `paseo` again as well: stopping its dependency
stops the daemon. Encrypted SSH keys still need a working host-side askpass
setup. A boot service has no graphical session environment by default; explicit
broker environment configuration is required for such prompts.
