;;; keyboard.scm -- udev hwdb key remaps shared by all desktop machines.

(define-module (uraj hardware keyboard)
  #:use-module (gnu services base)  ;udev-hardware, udev-hardware-service
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
(define %keyboard-remap-hwdb-service
  (udev-hardware-service
   'keyboard-remap
   (udev-hardware "61-keyboard-local.hwdb"
"evdev:atkbd:dmi:bvnLENOVO:bvrN2XET33W*
evdev:input:b0011v0001p0001*
  KEYBOARD_KEY_3a=leftshift
  KEYBOARD_KEY_2a=leftctrl
  KEYBOARD_KEY_1d=capslock

evdev:input:b0003v413Cp2113*
evdev:input:b0003v17EFp6047*
evdev:input:b0003v258Ap0013*
evdev:input:b0003v05ACp024F*
evdev:input:b0003v048DpC100*
  KEYBOARD_KEY_70039=leftshift
  KEYBOARD_KEY_700e1=leftctrl
  KEYBOARD_KEY_700e0=capslock
")))
