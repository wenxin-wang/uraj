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

(define (stale-block-label lines begin-prefix suffix)
  "Return the label of the first block in LINES whose begin marker starts with
BEGIN-PREFIX and whose label ends with SUFFIX, or #f."
  (any (lambda (line)
         (and (string-prefix? begin-prefix line)
              (let ((label (string-drop line (string-length begin-prefix))))
                (and (string-suffix? suffix label) label))))
       lines))

(define (relabel-stale-blocks lines comment-str label)
  "Blocks used to be labeled by the absolute template path, so moving the
checkout left a duplicate block behind.  Give the first block in LINES whose
label is a path ending in \"/LABEL\" the current LABEL, keeping its position,
and drop the other such blocks."
  (let* ((begin-prefix (string-append comment-str " BEGIN-BLOCK: "))
         (end-prefix (string-append comment-str " END-BLOCK: "))
         (begin-marker (string-append begin-prefix label))
         (end-marker (string-append end-prefix label))
         (suffix (string-append "/" label)))
    (let loop ((lines lines))
      (let* ((old (stale-block-label lines begin-prefix suffix))
             (split (and old
                         (split-block lines
                                      (string-append begin-prefix old)
                                      (string-append end-prefix old)))))
        (cond
         ((not split) lines)
         ((split-block lines begin-marker end-marker)
          (loop (append (car split) (cdr split))))
         (else
          (loop (append (car split)
                        (list begin-marker end-marker)
                        (cdr split)))))))))

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
         (existing-lines (relabel-stale-blocks
                          (if (string-null? existing-content)
                              '()
                              (string-split existing-content #\newline))
                          comment-str label))
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
