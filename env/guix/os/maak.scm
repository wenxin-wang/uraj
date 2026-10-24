(define-module (maak)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-26)
  #:use-module (uraj desktop env)
  #:use-module (uraj maak guix)
  #:use-module (uraj utils file path)
  #:export (deploy system-vm system-reconfigure build-iso home-container home-reconfigure))

(define* (system-vm #:optional (config-path (guix-env-path "os/qemu-example.scm")))
  ($guix `("system" "vm" ,config-path)))

(define* (system-reconfigure
          #:optional (config-path
                      (project-path
                       (string-append "env/guix/os/" (gethostname) ".scm")))
          #:rest args)
  ($guix `("system" "reconfigure" ,config-path ,@args)))

(define (with-environment-variable name value thunk)
  (let ((old-value (getenv name)))
    (dynamic-wind
      (lambda () (setenv name value))
      thunk
      (lambda ()
        (if old-value
            (setenv name old-value)
            (unsetenv name))))))

(define* (build-iso #:optional (config-path (guix-env-path "os/lappie.scm")))
  ;; The configuration itself performs the transformation.  Environment is
  ;; used because maak's CLI rejects task-specific --options.
  (with-environment-variable "TO_ISO" "1"
    (lambda ()
      ($guix `("system" "image" "-t" "iso9660" ,config-path)))))

(define* (home-container #:optional (config-path (guix-env-path "os/home.scm"))
	                 #:key (fork? (my-fork?))
                         (command '())
                         . args)
  "Run the home environment in a container, sharing the host's display and audio."
  (let ((command* (if (pair? args) args command)))
    (match (desktop-container-envs)
      ((shares . env)
       (let* ((script (and (pair? env)
                           (string-append
                            (string-join (map (cut string-append "export " <>) env) ";")
                            (if (null? command*) ";exec /proc/self/exe" ";"))))
              (head `("home" "container" ,config-path
                      ;; Only the fork supports this option.
                      ,@(if fork? '("--keep-host-uid-gid") '())
                      ,@shares))
              (tail (cond ((pair? env)    `("--" ,script ,@command*))
                          ((pair? command*) `("--" ,@command*))
                          (else            '()))))
         ($guix (append head tail) #:fork? fork?))))))

(define (default-home-config)
  ;; On Guix System hosts, deploy the Home embedded in the machine
  ;; configuration; elsewhere use the foreign-distro Home.
  (let ((machine (guix-env-path
                  (string-append "os/" (gethostname) ".scm"))))
    (if (file-exists? machine)
        machine
        (guix-env-path "os/home.scm"))))

(define* (home-reconfigure
          #:optional (config-path (default-home-config))
          #:rest args)
  ;; Machine configurations return their embedded Home for this target;
  ;; home.scm ignores it.
  (with-environment-variable "URAJ_DEPLOY_TARGET" "home"
    (lambda ()
      ($guix `("home" "reconfigure" ,config-path ,@args)))))

(define* (deploy #:optional (config-path (guix-env-path "os/lappie.scm")))
  ($guix `("deploy" ,config-path)))
