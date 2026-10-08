;;; Extra mounts and environment for contained-agent, per project (the
;;; repository's main work tree).  Only `read', never evaluated; ~ is the home
;;; directory, missing paths and unset variables are skipped.
;;;   (project ROOT (expose PATH ...) (share PATH ...) (preserve REGEXP ...)
;;;                 (guix-daemon))
;;; Projects may add the same clauses in .guix/contained-agent.scm, which
;;; count after `contained-agent allow'; see docs/contained-agent.org.
;;; Host-private additions (same project syntax, no reconfigure needed):
;;; ~/.config/contained-agent/projects.local.scm.  Keep identities and host
;;; names there; it is not deployed by Home or stored in this repository.
;;; Central configuration only may also declare:
;;;   (ssh-agent (identity "~/.ssh/project-key"
;;;                (destinations "git@github.com" "user@host.example")))
;;; Keys load automatically before entering the container.  To reload or
;;; unlock them in advance: `contained-agent ssh-start PROJECT' on the host.

(project "~/src/uraj"
  ;; Build/check Home, System, packages and locked channel environments.
  (guix-daemon)
  ;; Troubleshooting the System and Home this repository configures.
  (expose
   ;; System: logs (readable ones: messages via log-readers, guix build
   ;; logs under guix/drvs), the running and booted configurations, and
   ;; generations.
   "/var/log"
   "/run/current-system"
   "/run/booted-system"
   "/var/guix/profiles"
   ;; Home: service logs, the active generation, its shepherd config, and
   ;; the channels in use.
   "~/.local/state/shepherd"
   "~/.guix-home"
   "~/.config/shepherd"
   "~/.config/guix"))
