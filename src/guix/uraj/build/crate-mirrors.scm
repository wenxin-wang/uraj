(define-module (uraj build crate-mirrors)
  #:use-module (ice-9 regex)
  #:use-module (srfi srfi-1)
  #:export (crate-mirror-urls call-with-crate-mirrors))

;; Use the crate name in the URL, not the Guix file name: the latter can
;; replace underscores with hyphens (hex_color becomes rust-hex-color).
(define (expand-crate-url url)
  (let ((match (or (string-match
                    "^https://crates.io/api/v1/crates/([A-Za-z0-9_-]+)/([A-Za-z0-9.+_-]+)/download$"
                    url)
                   (string-match
                    "^https://static.crates.io/crates/([A-Za-z0-9_-]+)/\\1-([A-Za-z0-9.+_-]+)\\.crate$"
                    url))))
    (if match
        (let ((name (match:substring match 1))
              (version (match:substring match 2)))
          (list (string-append "https://rsproxy.cn/api/v1/crates/"
                               name "/" version "/download")
                (string-append "https://mirror.sjtu.edu.cn/crates.io/crates/"
                               name "/" name "-" version ".crate")
                url))
        (list url))))

(define (crate-mirror-urls urls)
  (let ((expanded (delete-duplicates
                   (append-map expand-crate-url
                               (if (string? urls) (list urls) urls)))))
    (if (and (string? urls) (equal? expanded (list urls)))
        urls
        expanded)))

(define (call-with-crate-mirrors thunk)
  ;; The daemon's original perform-download retains its privilege checks,
  ;; derivation parsing, mirror fallback and expected hashes.  Only the URLs
  ;; passed to its downloader change, in this short-lived helper process.
  (let* ((module (resolve-module '(guix build download)))
         (fetch (module-ref module 'url-fetch)))
    (dynamic-wind
      (lambda ()
        (module-set! module 'url-fetch
                     (lambda (urls . args)
                       (apply fetch (crate-mirror-urls urls) args))))
      thunk
      (lambda () (module-set! module 'url-fetch fetch)))))
