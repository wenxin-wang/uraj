;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2021 Marius Bakke <marius@gnu.org>
;;; Copyright © 2025 Denis 'GNUtoo' Carikli <GNUtoo@cyberdimension.org>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (gnu system images am335x-evm)
  #:use-module (gnu bootloader u-boot)
  #:use-module (gnu bootloader)
  #:use-module (gnu image)
  #:use-module (gnu packages bootloaders)
  #:use-module (gnu packages linux)
  #:use-module (gnu services base)
  #:use-module (gnu services networking)
  #:use-module (gnu services)
  #:use-module (gnu system file-systems)
  #:use-module (gnu system image)
  #:use-module (gnu system)
  #:use-module (guix platforms arm)
  #:use-module (srfi srfi-26)
  #:export (am335x-evm-barebones-os
            am335x-evm-image-type
            am335x-evm-barebones-raw-image))

;; See the comment in u-boot-am335x-evm-bootloader to know which computers are
;; supported by this image.
(define am335x-evm-barebones-os
  (operating-system
    (host-name "guadalajara")
    (timezone "Europe/Madrid")
    (locale "en_US.utf8")
    (bootloader (bootloader-configuration
                 (bootloader u-boot-am335x-evm-bootloader)
                 (targets '("/dev/sda"))))
    (initrd-modules '())
    (kernel linux-libre-arm-generic)
    (file-systems (cons (file-system
                          (device (file-system-label "my-root"))
                          (mount-point "/")
                          (type "ext4"))
                        %base-file-systems))
    (services (append (list
                       (service
                        agetty-service-type
                        (agetty-configuration
                          (extra-options '("-L")) ;no carrier detect
                          (baud-rate "115200")
                          (term "vt100")
                          (tty "ttyS0")))
                       (service dhcpcd-service-type))
                      %base-services))))

(define am335x-evm-image-type
  (image-type
    (name 'am335x-evm-raw)
    (constructor (lambda (os)
                   (image
                     ;; Reserve 4 MiB for the partition table and the
                     ;; bootloader.
                     (inherit (raw-with-offset-disk-image (expt 2 22)))
                     (operating-system os)
                     (platform armv7-linux))))))

(define am335x-evm-barebones-raw-image
  (image
   (inherit
    (os+platform->image am335x-evm-barebones-os armv7-linux
                        #:type am335x-evm-image-type))
   (name 'am335x-evm-barebones-raw-image)))

am335x-evm-barebones-raw-image
