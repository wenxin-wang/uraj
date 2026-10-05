;;; guix time-machine -C env/guix/channels-lock.scm -- repl -L src/guix test/guix/uraj/build/crate-mirrors.scm
(use-modules (srfi srfi-64)
             (guix build download)
             (uraj build crate-mirrors))

(test-begin "crate-mirrors")
(define upstream "https://crates.io/api/v1/crates/hex_color/3.0.0/download")
(define mirrors
  '("https://rsproxy.cn/api/v1/crates/hex_color/3.0.0/download"
    "https://mirror.sjtu.edu.cn/crates.io/crates/hex_color/hex_color-3.0.0.crate"))
(test-equal "priority and underscore preservation"
  (append mirrors (list upstream)) (crate-mirror-urls upstream))
(test-equal "static crates endpoint"
  (append mirrors '("https://static.crates.io/crates/hex_color/hex_color-3.0.0.crate"))
  (crate-mirror-urls "https://static.crates.io/crates/hex_color/hex_color-3.0.0.crate"))
(for-each
 (lambda (url)
   (test-equal "non-crate URLs unchanged" url (crate-mirror-urls url)))
 '("https://example.org/a.tar.gz" "mirror://gnu/hello.tar.gz"
   "https://crates.io.evil/api/v1/crates/a/1/download"
   "https://crates.io/api/v1/crates/../1/download"
   "https://crates.io/api/v1/crates/a/1/download?x=y"))
(test-equal "existing fallback retained, duplicates removed"
  (append mirrors (list upstream "https://example.org/archive"))
  (crate-mirror-urls (list upstream (car mirrors) "https://example.org/archive")))
(test-assert "versions with Cargo metadata"
  (string=? (car (crate-mirror-urls
                 "https://crates.io/api/v1/crates/toml/1.1.3+spec-1.1.0/download"))
            "https://rsproxy.cn/api/v1/crates/toml/1.1.3+spec-1.1.0/download"))

;; Exercise the binding used by upstream perform-download; preserve every
;; argument, especially expected hashes. Restore even when downloading fails.
(let* ((module (resolve-module '(guix build download)))
       (original (module-ref module 'url-fetch))
       (seen #f)
       (fake (lambda args (set! seen args) (throw 'download-failed))))
  (dynamic-wind
    (lambda () (module-set! module 'url-fetch fake))
    (lambda ()
      (catch 'download-failed
        (lambda ()
          (call-with-crate-mirrors
           (lambda ()
             (url-fetch upstream "/output" #:hashes '((sha256 . expected))))))
        (lambda _ #t))
      (test-equal "URL wrapper preserves output and hash arguments"
        (list (append mirrors (list upstream)) "/output"
              #:hashes '((sha256 . expected)))
        seen)
      (test-eq "restore downloader on exception" fake
        (module-ref module 'url-fetch)))
    (lambda () (module-set! module 'url-fetch original))))
(define failures (test-runner-fail-count (test-runner-current)))
(test-end "crate-mirrors")
(exit (if (zero? failures) 0 1))
