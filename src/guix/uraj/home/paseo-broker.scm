(define-module (uraj home paseo-broker)
  #:use-module (gnu home services)
  #:use-module (gnu home services shepherd)
  #:use-module (gnu packages commencement)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages python)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix build-system trivial)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (uraj utils file path)
  #:use-module (uraj packages ssh)
  #:export (paseo-broker-home-services paseo-broker-bundle
            broker-program paseo-broker-clients supervisor
            paseo-askpass-environment))

(define supervisor
  (computed-file
   "paseo-agent-supervisor"
   (with-imported-modules '((guix build utils))
     #~(begin
         (use-modules (guix build utils))
         (setenv "PATH" #$(file-append gcc-toolchain "/bin"))
         (invoke #$(file-append gcc-toolchain "/bin/gcc")
                 "-isystem" #$(file-append linux-libre-headers "/include")
                 "-Wall" "-Wextra" "-Werror" "-O2"
                 #$(local-file (project-path "src/c/uraj/paseo/agent-supervisor.c"))
                 "-o" #$output)))))

(define broker-source
  (local-file (project-path "src/python/uraj/paseo/broker.py")))

(define (broker-program launcher)
  (program-file
   "paseo-broker"
   #~(let ((args (cdr (command-line))))
       (if (and (pair? args) (member (car args) '("status" "configure")))
           (apply execl #$(file-append python "/bin/python3") "python3"
                  #$broker-source args)
           (apply execl #$(file-append python "/bin/python3") "python3"
                  #$broker-source "serve" "--shared-ssh"
                  "--supervisor" #$supervisor "--launcher" #$launcher
                  (if (and (pair? args) (string=? (car args) "serve"))
                      (cdr args) args))))))

(define (provider-client provider)
  (program-file
   (string-append "paseo-" provider)
   #~(apply execl #$(file-append python "/bin/python3") "python3"
            #$broker-source "client" #$provider (cdr (command-line)))))

(define paseo-broker-clients
  (package
    (name "paseo-broker-clients")
    (version "1")
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list #:builder
           #~(begin
               (mkdir #$output)
               (mkdir (string-append #$output "/bin"))
               (symlink #$(provider-client "codex")
                        (string-append #$output "/bin/paseo-codex"))
               (symlink #$(provider-client "claude")
                        (string-append #$output "/bin/paseo-claude")))))
    (home-page "https://paseo.sh")
    (synopsis "Paseo host broker clients")
    (description "Connect Paseo providers to the same-user execution broker.")
    (license license:gpl3+)))

;; Only host-side preparation receives the desktop's Secret Service access.
;; Explicit values take precedence over stale inherited askpass settings.
(define paseo-askpass-environment
  #~(cons* (string-append "SSH_ASKPASS="
                         #$(file-append ksshaskpass-with-qtkeychain
                                        "/bin/ksshaskpass"))
           "SSH_ASKPASS_REQUIRE=force"
           (filter (lambda (entry)
                     (not (or (string-prefix? "SSH_ASKPASS=" entry)
                              (string-prefix? "SSH_ASKPASS_REQUIRE=" entry))))
                   (environ))))

(define* (broker-shepherd-service program #:key (requirements '())
                                  (askpass? #f))
  (shepherd-service
   (provision '(paseo-broker))
   (requirement requirements)
   (documentation "Launch Paseo agents through owned PID namespaces.")
   (modules '((shepherd support) (srfi srfi-1) (srfi srfi-13)))
   (start #~(make-forkexec-constructor
             (list #$program)
             #:environment-variables #$(if askpass? paseo-askpass-environment
                                          #~(environ))
             #:log-file (in-vicinity %user-log-dir "paseo-broker.log")))
   (stop #~(make-kill-destructor))))

(define (paseo-broker-bundle launcher)
  "Build a trial bundle loadable by the user's existing Shepherd."
  (let* ((program (broker-program launcher))
         (definition (shepherd-service-file (broker-shepherd-service program))))
    (file-union
     "paseo-broker-bundle"
     `(("bin/paseo-broker" ,program)
       ("libexec/paseo-broker/codex" ,(provider-client "codex"))
       ("libexec/paseo-broker/claude" ,(provider-client "claude"))
       ("share/paseo-broker/shepherd.scm"
        ,(scheme-file
          "paseo-broker-trial.scm"
          #~(begin
              (use-modules (shepherd service))
              (register-services (list (primitive-load #$definition))))))))))

(define* (paseo-broker-home-services launcher #:key (autostart? #t)
                                     (requirements '()) (askpass? #f))
  "Install broker clients in the Home profile and optionally a user service.
Boot deployments start the broker through the root Shepherd instead."
  (let ((program (broker-program launcher)))
    (append (list
     (simple-service 'paseo-broker-profile home-profile-service-type
       (list paseo-broker-clients))
     (simple-service 'paseo-broker-files home-files-service-type
       `((".local/bin/paseo-broker" ,program)
         (".local/libexec/paseo-broker/codex" ,(provider-client "codex"))
         (".local/libexec/paseo-broker/claude" ,(provider-client "claude"))
         (".local/bin/paseo-broker-configure"
          ,(program-file
            "paseo-broker-configure"
            #~(apply execl #$(file-append python "/bin/python3") "python3"
                     #$broker-source "configure" (cdr (command-line))))))))
     (if autostart?
         (list (simple-service 'paseo-broker home-shepherd-service-type
                 (list (broker-shepherd-service
                        program #:requirements requirements #:askpass? askpass?))))
         '()))))
