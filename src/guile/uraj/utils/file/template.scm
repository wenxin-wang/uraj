(define-module (uraj utils file template)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:export (ensure-template-block-in-file))

(define (ensure-trailing-newline str)
  (if (string-suffix? "\n" str) str (string-append str "\n")))

(define (drop-trailing-empty-lines lines)
  (let loop ((lines (reverse lines)))
    (if (and (pair? lines) (string-null? (car lines)))
        (loop (cdr lines))
        (reverse lines))))

(define (content-lines str)
  (if (string-null? str)
      '()
      (drop-trailing-empty-lines
       (string-split (ensure-trailing-newline str) #\newline))))

(define (lines->file-string lines)
  (let ((joined (string-join lines "\n")))
    (if (or (null? lines) (string-null? (last lines)))
        joined
        (string-append joined "\n"))))

(define (split-block lines begin-marker end-marker)
  "If LINES contains a line equal to BEGIN-MARKER followed, possibly not
immediately, by one equal to END-MARKER, return the pair (BEFORE . AFTER) of
the lines surrounding that block.  Otherwise return #f."
  (let loop ((lines lines) (before-rev '()))
    (cond
     ((null? lines) #f)
     ((string=? (car lines) begin-marker)
      (let scan-end ((rest (cdr lines)))
        (cond
         ((null? rest) #f)
         ((string=? (car rest) end-marker)
          (cons (reverse before-rev) (cdr rest)))
         (else (scan-end (cdr rest))))))
     (else (loop (cdr lines) (cons (car lines) before-rev))))))

(define (mkdir-p dir)
  (let ((parent (dirname dir)))
    (unless (or (string=? dir parent) (file-exists? dir))
      (mkdir-p parent)
      (mkdir dir))))

(define* (ensure-template-block-in-file template-path target-file-path
                                        #:key (comment-str "#")
                                        (label template-path))
  "Make sure TARGET-FILE-PATH contains a block delimited by lines
\"COMMENT-STR BEGIN-BLOCK: LABEL\" and \"COMMENT-STR END-BLOCK: LABEL\" whose
content is the content of TEMPLATE-PATH.  An existing block with the same
markers is replaced in place; otherwise the block is appended at the end of
the file."
  (let* ((begin-marker (string-append comment-str " BEGIN-BLOCK: " label))
         (end-marker (string-append comment-str " END-BLOCK: " label))
         (template-lines
          (content-lines (call-with-input-file template-path get-string-all)))
         (existing-content (if (file-exists? target-file-path)
                               (call-with-input-file target-file-path get-string-all)
                               ""))
         (existing-lines (if (string-null? existing-content)
                             '()
                             (string-split existing-content #\newline)))
         (block-lines (cons begin-marker
                            (append template-lines (list end-marker))))
         (split (split-block existing-lines begin-marker end-marker))
         (new-content (if split
                          (lines->file-string
                           (append (car split) block-lines (cdr split)))
                          (lines->file-string
                           (append (drop-trailing-empty-lines existing-lines)
                                   block-lines)))))
    (mkdir-p (dirname target-file-path))
    (call-with-output-file target-file-path
      (lambda (port) (put-string port new-content)))))
