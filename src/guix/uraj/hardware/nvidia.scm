(define-module (uraj hardware nvidia)
  #:use-module (gnu home)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages compression)
  #:use-module (gnu packages gawk)
  #:use-module (gnu packages gl)
  #:use-module (guix base32)
  #:use-module (guix diagnostics)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix i18n)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 textual-ports)
  #:use-module (nonguix utils)
  #:use-module (nongnu packages nvidia)
  #:export (nvidia-host?
            home-transformation-nvidia))

;;; NVIDIA's proprietary driver is two halves that must be the exact same
;;; release: the kernel module loaded on the host (Ubuntu's
;;; nvidia-driver-580-open here) and the userspace libraries.  The host
;;; governs, so the userspace to install is not a constant: it is pinned
;;; per host module version in %nvidia-driver-pins and picked at
;;; evaluation time, which for a home config is on the machine being
;;; configured.
;;;
;;; nonguix packages that userspace as "nvda", a drop-in for Guix's
;;; "mesa": a union of libglvnd, a mesa built against the proprietary
;;; libs (mesa-for-nvda), the driver's own libraries and
;;; nvidia-vaapi-driver, carrying the search paths
;;; (__EGL_VENDOR_LIBRARY_DIRS, GBM_BACKENDS_PATH, LIBVA_DRIVERS_PATH,
;;; VK_*, ...) that point a session at it.  nonguix's own OS
;;; configuration swaps mesa for nvda *by grafting* -- rewriting the
;;; store paths inside already-built packages, no rebuilds -- and that is
;;; what home-transformation-nvidia does for a home-environment.
;;;
;;; Grafting substitutes store paths byte for byte, so origin and
;;; replacement must have equal-length names ("replacement length
;;; differs from the original length" otherwise): make-nvda pads its
;;; version to the length of mesa's -- nvda-580.12 against mesa-26.0.2 --
;;; which is where the oddly truncated version on grafted packages comes
;;; from.

(define* (nvidia-run-source version urls hash)
  "Return a package whose source is the userspace part of NVIDIA's
VERSION @file{.run} installer, fetched from URLS, verified against HASH,
and extracted with the bundled kernel modules and the libraries that
Guix packages already provide deleted.

This is the same extraction as @code{make-nvidia-source} in (nongnu
packages nvidia) -- keep the deletion list below in sync with it -- but
with explicit URLs: some releases (580.126.20, a Data Center branch
build) are published under .../tesla/ only, never under the .../XFree86/
paths that package assembles from the version."
  (define installer
    (origin
      (method url-fetch)
      (uri urls)
      (sha256 hash)))

  (package
    (inherit %binary-source)
    (version version)
    (source
     (origin
       (method (@@ (guix packages) computed-origin-method))
       (file-name (string-append "nvidia-driver-source-" version "-checkout"))
       (sha256 #f)
       (modules '((guix build utils)))
       (uri
        (delay
          (with-imported-modules '((guix build utils))
            #~(begin
                (use-modules (guix build utils))
                (set-path-environment-variable
                 "PATH" '("bin")
                 '#+(list bash-minimal coreutils-minimal gawk
                          grep tar which xz zstd))
                (invoke "sh" #+installer
                        "--extract-only" "--target" "extractdir")
                ;; Guix System builds the kernel modules from git; and
                ;; egl-gbm, egl-wayland, glvnd, nvidia-settings' GTK
                ;; panel, the OpenCL ICD loader are packages of their
                ;; own.
                (when (file-exists? "extractdir/kernel-open")
                  (delete-file-recursively "extractdir/kernel-open"))
                (for-each delete-file
                          (find-files "extractdir"
                                      (string-join
                                       '("libnvidia-egl-gbm\\.so\\."
                                         "libnvidia-egl-wayland\\.so\\."
                                         "libnvidia-egl-wayland2\\.so\\."
                                         "libnvidia-egl-xcb\\.so\\."
                                         "libnvidia-egl-xlib\\.so\\."
                                         "libEGL\\.so\\."
                                         "libGL\\.so\\."
                                         "libGLESv1_CM\\.so\\."
                                         "libGLESv2\\.so\\."
                                         "libGLX\\.so\\."
                                         "libGLdispatch\\.so\\."
                                         "libOpenGL\\.so\\."
                                         "libnvidia-gtk[23]\\.so\\."
                                         "libOpenCL\\.so\\.")
                                       "|")))
                (copy-recursively "extractdir" #$output)))))))))

(define %nvidia-driver-pins
  ;; Version of the loaded kernel module -> the .run the userspace comes
  ;; from.  On upgrading the host's driver, add the new version here
  ;; first; until then the transformation warns and leaves the profile
  ;; on mesa rather than building libraries the module cannot talk to.
  `(("580.126.20"
     .
     ,(nvidia-run-source
       "580.126.20"
       '("https://us.download.nvidia.com/tesla/580.126.20/NVIDIA-Linux-x86_64-580.126.20.run")
       (base32 "1cay4rd8q3k64bcw0ir1kp38530lc2h2j6dl6l1z4f14wzmdnmd0")))))

(define (pinned-nvda-driver source)
  "Return nonguix's nvidia-driver-580 rebuilt from the userspace files in
SOURCE (see @code{nvidia-run-source})."
  ;; nonguix's nvidia-driver-580 is itself a binary-package-from-sources
  ;; call, whose 'unpack replacement closes over its own source and
  ;; ignores the one it is handed: wrapping it again in
  ;; binary-package-from-sources is a no-op at best, the inner source
  ;; wins, and the built driver carries nonguix's version while claiming
  ;; ours -- which the host kernel module then rejects (NVML "driver
  ;; library version mismatch", EGL init failure).  Replace 'unpack on
  ;; top instead, so the last replacement is ours.
  (package
    (inherit (@@ (nongnu packages nvidia) nvidia-driver-580))
    (version (package-version source))
    (arguments
     (substitute-keyword-arguments
         (package-arguments (@@ (nongnu packages nvidia) nvidia-driver-580))
       ((#:phases phases)
        #~(modify-phases #$phases
            (replace 'unpack
              (lambda _
                ((assoc-ref %standard-phases 'unpack)
                 #:source #$(package-source source))))))))))

(define (pinned-nvda source)
  "Return nonguix's nvda (mesa with NVIDIA's userspace) built for the
driver files in SOURCE."
  ;; nvda's recipe finds the driver input by its "nvidia-driver" name;
  ;; the 580 driver package provides the name and the build phases, the
  ;; source provides the version (and so the file contents).
  ((@@ (nongnu packages nvidia) make-nvda) (pinned-nvda-driver source)))

(define (host-nvidia-driver-version)
  "Return the version of the NVIDIA kernel module loaded on the host,
e.g. \"580.126.20\", or #f when the proprietary driver is not loaded.

@file{/proc/driver/nvidia/version} exists only while the module is
loaded; under nouveau or nova -- or with no NVIDIA driver at all --
there is nothing to match, and NVIDIA's userspace is not wanted either."
  (false-if-exception
   (call-with-input-file "/proc/driver/nvidia/version"
     (lambda (port)
       ;; "NVRM version: NVIDIA UNIX Open Kernel Module for x86_64
       ;; 580.126.20 Release Build ..." -- the version is the first
       ;; dotted number on the line.
       (and=> (string-match "[0-9]+\\.[0-9]+\\.[0-9]+" (get-line port))
              match:substring)))))

(define (nvidia-host?)
  "True when the host is running NVIDIA's proprietary driver, i.e. when
the loaded kernel module reports a version."
  (and (host-nvidia-driver-version) #t))

(define (home-transformation-nvidia he)
  "Return the home environment HE with nonguix's nvda grafted over Guix's
mesa, pinned to the NVIDIA kernel module loaded on the host.

Every package in HE's `packages' and `services' gets its references to
mesa rewritten to nvda in place, so niri and the rest of the profile --
whose libEGL, libgbm, GBM backends and EGL vendors all come from mesa --
are not rebuilt, and nvda is added to the profile so its search paths
are exported to the session.  This is what lets a niri session advertise
the NVIDIA driver's dmabuf feedback instead of falling back to
llvmpipe.

The userspace and the kernel module must match exactly (\"NVRM: API
mismatch\" otherwise), so with no loaded NVIDIA driver HE is returned
unchanged, and a module version that is not in %nvidia-driver-pins is a
warning and a no-op rather than a broken profile.

nonguix's replace-mesa additionally grafts ffmpeg (so libva via
nvidia-vaapi-driver, which nvda already carries, is linked into the
codecs); that would rebuild ffmpeg, so it is left out until there is a
reason for it."
  (let ((version (host-nvidia-driver-version)))
    (cond
     ((not version) he)
     ((not (assoc-ref %nvidia-driver-pins version))
      (warning (G_ "NVIDIA driver ~a is not pinned in (uraj hardware nvidia); \
leaving the home profile on mesa.  Add the ~a installer to \
%nvidia-driver-pins to use the proprietary driver.\n")
               version version)
      he)
     (else
      (let* ((nvda (pinned-nvda (assoc-ref %nvidia-driver-pins version)))
             (graft (package-input-grafting `((,mesa . ,nvda)))))
        (home-environment
         (inherit he)
         (packages
          (cons nvda
                (with-transformation graft (home-environment-packages he))))
         (services
          (with-transformation graft (home-environment-user-services he)))))))))
