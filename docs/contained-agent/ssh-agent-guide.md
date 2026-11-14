# Per-project SSH agents

Only the central `projects.scm` or host-private `projects.local.scm` may
declare `ssh-agent`.  Even an approved
`.guix/contained-agent.scm` cannot request it.  For example (replace these
example key paths with keys you provision on the host).  Put this in
`~/.config/contained-agent/projects.local.scm` to keep it out of Git and
the Guix store:

```scheme
(project "~/src/uraj"
  (ssh-agent
    ;; Optional; defaults to ~/.ssh/known_hosts.
    (known-hosts "~/.ssh/known_hosts")
    (identity "~/.ssh/uraj-deploy"
      (destinations "git@github.com"))
    (identity "~/.ssh/dev-servers"
      (destinations "wenxin@a.xx.com" "wenxin@b.xx.com"))))
```

An optional `(client-config STRING)` holds literal SSH client configuration,
including multiline strings.  For example, inside the same `ssh-agent` clause:

```scheme
(client-config "Host dev.example.com
    HostName 192.0.2.1
    User wenxin
    Port 23333
    HostKeyAlias [dev.example.com]:23333

Host github.com
    User git

Host *
    IdentitiesOnly no
    ForwardAgent no
    AddKeysToAgent no
    StrictHostKeyChecking yes
")
```

The corresponding identity still needs
`(destinations "[dev.example.com]:23333")`.  SSH client configuration does
not change how `ssh-add -h` looks up host keys.  `client-config` is text, not
a filename; quotes and backslashes use Scheme string escaping.  Only one
such clause is allowed.  Its contents are written to a mode-0600 file in the
project's private runtime directory and mounted read-only as `~/.ssh/config`.
The text is never shell-expanded or evaluated by SSH on the host.  It is
interpreted by SSH inside the container, including any commands it specifies.
If omitted, the generated config is empty.  Editing the string changes the
policy fingerprint and reloads the project agent on the next launch.  A live
agent keeps its socket and the config file is rewritten in place, so existing
containers also see the update.

Each `destinations` contains one or more alternatives.  Each becomes a
separate `ssh-add -h` argument for that identity.  No identity may omit its
destinations or supply an empty list.  Paths must be absolute or start with
`~/`.  Private keys remain on the host; the supplied client config, public
host-key data and selected agent socket enter the container.

After Home reconfigure, normal agent startup automatically starts the
project's SSH agent and loads its configured keys on the host, before entering
the container.  Later sessions reuse it while the configuration is unchanged.
The following host commands are optional management tools:

```sh
contained-agent ssh-start ~/src/uraj   # explicitly reload keys, or unlock in advance
contained-agent ssh-socket ~/src/uraj   # prints the host socket path
# Stop it; a later session with ssh-agent configured will start it again:
contained-agent ssh-stop ~/src/uraj
```

`ssh-start` starts a dedicated background OpenSSH agent and loads the keys;
encrypted keys use ssh-add's terminal/askpass prompt.  It prints the socket
path, never shell code to evaluate.  A failed key load stops the new agent.
Starting it again reuses the live process/socket, runs `ssh-add -D` to clear
all identities (including manually added ones), then loads the current policy.
The config and known_hosts files are also updated in place to preserve existing
bind mounts.  A successful reload needs no container restart.  Reload is not
atomic: new authentication may briefly fail while keys are absent or loading;
existing SSH connections remain established.  If clearing or loading fails,
the agent is stopped so no partial set of keys remains.  Reopen containers
after a stopped/dead agent is recreated, since that produces a new socket inode.
Agents otherwise persist between sessions until
stopped or the host shuts down; this is not a Shepherd autostart service.

The host socket is
`$XDG_RUNTIME_DIR/contained-agent/<32-hex-path-hash>/ssh.sock`.  If
`XDG_RUNTIME_DIR` is unset, `/run/user/UID` is used; the runtime directory
must already exist, belong to the user, and be private.  The hash uses the
canonical current worktree path, so linked worktrees get separate agents
and sockets, even when they share a Git repository.  No extra project
name is needed.  A host-side lock serializes lifecycle operations.

Session startup checks, under the project lock, for an agent with a matching
policy and known_hosts snapshot.  A missing agent is started; a changed policy
or known_hosts file clears and reloads its keys automatically.  Concurrent
launches reuse the same process; the project lock serializes reloads.
Replacing key material at the same filename also requires `ssh-start`.
`--version` and `auth status` probes skip SSH provisioning.  Encrypted keys still require
ssh-add's terminal or host askpass prompt.  Automatic loading has stdin set
to `/dev/null` and stdout redirected to stderr so it cannot consume or corrupt
Paseo's protocol stream.  Without an available unlock mechanism it fails and
suggests `ssh-start` on the host; no partial agent is kept.  To permanently
disable automatic SSH access, remove the central clause and stop the agent.

The above host lifecycle applies to direct terminal use.  The
[Paseo broker](../paseo/broker-guide.md) instead keeps a separate shared SSH
service; direct `ssh-start` and `ssh-stop` do not manage its cache.

In the container:
- `SSH_AUTH_SOCK=/run/contained-agent/ssh.sock` selects only this project.
- The socket is an individual read-only bind mount (read-only does not
  prevent socket connections).  No parent runtime directory is exposed.
- A read-only snapshot is mounted as `~/.ssh/known_hosts`; it reveals the
  entries in the selected known_hosts file.  Use a dedicated file to limit
  that list.  Private keys and the host's original SSH config remain absent.
- The optional `client-config` string supplies the container's `~/.ssh/config`.
  Put connection settings here rather than inheriting the host's IdentityFile
  or forwarding configuration.
- `openssh` joins the container packages.  Normal `ssh` and Git SSH remotes
  use the socket and known_hosts without additional flags.

An empty `(ssh-agent)` clause creates an empty agent for manual host-side
loading.  Use `SSH_AUTH_SOCK="$(contained-agent ssh-socket DIR)" ssh-add ...`.
In this mode it is your responsibility to pass `-h` constraints when loading
keys.  The container can use the socket's management operations too (for
example, deleting loaded keys); this is not a signing-only proxy.

### Destination patterns

Constraints use the native [ssh-add(1)](https://man.openbsd.org/ssh-add.1) syntax, including `user@host` and
`source>user@destination` forwarding hops.  Strings are passed as arguments,
never expanded by a shell.

For a non-default port, match the known_hosts spelling, for example
`(destinations "[hypie.example.com]:23333")`.  This selects the host-key
record; the SSH connection still needs `-p 23333`.  Loading errors preserve
ssh-add's original stderr and include the identity path, destination list,
and source known_hosts path.  They are not assumed to be password errors.

Wildcards such as `*.xx.com` need compatible known_hosts records; ssh-add
does not enumerate ordinary `a.xx.com` and `b.xx.com` records to expand the
pattern.  A usual wildcard setup uses a trusted host-certificate CA entry
such as `@cert-authority *.xx.com KEY`.  Without that setup, list individual
hosts.  Missing host keys fail loading; the wrapper never fetches or trusts
host keys automatically.  Hosts are authenticated by keys/certificates,
not merely by a DNS suffix.  A constraint to `git@github.com` does not limit
repositories: use a repository-scoped deploy key for that.

Tests: [development-guide](development-guide.md).
