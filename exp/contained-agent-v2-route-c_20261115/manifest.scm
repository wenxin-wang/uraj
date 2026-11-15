;; Box contents for the route C probe: a Paseo daemon, a socket forwarder,
;; a reaping init and what the probe runs inside the box.  Build with
;; `guix package -L src/guix -m ...' from the repository root.
(use-modules (gnu packages)
             (guix profiles)
             (uraj packages llm))

(concatenate-manifests
 (list (packages->manifest (list paseo))
       (specifications->manifest
        '("socat" "catatonit" "git" "bash" "coreutils" "grep" "sed"
          "findutils" "procps" "curl" "nss-certs" "iproute2"))))
