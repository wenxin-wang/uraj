;;; guix repl -L src/guix -L src/guile test/guix/uraj/services/paseo.scm
(use-modules (gnu) (gnu home) (gnu home services)
             (gnu services) (gnu services shepherd)
             (guix gexp) (guix packages) (srfi srfi-1) (srfi srfi-64)
             (uraj services paseo) (uraj system home))

(define (lookup all name)
  (find (lambda (s) (memq name (shepherd-service-provision s))) all))
(define (keyword-value expression keyword)
  (cadr (memq keyword expression)))
(define (services os)
  (shepherd-configuration-services
   (service-value (fold-services (operating-system-services os)
                                #:target-type shepherd-root-service-type))))
(unsetenv "TO_ISO")
(define storie (load (string-append (getcwd) "/env/guix/os/storie.scm")))
(define installed (services storie))
(define homes
  (service-value
   (find (lambda (s) (eq? (service-kind s) guix-home-with-environment-service-type))
         (operating-system-user-services storie))))
(define home (cadr (assoc "wenxin" homes)))
(define profile-packages
  (service-value (fold-services (home-environment-services home)
                                #:target-type home-profile-service-type)))

(test-begin "paseo")
(test-equal "daemon depends on host broker" '(paseo-broker)
  (shepherd-service-requirement (lookup installed 'paseo)))
(test-equal "storie broker waits for wenxin Home, not old data storage"
  '(user-processes networking guix-daemon guix-home-wenxin)
  (shepherd-service-requirement (lookup installed 'paseo-broker)))
(for-each
 (lambda (name)
   (let* ((s (lookup installed name))
          (start (gexp->approximate-sexp (shepherd-service-start s))))
     (test-equal (format #f "~a runs as wenxin" name) "wenxin"
       (keyword-value start #:user))
     (test-equal (format #f "~a uses wenxin Home" name) "/home/wenxin"
       (keyword-value start #:directory))
     (test-assert (format #f "~a starts at boot" name)
       (shepherd-service-auto-start? s))))
 '(paseo paseo-broker))
(test-assert "no old data mount preparation"
  (not (lookup installed 'paseo-preparation)))
(test-assert "no dedicated paseo account"
  (not (find (lambda (user) (string=? (user-account-name user) "paseo"))
             (operating-system-user-accounts storie))))
(for-each
 (lambda (name)
   (test-assert (string-append "wenxin profile contains " name)
     (find (lambda (package) (string=? (package-name package) name)) profile-packages)))
 '("paseo" "paseo-broker-clients" "codex" "claude-code"))
(let* ((account (user-account (name "test-user") (group "users")
                             (home-directory "/srv/test-home")))
       (config (paseo-user-configuration account)))
  (test-equal "project paths derive from target account Home"
    '("/srv/test-home/src" "/srv/test-home/Projects"
      "/srv/test-home/.local/share/paseo/worktrees")
    ((@@ (uraj services paseo) paseo-roots) config))
  (test-equal "Home dependency derives from target account"
    '(user-processes networking guix-daemon guix-home-test-user)
    ((@@ (uraj services paseo) paseo-requirements) config)))
(test-assert "agents cannot request persistent broker state"
  ((@@ (uraj bin contained-agent) denied?)
   (string-append (getenv "HOME") "/.local/state/paseo-broker")))
(define failures (test-runner-fail-count (test-runner-current)))
(test-end "paseo")
(exit (if (zero? failures) 0 1))
