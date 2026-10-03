(define-module (uraj services desktop)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services dbus)
  #:use-module (gnu system pam)
  #:use-module (guix gexp)
  #:use-module (srfi srfi-1)
  #:export (greetd-with-elogind-service-type
            bluetooth-gatt-release-service))

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
