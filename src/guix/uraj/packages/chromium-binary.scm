(define-module (uraj packages chromium-binary)
  #:use-module (guix gexp)
  #:export (isolate-chromium-wrapper-environment))

;;; nonguix's chromium-binary-build-system wraps every bin/ entry so that
;;; LD_LIBRARY_PATH and PATH list all inputs, glibc included.  Electron
;;; passes its environment to every child it spawns, so on a foreign distro
;;; a host program such as /bin/bash starts with the host's ld.so but Guix's
;;; libc.so.6, and dies on its first fork.
;;;
;;; The patchelf phase has already put the inputs' lib/ directories in the
;;; RUNPATH of the wrapper-plan files, which dlopen also consults, so the
;;; variables are redundant.  The exception is NSS, whose libraries live in
;;; lib/nss; add that to every file whose RUNPATH points at NSS.  Keep
;;; FONTCONFIG_PATH and ELECTRON_OZONE_PLATFORM_HINT, which are harmless to
;;; children.
(define (isolate-chromium-wrapper-environment phases)
  "Return PHASES with a phase that drops LD_LIBRARY_PATH and PATH from the
Chromium wrappers in bin/."
  #~(modify-phases #$phases
      (add-after 'install-wrapper 'isolate-wrapper-environment
        (lambda* (#:key inputs outputs #:allow-other-keys)
          (let* ((out (assoc-ref outputs "out"))
                 (nss (assoc-ref inputs "nss"))
                 (nss-lib (string-append nss "/lib"))
                 (open-pipe* (@ (ice-9 popen) open-pipe*))
                 (close-pipe (@ (ice-9 popen) close-pipe))
                 (get-string-all (@ (ice-9 textual-ports) get-string-all)))
            (define (regular-file? file stat)
              (eq? 'regular (stat:type stat)))
            (define (runpath file)
              (let* ((pipe (open-pipe* "r" "patchelf" "--print-rpath" file))
                     (result (get-string-all pipe)))
                (close-pipe pipe)
                (string-trim-right result)))
            (define (chromium-wrapper? file)
              (and (not (elf-file? file))
                   (string-contains
                    (call-with-input-file file get-string-all)
                    "ELECTRON_OZONE_PLATFORM_HINT")))
            (for-each
             (lambda (file)
               (when (string-contains (runpath file) nss-lib)
                 (invoke "patchelf" "--add-rpath"
                         (string-append nss-lib "/nss") file)))
             (find-files out (lambda (file stat)
                               (and (regular-file? file stat)
                                    (elf-file? file)))))
            (for-each
             (lambda (wrapper)
               (substitute* wrapper
                 (("^export (LD_LIBRARY_PATH|PATH)=.*$") "")))
             (find-files (string-append out "/bin")
                         (lambda (file stat)
                           (and (regular-file? file stat)
                                (chromium-wrapper? file))))))))))
