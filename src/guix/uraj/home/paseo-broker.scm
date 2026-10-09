(define-module (uraj home paseo-broker)
  #:use-module (gnu home services)
  #:use-module (gnu home services shepherd)
  #:use-module (gnu packages commencement)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages python)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (guix gexp)
  #:use-module (uraj utils file path)
  #:export (paseo-broker-home-services paseo-broker-bundle))

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

(define (broker-shepherd-service program)
  (shepherd-service
   (provision '(paseo-broker))
   (documentation "Launch Paseo agents through owned PID namespaces.")
   (modules '((shepherd support)))
   (start #~(make-forkexec-constructor
             (list #$program)
             #:environment-variables (environ)
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

(define (paseo-broker-home-services launcher)
  "Install the local broker and separate Paseo provider clients.  The host
Paseo daemon is unchanged; select these clients in its provider configuration."
  (let ((program (broker-program launcher)))
    (list
     (simple-service 'paseo-broker-files home-files-service-type
       `((".local/bin/paseo-broker" ,program)
         (".local/libexec/paseo-broker/codex" ,(provider-client "codex"))
         (".local/libexec/paseo-broker/claude" ,(provider-client "claude"))
         (".local/bin/paseo-broker-configure"
          ,(program-file
            "paseo-broker-configure"
            #~(apply execl #$(file-append python "/bin/python3") "python3"
                     #$broker-source "configure" (cdr (command-line)))))))
     (simple-service 'paseo-broker home-shepherd-service-type
       (list (broker-shepherd-service program))))))
