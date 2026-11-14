# 附件：daemon 仍在主机上运行时的过渡做法

For the transition while Paseo still runs on the host, stop the old daemon
and start it with the same launcher in host mode (with the broker running):

```sh
paseo_service=$(guix build -L src/guix -L src/guile \
  -e '(@ (uraj home paseo) paseo-service-program)')
"$paseo_service" run-host
```

Alternatively, start the existing host daemon with
`TMPDIR="$HOME/.cache/paseo-tmp" paseo daemon run` after creating that directory
with mode 0700. Both methods require the updated contained-agent Home/broker
launcher. Restart providers after the directory exists and the new launcher
is selected; existing containers retain their old mounts. Resend images that
were materialized under the old temporary directory. Setting `TMPDIR` only
on the provider or broker does not change where Paseo writes images.
