;;; guix repl -L src/guix test/guix/uraj/openclaw-runtime.scm
(use-modules (guix build utils) (ice-9 ftw) (json) (rnrs io ports)
             (srfi srfi-1) (srfi srfi-64) (uraj build openclaw))

(test-begin "openclaw-runtime")
(define root (mkdtemp "/tmp/openclaw-test-XXXXXX"))
(define pool (string-append root "/pool"))
(define data (string-append pool "/openclaw"))
(define runtime (string-append root "/runtime"))
(define engine-runtime (string-append root "/engine-runtime"))
(define acl-log (string-append root "/setfacl.log"))
(define setfacl (string-append root "/setfacl"))
(define resolver (string-append root "/resolv.conf"))
(define secret (string-append root "/secret"))
(define names '("feishu-app-secret" "new-api-token" "gateway-token"))
(define inputs (map (lambda (name) (cons name secret)) names))
(define (write path value)
  (call-with-output-file path (lambda (p) (display value p))))
(mkdir pool)
(write secret "test-credential\n")
(write setfacl (string-append "#!/bin/sh\necho \"$*\" >> " acl-log "\n"))
(chmod setfacl #o755)
(write resolver "nameserver 172.31.0.1\nnameserver 1.1.1.1\n")

;; Real files and permissions, but fake mount metadata and root-only chown.
;; Run as an ordinary user; never touch /data, /run, Docker or host mounts.
;; Replace the core binding: compiled modules reference it directly, so a
;; module-local definition would leave the real chown in place.
(define ownership '())
(module-set! (resolve-module '(guile)) 'chown
  (lambda (path uid gid) (set! ownership (cons (list path uid gid) ownership))))
(define (mount type)
  ((@@ (guix build syscalls) %mount) "test-device" pool 0 type '()))
(define* (prepare #:key (mounts (list (mount "btrfs"))))
  (prepare-openclaw data inputs #:runtime runtime #:resolver resolver
                    #:engine-runtime engine-runtime
                    #:sandbox-state '(".openclaw/sandbox/skills-workspaces")
                    #:uid 2010 #:gid 2011 #:readers 973 #:setfacl setfacl
                    #:data-mount pool #:current-mounts mounts))
(test-error "absent mount rejected" #t (prepare #:mounts '()))
(test-assert "mount failure creates no state" (not (file-exists? data)))
(test-error "wrong filesystem rejected" #t (prepare #:mounts (list (mount "ext4"))))
(delete-file secret)
(test-error "missing secret rejected" #t (prepare))
(test-assert "secret failure creates no state" (not (file-exists? data)))
(write secret "")
(test-error "empty secret rejected" #t (prepare))
(write secret "test-credential\n")
(for-each
 (lambda (value)
   (write resolver value)
   (test-error "invalid DNS snapshot rejected" #t (prepare))
   (test-assert "DNS failure creates no state" (not (file-exists? data))))
 '("" "nameserver 127.0.0.1\n" "nameserver ::1\n"
   "nameserver 169.254.1.1\n" "nameserver invalid\n" "search example.org\n"))
(write resolver "nameserver 172.31.0.1\nnameserver 1.1.1.1\n")
(prepare)
(test-equal "private runtime" #o700 (stat:perms (stat runtime)))
(test-equal "home private" #o700 (stat:perms (stat (string-append data "/home"))))
(for-each
 (lambda (part)
   (let ((path (string-append data "/home/" part)))
     (test-equal "sandbox state bind source private" #o700 (stat:perms (stat path)))
     (test-equal "sandbox state owned by the dedicated user" '(2010 2011)
       (cdr (find (lambda (e) (equal? path (car e))) ownership)))))
 '(".openclaw" ".openclaw/sandbox" ".openclaw/sandbox/skills-workspaces"))
(test-equal "engine storage private" #o700
  (stat:perms (stat (string-append data "/engine"))))
(test-equal "engine socket directory private" #o700
  (stat:perms (stat engine-runtime)))
(test-equal "readers may enter data, not other users" #o750
  (stat:perms (stat data)))
(for-each
 (lambda (path)
   ;; Group inheritance for reports; other-execute for crun under keep-id.
   (test-equal "workspace is setgid, reader-listable, traversable" #o2751
     (logand #o7777 (stat:perms (stat path)))))
 (list (string-append data "/workspaces") (string-append data "/workspaces/main")))
(define (owner path)
  (let ((entry (find (lambda (e) (equal? path (car e))) ownership)))
    (and entry (cdr entry))))
(test-equal "data owned by root and the reader group" '(0 973) (owner data))
(test-equal "home owned by the dedicated user" '(2010 2011)
  (owner (string-append data "/home")))
(test-equal "workspaces carry the reader group" '(2010 973)
  (owner (string-append data "/workspaces/main")))
(test-equal "engine owns its socket directory" '(2010 2011) (owner engine-runtime))
(test-assert "reader ACL applied to both workspace levels"
  (let ((log (call-with-input-file acl-log get-string-all)))
    (every (lambda (path)
             (string-contains log (string-append "-m g:973:rX,d:g:973:rX " path)))
           (list (string-append data "/workspaces")
                 (string-append data "/workspaces/main")))))
(test-assert "only expected paths change owner"
  (every (lambda (entry)
           (or (member (cadr entry) '(0 2010))
               (string-prefix? runtime (car entry))))
         ownership))
(for-each
 (lambda (name)
   (let ((path (string-append runtime "/" name)))
     (test-equal "SecretRef file private" #o400 (stat:perms (stat path)))
     (test-equal "SecretRef file regular" 'regular (stat:type (lstat path)))
     (test-equal "SecretRef file not hardlinked" 1 (stat:nlink (stat path)))))
 names)
(define* (dns #:optional (service "gateway"))
  (let ((json (call-with-input-file (string-append runtime "/compose-dns.json") json->scm)))
    (assoc-ref (assoc-ref (assoc-ref json "services") service) "dns")))
(test-equal "Docker receives the firewall resolver snapshot"
  '#("172.31.0.1" "1.1.1.1") (dns))
(test-equal "engine uses the same resolver snapshot"
  '#("172.31.0.1" "1.1.1.1") (dns "engine"))
(define note (string-append data "/workspaces/main/note"))
(write note "persist across restarts")
(write secret "rotated-test-credential\n")
(write resolver "nameserver 9.9.9.9\n")
(write (string-append engine-runtime "/podman.sock") "stale")
(prepare)
(test-assert "stale engine socket removed"
  (not (file-exists? (string-append engine-runtime "/podman.sock"))))
(test-equal "restart preserves workspace" "persist across restarts"
  (call-with-input-file note get-string-all))
(test-equal "restart refreshes DNS" '#("9.9.9.9") (dns))
(test-equal "restart replaces secret contents" "rotated-test-credential\n"
  (call-with-input-file (string-append runtime "/gateway-token") get-string-all))
(delete-file-recursively (string-append data "/home"))
(symlink pool (string-append data "/home"))
(test-error "container-controlled symlink is rejected" #t (prepare))
(delete-file (string-append data "/home"))

(define failures (test-runner-fail-count (test-runner-current)))
(delete-file-recursively root)
(test-end "openclaw-runtime")
(exit (if (zero? failures) 0 1))
