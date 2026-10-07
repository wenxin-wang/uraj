(define-module (uraj services desktop)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services dbus)
  #:use-module (gnu services shepherd)
  #:use-module (gnu system pam)
  #:use-module (guix gexp)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (greetd-with-elogind-service-type
            bluetooth-gatt-release-service
            backlight-schedule-service))

;; Use only with elogind-service-type: it adds pam_elogind to the PAM
;; services and owns /run/user/$UID.  Stock greetd also appends a global
;; pam_mount transformer, mounting another tmpfs over the same directory.
;; Keep greetd's PAM service, omit its pam_mount transformer, and leave
;; elogind's independent PAM extension intact.  Do not transform the final
;; PAM stack: extension order should not decide whether pam_mount survives.
(define greetd-with-elogind-service-type
  (service-type
    (inherit greetd-service-type)
    (extensions
     (map (lambda (extension)
            (if (eq? (service-extension-target extension)
                     pam-root-service-type)
                (service-extension
                 pam-root-service-type
                 (lambda (config)
                   (filter pam-service?
                           ((service-extension-compute extension) config))))
                extension))
          (service-type-extensions greetd-service-type)))))

(define bluetooth-gatt-release-service
  (simple-service
   'bluetooth-gatt-release dbus-root-service-type
   (list
    (file-union
     "bluetooth-gatt-release-policy"
     `(("etc/dbus-1/system.d/bluez-gatt-release.conf"
        ,(plain-file
          "bluez-gatt-release.conf"
          "<!DOCTYPE busconfig PUBLIC \"-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN\"\n  \"http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd\">\n<busconfig>\n  <policy user=\"root\">\n    <allow send_type=\"method_call\"\n           send_interface=\"org.bluez.GattProfile1\"\n           send_member=\"Release\"/>\n  </policy>\n</busconfig>\n")))))))

;;; Guix has no systemd-backlight equivalent, so drivers come up at their
;;; firmware default brightness on every boot.  This daemon goes a step
;;; further and remembers two levels per backlight device: the last one set
;;; by hand during the day and during the night.  It applies the current
;;; period's level at boot (or as soon as the device appears), switches to
;;; the other one at sunrise/sunset, and otherwise only records manual
;;; changes -- a change after a switch becomes the new level for that
;;; period.  Levels are checked every minute, at each switch (before
;;; applying the other period's level) and when the service stops at
;;; shutdown.  Restored levels are clamped to at least 5% of the maximum so
;;; a saved 0 cannot leave the panel dark.
;;;
;;; The day/night boundaries are given as "HH:MM" strings in local time.
;;; noctalia watches the sysfs brightness file, so its slider follows.
;;; Machines without backlight devices just idle.

(define (hh:mm->minutes str)
  (match (map string->number (string-split str #\:))
    (((? integer? h) (? integer? m)) (+ (* 60 h) m))
    (_ (error "backlight-schedule: invalid HH:MM time" str))))

(define (backlight-schedule-program sunrise sunset)
  (program-file "backlight-schedule"
    #~(begin
        (use-modules (ice-9 ftw)
                     (ice-9 textual-ports))

        (define sysfs "/sys/class/backlight")
        (define check-seconds 60)
        (define fade-steps 20)
        (define fade-step-us 100000)

        (define state-dir "/var/lib/backlight")

        (define (report fmt . args)
          (apply format #t fmt args)
          (newline)
          (force-output))

        (define (read-number file)
          (false-if-exception
           (string->number
            (string-trim-both (call-with-input-file file get-string-all)))))

        (define (write-number file n)
          (false-if-exception
           (call-with-output-file file
             (lambda (port) (display n port)))))

        ;; Minutes after midnight.
        (define sunrise #$(hh:mm->minutes sunrise))
        (define sunset #$(hh:mm->minutes sunset))

        (define (seconds-of-day)
          (let ((now (localtime (current-time))))
            (+ (* 3600 (tm:hour now)) (* 60 (tm:min now)) (tm:sec now))))

        (define (current-period)
          (let ((minutes (quotient (seconds-of-day) 60)))
            (if (if (< sunrise sunset)
                    (and (>= minutes sunrise) (< minutes sunset))
                    (not (and (>= minutes sunset) (< minutes sunrise))))
                "day"
                "night")))

        ;; Sleep until the next check: a minute, or just past the next
        ;; sunrise/sunset if that comes first.
        (define (seconds-until-next-check)
          (let ((now (seconds-of-day)))
            (define (until boundary)
              (let ((delta (modulo (- (* 60 boundary) now) 86400)))
                (if (zero? delta) 86400 delta)))
            (min check-seconds
                 (+ 1 (min (until sunrise) (until sunset))))))

        (define (devices)
          (or (scandir sysfs (lambda (f) (not (string-prefix? "." f))))
              '()))

        (define (device-file name file)
          (string-append sysfs "/" name "/" file))

        (define (saved-file name period)
          (string-append state-dir "/" name "." period))

        (define (fade! name from to)
          (let ((file (device-file name "brightness")))
            (let loop ((i 1))
              (when (<= i fade-steps)
                (write-number file (+ from (quotient (* (- to from) i)
                                                     fade-steps)))
                (usleep fade-step-us)
                (loop (+ i 1))))))

        ;; Per device: (period . last level seen or set by us).
        (define seen (make-hash-table))

        ;; A level that differs from the last one seen was set by hand:
        ;; remember it for the period it was set in.
        (define (remember! name current)
          (let ((last (hash-ref seen name)))
            (when (and last (not (= current (cdr last))))
              (report "~a: remember ~a for ~a" name current (car last))
              (write-number (saved-file name (car last)) current)
              (hash-set! seen name (cons (car last) current)))))

        (define (check!)
          (let ((period (current-period)))
            (for-each
             (lambda (name)
               (let ((current (read-number (device-file name "brightness")))
                     (limit (read-number (device-file name "max_brightness"))))
                 (when (and current limit (> limit 0))
                   (remember! name current)
                   (let ((last (hash-ref seen name)))
                     ;; Startup (or the device just appeared) or a
                     ;; day/night switch: apply this
                     ;; period's remembered level.
                     (unless (and last (string=? (car last) period))
                       (let* ((saved (read-number (saved-file name period)))
                              (target (and saved
                                           (min limit
                                                (max saved
                                                     (quotient limit 20))))))
                         (if (and target (not (= target current)))
                             (begin
                               (report "~a: ~a, ~a -> ~a"
                                       name period current target)
                               (fade! name current target)
                               (hash-set! seen name (cons period target)))
                             (hash-set! seen name (cons period current)))))))))
             (devices))))

        ;; Shutdown: keep a change made since the last check.
        (sigaction SIGTERM
          (lambda (signal)
            (for-each
             (lambda (name)
               (let ((current (read-number (device-file name "brightness"))))
                 (when current
                   (remember! name current))))
             (devices))
            (primitive-exit 0)))

        (let mkdir-p ((dir state-dir))
          (unless (file-exists? dir)
            (mkdir-p (dirname dir))
            (mkdir dir)))
        (let loop ()
          (check!)
          (sleep (seconds-until-next-check))
          (loop)))))

(define (backlight-schedule-service sunrise sunset)
  "Return a service that keeps per-device day and night backlight levels,
switching between them at SUNRISE and SUNSET (\"HH:MM\" strings)."
  (simple-service
   'backlight-schedule shepherd-root-service-type
   (list
    (shepherd-service
     (documentation
      "Remember day and night backlight levels and switch between them.")
     (provision '(backlight-schedule))
     (requirement '(udev file-systems))
     (start #~(make-forkexec-constructor
               (list #$(backlight-schedule-program sunrise sunset))
               #:log-file "/var/log/backlight-schedule.log"))
     (stop #~(make-kill-destructor))))))
