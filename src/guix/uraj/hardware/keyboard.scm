;;; keyboard.scm -- udev hwdb key remaps shared by all desktop machines.

(define-module (uraj hardware keyboard)
  #:use-module (gnu services base)        ;file->udev-hardware, udev-hardware-service
  #:use-module (guix gexp)                ;local-file
  #:use-module (uraj utils file path)     ;project-path
  #:export (%keyboard-remap-hwdb-service))

;;; hwdb remaps keys per input device, at the kernel-input level, so
;;; they hold in the console and in every graphical session alike, with
;;; no per-user daemon.  The udev service unions every
;;; lib/udev/hwdb.d directory and compiles them into /etc/udev/hwdb.bin
;;; while the system is built: the remap below is part of the
;;; generation, and reaches already-connected keyboards with
;;; `udevadm trigger'.

;;; The three left-edge modifiers are rotated on every keyboard I use:
;;; physical Caps Lock acts as left Shift, physical left Shift as left
;;; Ctrl, and physical left Ctrl as Caps Lock.  Same remap, two
;;; encodings: AT scancodes (3a/2a/1d) for internal PS/2-style
;;; keyboards, HID usage codes (70039/700e1/700e0) for USB keyboards.
;;; Within a record, consecutive match lines are ORed (each is a trie
;;; path to the same property set), so one record covers every device
;;; sharing an encoding.  The "61-" prefix keeps this file after the
;;; upstream 60-keyboard.hwdb, so it wins on equal-length matches.
;;;
;;; The remap itself lives in env/desktop/61-keyboard-local.hwdb,
;;; shared with the Ansible basic-system role that deploys it on
;;; foreign-distro desktops; edit it there.
(define %keyboard-remap-hwdb-service
  (udev-hardware-service
   'keyboard-remap
   (file->udev-hardware
    "61-keyboard-local.hwdb"
    (local-file (project-path "env/desktop/61-keyboard-local.hwdb")))))
