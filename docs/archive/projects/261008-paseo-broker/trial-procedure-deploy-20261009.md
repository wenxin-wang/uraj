# broker 试用包的构建、加载和回退步骤

In a host terminal on lappie, as wenxin (no sudo), build a GC-rooted trial:

```sh
cd ~/src/uraj
mkdir -p ~/.local/state
paseo_bundle=$(guix build -L src/guix -L src/guile \
  -r "$HOME/.local/state/paseo-broker-trial" \
  -e '((@ (uraj home paseo-broker) paseo-broker-bundle) (@@ (uraj home llm) contained-agent))')
herd load root "$paseo_bundle/share/paseo-broker/shepherd.scm"
herd start paseo-broker
"$paseo_bundle/bin/paseo-broker" status
```

These explicit trial commands load and start the service in the existing user
Shepherd.  Normal Home reconfiguration installs the profile clients and automatically
merges their commands into Paseo configuration. On Guix System the root
Shepherd owns the boot service; foreign Home registers user services. Do not
load a trial broker alongside either managed service.  Replacing a running broker
can end its executions; finish them before deploying a new service definition.

Managed brokers run Home's `~/.local/bin/contained-agent`, resolved for each
execution, so a Home reconfigure reaches new sessions without a broker restart;
running sessions keep their launcher.  Changes to the broker or supervisor still
need one.  So do changes to `contained-agent ssh-service`, which stays running
for the broker's lifetime, and new launchers must keep working with it until
then.  The trial bundle above keeps its own store launcher.

Switch only the two provider commands after successful version probes:

```sh
"$paseo_bundle/bin/paseo-broker" configure \
  --client-directory "$paseo_bundle/libexec/paseo-broker"
```

This reads existing \~/.paseo/config.json, probes both clients, writes a private
backup beside the file, preserves other provider/settings fields and replaces
the configuration atomically.  Managed symlink configs are refused.  It prints
the backup path.  No daemon restart is hidden in this command.

After allowing current sessions to finish, restart Paseo and create a new agent:

```sh
paseo daemon restart
"$paseo_bundle/bin/paseo-broker" status
```

Check a small prompt, interrupt a turn and continue, then close the session and
check its execution disappears.  Closing the app with daemon retained should
not remove it.  Provider sessions can remain idle between turns: idle does not
mean their process should have exited.  The restart can end the current agent,
so execute it only after this implementation conversation has finished.

Restore only provider command fields from the printed backup if needed:

```sh
"$paseo_bundle/bin/paseo-broker" configure --restore /path/to/printed/backup
paseo daemon restart
herd stop paseo-broker
```
