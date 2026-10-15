(define-module (uraj home paseo)
  #:use-module (gnu home services)
  #:use-module (gnu home services shepherd)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages base)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages nss)
  #:use-module (gnu packages python)
  #:use-module (gnu packages version-control)
  #:use-module (gnu packages ssh)
  #:use-module (gnu packages rust-apps)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix profiles)
  #:use-module (guix records)
  #:use-module (uraj common agent-secrets)
  #:use-module (uraj gexp)
  #:use-module (uraj home paseo-broker)
  #:use-module (uraj packages llm)
  #:use-module (uraj utils file path)
  #:export (paseo-setup paseo-setup-autostart? %paseo-setup
            paseo-service-program paseo-daemon-profile paseo-home-services
            paseo-sandbox-program))

;;; How a desktop session treats the Paseo stack.  Bind %paseo-setup around
;;; Home service construction: a <paseo-setup> record selects the managed
;;; stack (broker, daemon service and settings activation) and its daemon
;;; start policy; #f leaves the host app-managed, with the Paseo app
;;; running its own daemon and owning its provider settings.

(define-record-type* <paseo-setup>
  paseo-setup make-paseo-setup
  paseo-setup?
  (autostart? paseo-setup-autostart?        ;start the daemon at login?
              (default #t)))

(define %paseo-setup (make-parameter (paseo-setup)))

(define paseo-daemon-profile
  (profile
   (content (packages->manifest
             (list paseo paseo-broker-clients bash coreutils git nss-certs
                   procps openssh gh-git-credential)))))

;;; The daemon's own GitHub CLI configuration, mounted read-only over
;;; ~/.config/gh in its container instead of the host's (which holds the
;;; login).  Paseo only reads git_protocol from it, to pick clone URLs; HTTPS
;;; ones take the token of the daemon's (github TIER) policy clause.  A
;;; read-only directory also keeps `gh auth login' and aliases from
;;; persisting anything.
(define paseo-gh-config
  (file-union "paseo-gh-config"
              `(("config.yml"
                 ,(plain-file "config.yml"
                              "version: \"1\"\ngit_protocol: https\n")))))

(define paseo-sandbox-program
  (program-file
   "paseo-sandbox"
   (with-uraj-modules '((uraj bin paseo-sandbox))
     #~(begin
         (use-modules (uraj bin paseo-sandbox))
         (paseo-sandbox-main
          (cadr (command-line))
          (list (cons 'ssh-agent #$(file-append openssh "/bin/ssh-agent"))
                (cons 'ssh-add #$(file-append openssh "/bin/ssh-add"))
                (cons 'sha256sum #$(file-append coreutils "/bin/sha256sum"))
                (cons 'bash #$(file-append bash "/bin/bash")))
          #:github-secrets #$(github-token-directory))))))

(define paseo-python-modules
  (file-union
   "paseo-python-modules"
   `(("service.py" ,(local-file (project-path "src/python/uraj/paseo/service.py")))
     ("broker.py" ,(local-file (project-path "src/python/uraj/paseo/broker.py"))))))

(define paseo-service-program
  (program-file
   "paseo-service"
   #~(apply execl #$(file-append python "/bin/python3") "python3"
            "-c" "import sys; sys.path.insert(0, sys.argv.pop(1)); from service import main; main()"
            #$paseo-python-modules
            (append (cdr (command-line))
                    (list "--sandbox-helper" #$paseo-sandbox-program
                          "--supervisor" #$supervisor
                          "--gh-config" #$paseo-gh-config)
                    (let ((policy #$(sandbox-policy-secret 'paseo)))
                      (if policy (list "--sandbox-secret" policy) '()))))))

(define* (paseo-home-services #:key (desktop? #t) (autostart? #f) worktrees)
  (append
   (list
    (simple-service 'paseo-settings home-activation-service-type
      #~(invoke #$paseo-service-program "activate"
                #$@(if desktop? '("--desktop") '())
                #$@(if worktrees (list "--worktrees" worktrees) '()))))
   (if autostart?
       (list
        (simple-service 'paseo-daemon home-shepherd-service-type
          (list
           (shepherd-service
            (provision '(paseo))
            (requirement '(paseo-broker))
            (documentation "Run Paseo in a Guix application container.")
            (modules '((shepherd support) (srfi srfi-1) (srfi srfi-13)))
            (start #~(make-forkexec-constructor
                      (list #$paseo-service-program "run" "--guix" "guix"
                            "--profile" #$paseo-daemon-profile)
                      #:environment-variables #$(if desktop? paseo-askpass-environment
                                                   #~(environ))
                      #:log-file (in-vicinity %user-log-dir "paseo.log")))
            (stop #~(make-kill-destructor))))))
       '())))
