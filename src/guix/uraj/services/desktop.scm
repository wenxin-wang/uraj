(define-module (uraj services desktop)
  #:use-module (gnu services)
  #:use-module (gnu services dbus)
  #:use-module (guix gexp)
  #:export (bluetooth-gatt-release-service))

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
