(use-modules (uraj utils file template)
             (ice-9 ftw)
             (ice-9 textual-ports))

(define tmp-dir (string-append "/tmp/uraj-template-ut-" (number->string (getpid))))
(mkdir tmp-dir)

(define (delete-recursively dir)
  (file-system-fold
   (lambda (path stat result) #t)
   (lambda (path stat result) (delete-file path))
   (lambda (path stat result) #t)
   (lambda (path stat result) (rmdir path))
   (lambda (path stat result) #t)
   (lambda (path stat errno result) #t)
   #t
   dir))

(define (w path str)
  (call-with-output-file path (lambda (p) (put-string p str))))
(define (r path)
  (call-with-input-file path get-string-all))
(define (p name)
  (string-append tmp-dir "/" name))

(define failures '())

(define (check label expected actual)
  (if (equal? expected actual)
      (format #t "~a: ok~%" label)
      (begin
        (set! failures (cons label failures))
        (format #t "~a: FAILED~%  expected: ~s~%  actual:   ~s~%"
                label expected actual))))

(define a.tmpl (p "a.tmpl"))
(define target (p "target.conf"))

;; 1. fresh file
(w a.tmpl "hello\nworld\n")
(ensure-template-block-in-file a.tmpl target)
(check "fresh-file"
       (string-append "# BEGIN-BLOCK: " a.tmpl "\nhello\nworld\n"
                      "# END-BLOCK: " a.tmpl "\n")
       (r target))

;; 2. re-run with changed template replaces block in place
(w a.tmpl "hello2\n")
(ensure-template-block-in-file a.tmpl target)
(check "replace"
       (string-append "# BEGIN-BLOCK: " a.tmpl "\nhello2\n"
                      "# END-BLOCK: " a.tmpl "\n")
       (r target))

;; 3. block in the middle stays in place, surrounding content kept
(w target (string-append "keep me\n# BEGIN-BLOCK: " a.tmpl "\nold\n"
                         "# END-BLOCK: " a.tmpl "\ntail\n"))
(ensure-template-block-in-file a.tmpl target)
(check "in-place"
       (string-append "keep me\n# BEGIN-BLOCK: " a.tmpl "\nhello2\n"
                      "# END-BLOCK: " a.tmpl "\ntail\n")
       (r target))

;; 4. block at the very top stays at the top
(w target (string-append "# BEGIN-BLOCK: " a.tmpl "\nold\n"
                         "# END-BLOCK: " a.tmpl "\ntail\n"))
(ensure-template-block-in-file a.tmpl target)
(check "at-top"
       (string-append "# BEGIN-BLOCK: " a.tmpl "\nhello2\n"
                      "# END-BLOCK: " a.tmpl "\ntail\n")
       (r target))

;; 5. no trailing newline in existing file, no trailing newline in template
(define b.tmpl (p "b.tmpl"))
(w b.tmpl "noline")
(w (p "target2.conf") "x")
(ensure-template-block-in-file b.tmpl (p "target2.conf"))
(check "trailing-newline"
       (string-append "x\n# BEGIN-BLOCK: " b.tmpl "\nnoline\n"
                      "# END-BLOCK: " b.tmpl "\n")
       (r (p "target2.conf")))

;; 6. custom comment-str
(define c.tmpl (p "c.tmpl"))
(w c.tmpl "c\n")
(ensure-template-block-in-file c.tmpl (p "target3.conf") #:comment-str "//")
(check "comment-str"
       (string-append "// BEGIN-BLOCK: " c.tmpl "\nc\n"
                      "// END-BLOCK: " c.tmpl "\n")
       (r (p "target3.conf")))

;; 7. orphan begin marker (no end): treated as absent, block appended
(w (p "target4.conf") (string-append "before\n# BEGIN-BLOCK: " a.tmpl "\norphan\n"))
(ensure-template-block-in-file a.tmpl (p "target4.conf"))
(check "orphan-begin"
       (string-append "before\n# BEGIN-BLOCK: " a.tmpl "\norphan\n"
                      "# BEGIN-BLOCK: " a.tmpl "\nhello2\n"
                      "# END-BLOCK: " a.tmpl "\n")
       (r (p "target4.conf")))

;; 8. empty template content
(define e.tmpl (p "e.tmpl"))
(w e.tmpl "")
(ensure-template-block-in-file e.tmpl (p "target5.conf"))
(check "empty-template"
       (string-append "# BEGIN-BLOCK: " e.tmpl "\n# END-BLOCK: " e.tmpl "\n")
       (r (p "target5.conf")))

;; 9. parent dir created
(ensure-template-block-in-file a.tmpl (p "sub/dir/target.conf"))
(check "parent-dir" #t (file-exists? (p "sub/dir/target.conf")))

(delete-recursively tmp-dir)

(if (null? failures)
    (begin
      (display "all template tests passed")
      (newline))
    (begin
      (format #t "~a test(s) failed~%" (length failures))
      (exit 1)))
