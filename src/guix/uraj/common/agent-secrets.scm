(define-module (uraj common agent-secrets)
  #:use-module (guix gexp)
  #:use-module (ice-9 ftw)
  #:use-module (srfi srfi-1)
  #:use-module (uraj utils file path)
  #:export (github-token-directory
            %sandbox-policies
            sandbox-policy-file
            sandbox-policy-hosts
            sandbox-policy-secret))

;;; SOPS secrets of contained-agent and the Paseo daemon, see
;;; secrets/README.org.  (uraj system secrets) decrypts them on the hosts
;;; that have them.  The programs using them know which hosts these are
;;; and, on them, wait for each file at runtime instead of starting without
;;; it: at boot they may run before SOPS is done.  The host is checked at
;;; runtime because a Home is not always built on the machine it is for.

(define (on-hosts hosts value)
  #~(and (member (gethostname) '#$hosts) #$value))

(define (github-token-directory)
  "Return a gexp evaluating at runtime to the directory of the GitHub token
tiers on Guix System, whose agent hosts all declare them with
github-token-secrets, else to #f: foreign distros have no SOPS service."
  #~(and (file-exists? "/run/current-system") "/run/secrets/github"))

;;; Host-private sandbox policies, in secrets/hosts/HOST/FILE.
(define %sandbox-policies
  ;; (NAME FILE KEY PATH): KEY in FILE is decrypted to PATH.
  '((contained-agent "contained-agent.yaml" ("contained-agent" "projects.scm")
                     "/run/secrets/contained-agent/projects.scm")
    (paseo "paseo.yaml" ("paseo" "sandbox.scm")
           "/run/secrets/paseo/sandbox.scm")))

(define (policy name)
  (or (assq name %sandbox-policies)
      (error "unknown sandbox policy" name)))

(define (sandbox-policy-file host name)
  "Return the SOPS file holding policy NAME for HOST, which may not exist."
  (project-path
   (string-append "secrets/hosts/" host "/" (second (policy name)))))

(define (sandbox-policy-hosts name)
  "Return the hosts that have policy NAME."
  (filter (lambda (host) (file-exists? (sandbox-policy-file host name)))
          (or (scandir (project-path "secrets/hosts")
                       (lambda (entry) (not (string-prefix? "." entry))))
              '())))

(define (sandbox-policy-secret name)
  "Return a gexp evaluating at runtime to the decrypted path of policy NAME
on the hosts that have it, else to #f."
  (on-hosts (sandbox-policy-hosts name) (fourth (policy name))))
