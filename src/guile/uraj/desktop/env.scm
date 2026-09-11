(define-module (uraj desktop env)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-26)
  #:export (desktop-container-envs))

(define (socket? file)
  (let ((info (stat file #f)))
    (and info (eq? (stat:type info) 'socket))))

(define (owned-by-me? path)
  (let ((info (stat path #f)))
    (and info (eq? (stat:uid info) (getuid)))))

(define (session-runtime-dir)
  (let ((dir (or (getenv "XDG_RUNTIME_DIR")
                 (string-append "/run/user/" (number->string (getuid))))))
    (and (owned-by-me? dir) dir)))

(define (display-number display)
  ;; ":0.0" or "host:0.0" → "0"
  (let ((last (last (string-split display #\:))))
    (first (string-split last #\.))))

(define (desktop-container-envs)
  "Detect the host's display and audio facilities.

Return (shares . env): shares is a list of --share=SPEC strings, env a list
of VAR=VALUE strings; both empty when nothing is detected."
  (let* ((display (getenv "DISPLAY"))
         (x11? (and display
                    (socket? (string-append "/tmp/.X11-unix/X"
                                            (display-number display)))))
         (xauth (or (getenv "XAUTHORITY")
                    (and=> (getenv "HOME")
                           (cut string-append <> "/.Xauthority"))))
         (xauth? (and xauth (file-exists? xauth)))
         ;; Wayland, PipeWire/PulseAudio and the session bus all live under
         ;; $XDG_RUNTIME_DIR, so share it as a whole.
         (rtd (session-runtime-dir))
         (wayland (getenv "WAYLAND_DISPLAY"))
         (wayland-socket (and rtd wayland
                              (if (string-prefix? "/" wayland)
                                  wayland
                                  (string-append rtd "/" wayland))))
         (wayland? (and wayland-socket (socket? wayland-socket)))
         (bus? (and rtd (socket? (string-append rtd "/bus")))))
    (cons (append (if x11? '("--share=/tmp/.X11-unix") '())
                  (if xauth? (list (string-append "--share=" xauth)) '())
                  (if rtd (list (string-append "--share=" rtd)) '()))
          (append (if x11? (list (string-append "DISPLAY=" display)) '())
                  (if xauth? (list (string-append "XAUTHORITY=" xauth)) '())
                  (if rtd (list (string-append "XDG_RUNTIME_DIR=" rtd)) '())
                  (if wayland? (list (string-append "WAYLAND_DISPLAY=" wayland)) '())
                  (if bus? (list (string-append "DBUS_SESSION_BUS_ADDRESS=unix:path="
                                                rtd "/bus")) '())))))

