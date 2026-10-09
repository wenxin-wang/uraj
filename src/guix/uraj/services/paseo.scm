;;; A host broker and a Guix application container, started at boot.
(define-module (uraj services paseo)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system accounts)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (srfi srfi-1)
  #:use-module (uraj home llm)
  #:use-module (uraj home paseo)
  #:use-module (uraj home paseo-broker)
  #:export (paseo-configuration paseo-service-type paseo-user-configuration))

(define-record-type* <paseo-configuration>
  paseo-configuration make-paseo-configuration paseo-configuration?
  (user paseo-user (default "wenxin"))
  (group paseo-group (default "users"))
  (home paseo-home (default "/home/wenxin"))
  (roots paseo-roots (default '("/home/wenxin/src" "/home/wenxin/Projects")))
  (listen paseo-listen (default "127.0.0.1:6767"))
  (environment paseo-environment (default '()))
  (requirements paseo-requirements
                (default '(user-processes networking guix-daemon guix-home-wenxin))))

(define* (paseo-user-configuration account #:key (listen "127.0.0.1:6767"))
  "Use ACCOUNT's existing Home; account and Home activation are owned by the OS."
  (let ((name (user-account-name account))
        (directory (user-account-home-directory account)))
    (paseo-configuration
     (user name)
     (group (user-account-group account))
     (home directory)
     (roots (map (lambda (name) (string-append directory "/" name))
                 '("src" "Projects")))
     (listen listen)
     (requirements
      (list 'user-processes 'networking 'guix-daemon
            (string->symbol (string-append "guix-home-" name)))))))

(define (launch-program config command)
  (program-file
     (string-append "paseo-" command "-launch")
     #~(begin
         (setenv "HOME" #$(paseo-home config))
         (setenv "USER" #$(paseo-user config))
         (setenv "LOGNAME" #$(paseo-user config))
         (setenv "PATH" (string-append #$(paseo-home config)
                                      "/.guix-home/profile/bin:/run/current-system/profile/bin"))
         (setenv "PASEO_LISTEN" #$(paseo-listen config))
         (setenv "PASEO_WEB_UI_ENABLED" "true")
         (for-each (lambda (entry) (setenv (car entry) (cdr entry)))
                   '#$(paseo-environment config))
         #$(if (string=? command "broker")
               #~(execl #$(broker-program contained-agent) "paseo-broker" "serve"
                        #$@(append-map (lambda (root) (list "--root" root))
                                      (paseo-roots config)))
               #~(execl #$paseo-service-program "paseo-service" "run"
                        "--guix" "/run/current-system/profile/bin/guix"
                        "--profile" #$paseo-daemon-profile
                        #$@(append-map (lambda (root) (list "--root" root))
                                      (paseo-roots config)))))))

(define (paseo-shepherd-services config)
  (let ((user (paseo-user config)) (group (paseo-group config)))
    (list
      (shepherd-service
       (provision '(paseo-broker))
       (requirement (paseo-requirements config))
       (documentation "Launch same-user coding agents outside the Paseo container.")
       (start #~(make-forkexec-constructor
                 (list #$(launch-program config "broker"))
                 #:user #$user #:group #$group
                 #:directory #$(paseo-home config)
                 #:log-file "/var/log/paseo-broker.log"))
       (stop #~(make-kill-destructor)))
      (shepherd-service
       (provision '(paseo))
       (requirement '(paseo-broker))
       (documentation "Run Paseo in a Guix container sharing the host network.")
       (start #~(make-forkexec-constructor
                 (list #$(launch-program config "daemon"))
                 #:user #$user #:group #$group
                 #:directory #$(paseo-home config)
                 #:log-file "/var/log/paseo.log"))
       (stop #~(make-kill-destructor))))))

(define paseo-service-type
  (service-type
   (name 'paseo)
   (extensions (list (service-extension shepherd-root-service-type paseo-shepherd-services)))
   (default-value (paseo-configuration))
   (description "Paseo application container and host broker for an existing user.")))
