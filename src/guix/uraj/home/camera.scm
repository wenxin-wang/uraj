(define-module (uraj home camera)
  #:use-module (gnu home services)
  #:use-module (gnu home services shepherd)
  #:use-module (gnu packages gnome)       ;libnotify
  #:use-module (gnu packages video)       ;v4l-utils
  #:use-module (gnu services)
  #:use-module (guix gexp)
  #:export (camera-privacy-home-services))

;;; Laptop webcams with a hardware kill (lappie's F11, handled by the
;;; firmware/EC: no frames and no LED afterwards) report it through the
;;; read-only UVC privacy control -- 1 while killed -- while the USB
;;; device and /dev/video* stay present.  Nothing on the desktop shows
;;; that state, so it is announced as a desktop notification.
;;;
;;; The state is read on demand rather than polled: uvcvideo runs the
;;; status interrupt endpoint, through which the camera reports privacy
;;; changes, only while the device is powered for an ioctl or a stream,
;;; so a control-event subscription stays silent while the camera
;;; autosuspends, and polling would keep resuming the USB device.  The
;;; kill key also sends KEY_CAMERA (asus-nb-wmi maps lappie's F11, WMI
;;; code 0x85, to it), which niri binds to this program (XF86WebCam in
;;; env/dotfiles/desktop/niri); a session service runs it once more at
;;; login with --startup.  Each read resumes the USB device for the
;;; autosuspend delay but does not start streaming, so the camera LED
;;; stays off.

(define (camera-privacy-notify)
  (program-file "camera-privacy-notify"
    #~(begin
        (use-modules (ice-9 ftw)
                     (ice-9 popen)
                     (ice-9 rdelim)
                     (ice-9 regex)
                     (srfi srfi-1))

        (define v4l2-ctl #$(file-append v4l-utils "/bin/v4l2-ctl"))
        (define notify-send #$(file-append libnotify "/bin/notify-send"))

        (define startup?
          (member "--startup" (cdr (command-line))))

        (define (video-nodes)
          (map (lambda (name) (string-append "/dev/" name))
               (or (scandir "/dev"
                            (lambda (name)
                              (string-match "^video[0-9]+$" name)))
                   '())))

        (define (privacy-state node)
          "Return 'killed or 'live for NODE's privacy control, or #f if
NODE has none (metadata nodes, webcams without a kill switch)."
          (let* ((port (with-error-to-file "/dev/null"
                         (lambda ()
                           ;; Nodes without the control complain.
                           (open-pipe* OPEN_READ v4l2-ctl "-d" node
                                       "-C" "privacy"))))
                 (line (read-line port)))
            (close-pipe port)
            (and (string? line)
                 (let ((match (string-match "^privacy: ([01])$" line)))
                   (and match
                        (if (string=? (match:substring match 1) "1")
                            'killed
                            'live))))))

        (define (camera-state)
          "Return 'killed if any camera reports its kill, 'live if some
camera has the control, #f if none has."
          (let ((states (filter-map privacy-state (video-nodes))))
            (cond ((memq 'killed states) 'killed)
                  ((null? states) #f)
                  (else 'live))))

        (define (notify state)
          (let ((killed? (eq? state 'killed)))
            (system* notify-send "--app-name=camera"
                     (if killed? "--icon=camera-off" "--icon=camera-web")
                     (if killed? "摄像头已关闭" "摄像头已恢复")
                     (if killed?
                         "硬件开关已切断摄像头"
                         "硬件开关已放开摄像头，可以被应用使用"))))

        ;; One press can deliver the key twice (~50 ms apart), so runs
        ;; are serialized on a lock file that also records the last
        ;; announcement; the same state again within a few seconds is
        ;; that duplicate and stays quiet.
        (define lock-file
          (string-append (or (getenv "XDG_RUNTIME_DIR") "/tmp")
                         "/camera-privacy-" (number->string (getuid))))

        (if startup?
            (when (eq? (camera-state) 'killed)
              (notify 'killed))
            (let ((port (open-file lock-file "a+")))
              (flock port LOCK_EX)
              ;; Give the firmware time to switch the camera before
              ;; reading the control the key press is about.
              (usleep 500000)
              (let* ((state (camera-state))
                     (previous (begin (seek port 0 SEEK_SET)
                                      (read port)))
                     (now (current-time)))
                (cond
                 ((not state)
                  (format (current-error-port)
                          "camera-privacy-notify: no camera reports a privacy control~%"))
                 ((and (pair? previous)
                       (eq? (car previous) state)
                       (< (- now (cdr previous)) 3))
                  #t)
                 (else
                  (notify state)
                  (truncate-file port 0)
                  (write (cons state now) port)
                  (force-output port))))
              (close-port port))))))

(define (camera-privacy-startup-service)
  (shepherd-service
   (documentation "Notify at login when a webcam is hardware-killed.")
   (provision '(camera-privacy))
   (requirement '(dbus graphical-session))
   (one-shot? #t)
   (modules '((shepherd support)))
   (start #~(make-forkexec-constructor
             (list #$(camera-privacy-notify) "--startup")
             #:log-file
             (in-vicinity %user-log-dir "camera-privacy.log")
             #:environment-variables (environ)))))

(define (camera-privacy-home-services)
  "Return the Home services that announce webcam hardware kill switch
state: ~/.local/bin/camera-privacy-notify for the compositor's
KEY_CAMERA binding, and a session one-shot that runs it at login."
  (list (simple-service 'camera-privacy-notify
                        home-files-service-type
                        `((".local/bin/camera-privacy-notify"
                           ,(camera-privacy-notify))))
        (simple-service 'camera-privacy
                        home-shepherd-service-type
                        (list (camera-privacy-startup-service)))))
