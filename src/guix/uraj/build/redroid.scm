;;; Android checks; networking is owned by restricted-network.
(define-module (uraj build redroid)
  #:use-module (guix build utils)
  #:use-module (ice-9 textual-ports)
  #:export (prepare-redroid))

(define (prepare-redroid data render-node)
  (unless (string-contains (call-with-input-file "/proc/filesystems" get-string-all)
                           "binder")
    (error "Running kernel lacks binderfs; enable/load Binder before starting redroid"))
  (unless (and (file-exists? render-node)
               (eq? 'char-special (stat:type (stat render-node))))
    (error "Intel render device is missing" render-node))
  ;; Protect the parent, not Android's data directory: Android owns its
  ;; contents and permissions, including across container recreation.
  (umask #o077)
  (mkdir-p (dirname data))
  (mkdir-p data))
