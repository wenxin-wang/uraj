(define-module (uraj packages llm)
  #:use-module (gnu packages base)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages elf)
  #:use-module (gnu packages fonts)
  #:use-module (gnu packages gcc)
  #:use-module (gnu packages xorg)
  #:use-module (gnu packages chromium)
  #:use-module (gnu packages gl)
  #:use-module (gnu packages linux)
  #:use-module (gnu packages python)
  #:use-module (gnu packages version-control)
  #:use-module (gnu packages window-management)
  #:use-module (guix build-system trivial)
  #:use-module (guix build-system copy)
  #:use-module (guix download)
  #:use-module (guix git-download)
  #:use-module (guix gexp)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:use-module ((guix search-paths) #:select ($SSL_CERT_DIR $SSL_CERT_FILE))
  #:use-module (guix utils)
  #:use-module (srfi srfi-1)
  #:use-module (nonguix build-system binary)
  #:use-module (nonguix build-system chromium-binary)
  #:use-module (uraj packages chromium-binary)
  #:use-module (uraj utils file path)
  #:use-module ((px packages ai)
                #:select ((claude-code . pantherx-claude-code)))
  #:use-module ((px packages tools)
                #:select ((codex . pantherx-codex)))
  #:use-module ((shika packages ai)
                #:select ((opencode-bin . shika-opencode-bin)))
  #:export (agent-browser
            browser-profile
            contained-browser-profile
            claude-code
            codex
            gh-git-credential
            opencode-bin
            pi-coding-agent
            paseo))

;;; PantherX's package replaces `unpack' and leaves the build-directory root as
;;; the working directory, so install-license-files lists "../" (= /tmp) to
;;; find the source directory.  The host's AppArmor profile for guix-builders
;;; does not allow reading /tmp itself, so scandir returns #f and the phase
;;; dies with `match-error'.  The package installs a single binary and ships
;;; no license files in the build tree, so drop the phase.
(define-public claude-code
  (package
    (inherit pantherx-claude-code)
    ;; Backport PantherX fd68e7a6's update without advancing the channel lock.
    (version "2.1.287")
    (source
     (origin
       (inherit (package-source pantherx-claude-code))
       (uri (string-append
             "https://storage.googleapis.com/claude-code-dist-"
             "86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/"
             version "/linux-x64/claude"))
       (sha256
        (base32 "1w0q2xd0x9hnkkdmwvbrphigy23l4wjjqf8sd9wgbkq9a6d4h81r"))))
    (arguments
     (substitute-keyword-arguments (package-arguments pantherx-claude-code)
       ((#:phases phases #~%standard-phases)
        #~(modify-phases #$phases
            (delete 'install-license-files)))))))

;;; PantherX installs only the main executable from OpenAI's standalone
;;; release.  Code Mode is distributed as a separate, version-matched host
;;; archive and Codex looks for it next to itself in bin/.
(define-public codex
  (package
    (inherit pantherx-codex)
    (supported-systems '("x86_64-linux"))
    (inputs
     `(("code-mode-host"
        ,(origin
           (method url-fetch)
           (uri (string-append
                 "https://github.com/openai/codex/releases/download/rust-v"
                 (package-version pantherx-codex)
                 "/codex-code-mode-host-x86_64-unknown-linux-musl.tar.gz"))
           (sha256
            (base32
             "1m2lg15awdrv53sq727fh61v3lsklgz6wmwl6w2jgiwzw3mip31j"))))
       ,@(package-inputs pantherx-codex)))
    (arguments
     (substitute-keyword-arguments (package-arguments pantherx-codex)
       ((#:phases phases #~%standard-phases)
        #~(modify-phases #$phases
            ;; The tarball unpacks to a single file, so 'unpack' does not
            ;; enter a sub-directory; see claude-code above for why the
            ;; license phase must go.
            (delete 'install-license-files)
            (add-after 'install 'install-code-mode-host
              (lambda* (#:key inputs outputs #:allow-other-keys)
                (let* ((archive (assoc-ref inputs "code-mode-host"))
                       (host "codex-code-mode-host-x86_64-unknown-linux-musl")
                       (bin (string-append (assoc-ref outputs "out") "/bin")))
                  (invoke "tar" "-xzf" archive host)
                  (install-file host bin)
                  (rename-file (string-append bin "/" host)
                               (string-append bin "/codex-code-mode-host")))))))))))

;;; Like the PantherX packages above, Shikanox's package builds the release
;;; tarball with nonguix's binary-build-system, which has no 'configure phase
;;; and leaves the build-directory root as the working directory, so
;;; 'install-license-files' lists ".." to find the source directory; see
;;; claude-code above for why the phase must go.
;;;
;;; Its wrapper also exports LD_LIBRARY_PATH with Guix's glibc, which leaks
;;; into every shell OpenCode spawns; see (uraj packages chromium-binary).
;;; The binary needs only libc, which its Guix ld.so finds unaided, so drop
;;; the variable.
(define-public opencode-bin
  (package
    (inherit shika-opencode-bin)
    (arguments
     (substitute-keyword-arguments (package-arguments shika-opencode-bin)
       ((#:phases phases #~%standard-phases)
        #~(modify-phases #$phases
            (delete 'install-license-files)
            (add-after 'patch-and-wrap 'drop-library-path
              (lambda _
                (substitute* (string-append #$output "/bin/opencode")
                  (("^export LD_LIBRARY_PATH=.*$") ""))))))))))

(define-public pi-coding-agent
  (package
    (name "pi-coding-agent")
    (version "1.3.0")
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://github.com/earendil-works/pi/releases/download/v"
             version "/pi-linux-x64.tar.gz"))
       (sha256
        (base32 "1vaxa3ma68y56mybbyrlhjml6kwp06ari5k2hwvdmm36icrbxx94"))))
    (build-system binary-build-system)
    (supported-systems '("x86_64-linux"))
    (arguments
     (list
      #:strip-binaries? #f
      #:validate-runpath? #f
      #:patchelf-plan
      #~'(("native/linux/prebuilds/linux-x64/linux-platform-x11.node"
           ("libxcb")))
      #:install-plan #~'(("." "share/pi"))
      #:phases
      #~(modify-phases %standard-phases
          ;; Preserve Bun's embedded payload: only change the dynamic section.
          ;; glibc dlopens libgcc_s.so.1 when a thread exits, such as a
          ;; terminated Worker, and aborts if it is not found.  That dlopen
          ;; ignores the program's RUNPATH, and the ld.so cache lists only
          ;; NEEDED libraries, so load libgcc_s at startup.
          (add-after 'install 'wrap-pi
            (lambda* (#:key inputs #:allow-other-keys)
              (let ((program (string-append #$output "/share/pi/pi")))
                (invoke "patchelf" "--set-interpreter"
                        (search-input-file inputs "/lib/ld-linux-x86-64.so.2")
                        "--set-rpath"
                        (dirname (search-input-file inputs
                                                    "/lib/libgcc_s.so.1"))
                        "--add-needed" "libgcc_s.so.1"
                        program)
                (mkdir-p (string-append #$output "/bin"))
                ;; Keep the executable beside its themes, docs and addons.
                (call-with-output-file (string-append #$output "/bin/pi")
                  (lambda (port)
                    (format port "#!~a~%exec ~a \"$@\"~%"
                            (search-input-file inputs "/bin/bash") program)))
                (chmod (string-append #$output "/bin/pi") #o755))))
          (add-after 'wrap-pi 'check-thread-exit
            (lambda _
              (call-with-output-file "worker.js"
                (lambda (port)
                  (display "const w = new Worker(URL.createObjectURL(
  new Blob([\"postMessage(1)\"])));
w.onmessage = () => { w.terminate(); setTimeout(() => {}, 500); };
" port)))
              (setenv "BUN_BE_BUN" "1")
              (invoke (string-append #$output "/share/pi/pi") "worker.js"))))))
    (native-inputs (list patchelf))
    (inputs (list bash-minimal glibc `(,gcc "lib") libxcb))
    (home-page "https://pi.dev")
    (synopsis "Terminal coding agent with extensible tools")
    (description "Pi is a coding agent with file editing, shell tools,
session management, multiple model providers and user extensions.")
    (license license:expat)))

;;; Like Claude Code, use the official binary distribution.  The Chromium
;;; variant of binary-build-system supplies Electron's runtime dependencies.
(define-public paseo
  (package
    (name "paseo")
    (version "0.11.4")
    (source
     (origin
       (method url-fetch)
       (uri (string-append
             "https://github.com/getpaseo/paseo/releases/download/v" version
             "/Paseo-" version "-amd64.deb"))
       (sha256
        (base32 "1h1g08x5x0n4j0d4hvivxg94b2yhzg4a2lnqcl6i2rh93xiz5yhv"))))
    (build-system chromium-binary-build-system)
    (arguments
     (list
      #:strip-binaries? #f
      #:validate-runpath? #f
      #:wrapper-plan
      #~(map (lambda (file) (string-append "opt/Paseo/" file))
         ;; Include daemon addons and speech libraries, but not the unused
         ;; musl addons or statically linked esbuild executables.
         '("Paseo.bin"
           "chrome-sandbox"
           "chrome_crashpad_handler"
           "libffmpeg.so"
           "libvulkan.so.1"
           "libvk_swiftshader.so"
           "resources/app.asar.unpacked/node_modules/node-pty/prebuilds/linux-x64/pty.node"
           "resources/app.asar.unpacked/node_modules/@msgpackr-extract/msgpackr-extract-linux-x64/node.abi115.glibc.node"
           "resources/app.asar.unpacked/node_modules/@msgpackr-extract/msgpackr-extract-linux-x64/node.napi.glibc.node"
           "resources/app.asar.unpacked/node_modules/sherpa-onnx-linux-x64/sherpa-onnx.node"
           "resources/app.asar.unpacked/node_modules/sherpa-onnx-linux-x64/libsherpa-onnx-c-api.so"
           "resources/app.asar.unpacked/node_modules/sherpa-onnx-linux-x64/libsherpa-onnx-cxx-api.so"
           "resources/app.asar.unpacked/node_modules/sherpa-onnx-linux-x64/libonnxruntime.so"))
      #:install-plan
      #~'(("opt/Paseo/" "share/paseo/")
          ("usr/share/applications/" "share/applications/")
          ("usr/share/icons/" "share/icons/"))
      #:phases
      (isolate-chromium-wrapper-environment
       #~(modify-phases %standard-phases
           (add-after 'patchelf 'patch-sandbox-probe
             (lambda* (#:key inputs #:allow-other-keys)
               ;; The wrapper no longer prefixes PATH with util-linux.
               (substitute* "opt/Paseo/Paseo"
                 (("\\$\\((unshare|findmnt) " _ command)
                  (string-append
                   "$("
                   (search-input-file inputs (string-append "bin/" command))
                   " ")))))
           (add-after 'patchelf 'restore-origin-runpath
             (lambda _
               ;; patchelf replaces upstream's $ORIGIN; Electron and sherpa
               ;; still need their co-located shared libraries.
               (for-each
                (lambda (file)
                  (invoke "patchelf" "--add-rpath" "$ORIGIN" file))
                (cons "opt/Paseo/Paseo.bin"
                      (find-files "opt/Paseo/resources/app.asar.unpacked"
                                  "sherpa-onnx.*\\.(node|so)$")))))
           (add-before 'install 'patch-desktop-entry
             (lambda _
               (substitute* "usr/share/applications/Paseo.desktop"
                 (("/opt/Paseo/Paseo")
                  (string-append #$output "/bin/paseo-desktop")))))
           (add-before 'install-wrapper 'install-launchers
             (lambda _
               (let ((bin (string-append #$output "/bin"))
                     (app (string-append #$output "/share/paseo")))
                 (mkdir-p bin)
                 ;; Keep the upstream sandbox launcher, which also handles
                 ;; hosts where unprivileged user namespaces are unavailable.
                 (symlink (string-append app "/Paseo")
                          (string-append bin "/paseo-desktop"))
                 (symlink (string-append app "/resources/bin/paseo")
                          (string-append bin "/paseo")))))))))
    ;; The upstream sandbox launcher probes user namespaces with unshare.
    (inputs (list util-linux))
    (supported-systems '("x86_64-linux"))
    (home-page "https://paseo.sh")
    (synopsis "Desktop interface for AI coding agents")
    (description
     "Paseo provides a desktop interface and a local daemon for managing AI
coding agents such as Claude Code and Codex.  This package repackages the
official Linux desktop application, including its bundled command-line client.
Run @command{paseo-desktop} for the GUI or @command{paseo} for the CLI.")
    (license license:asl2.0)))

;;; The release binary is statically linked against musl and needs no
;;; patching.  `agent-browser skills get' serves version-matched content from
;;; ../skills and ../skill-data next to the canonicalized executable, so the
;;; tagged checkout supplies those directories and the binary sits beside them
;;; under share/.  The launcher defaults to ungoogled-chromium in place of the
;;; Chrome for Testing that `agent-browser install' downloads, which cannot run
;;; on Guix System.
(define-public agent-browser
  (package
    (name "agent-browser")
    (version "0.38.2")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/vercel-labs/agent-browser")
             (commit (string-append "v" version))))
       (file-name (git-file-name name version))
       (sha256
        (base32 "0l9jnxqyc4zdkvsinxa9c571hldmr4jkllrdhnycpa8q6fyi1liw"))))
    (build-system copy-build-system)
    (arguments
     (let ((binary
            (origin
              (method url-fetch)
              (uri (string-append
                    "https://github.com/vercel-labs/agent-browser/releases/download/v"
                    (package-version this-package)
                    "/agent-browser-linux-musl-x64"))
              (sha256
               (base32 "0xg6k2wwrhh30c9f17s4zhmm197baaj22r9sv5h9ihfg9lplcgcr")))))
       (list
        #:install-plan
        #~'(("skills" "share/agent-browser/")
            ("skill-data" "share/agent-browser/"))
        #:phases
        #~(modify-phases %standard-phases
            (add-after 'install 'install-binary
              (lambda* (#:key inputs #:allow-other-keys)
                (let ((real (string-append #$output
                                           "/share/agent-browser/bin/agent-browser"))
                      (launcher (string-append #$output "/bin/agent-browser")))
                  (mkdir-p (dirname real))
                  (copy-file #$binary real)
                  (chmod real #o555)
                  (mkdir-p (dirname launcher))
                  (call-with-output-file launcher
                    (lambda (port)
                      (format port "#!~a
export AGENT_BROWSER_EXECUTABLE_PATH=\"${AGENT_BROWSER_EXECUTABLE_PATH:-~a}\"
exec ~a \"$@\"~%"
                              (search-input-file inputs "/bin/bash")
                              (search-input-file inputs "/bin/chromium")
                              real)))
                  (chmod launcher #o555))))))))
    (inputs (list bash-minimal ungoogled-chromium))
    (supported-systems '("x86_64-linux"))
    (home-page "https://agent-browser.dev")
    (synopsis "Browser automation command-line tool for AI agents")
    (description
     "agent-browser drives Chrome or Chromium over the DevTools protocol and
prints accessibility-tree snapshots with compact element references, for use by
AI coding agents.  This package repackages the official static Linux binary
together with its version-matched agent skills.")
    (license license:asl2.0)))

;;; gh reads no git credential helper, only GH_TOKEN or its own login.  In
;;; containers, which hold no login, ask git for the current repository's
;;; token instead, so that git and gh use the same one, configured once.
(define gh-git-credential-script
  (mixed-text-file "gh"
    "#!" bash-minimal "/bin/sh
url=$(" git "/bin/git remote get-url origin 2>/dev/null) || url=
case $url in
  https://github.com/*) ;;
  git@github.com:*) url=https://github.com/${url#git@github.com:} ;;
  ssh://git@github.com/*) url=https://github.com/${url#ssh://git@github.com/} ;;
  *) url=https://github.com ;;
esac
if [ -z \"${GH_TOKEN-}\" ]; then
  token=$(printf 'url=%s\\n\\n' \"$url\" |
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS= SSH_ASKPASS= \\
    " git "/bin/git -c credential.interactive=false credential fill 2>/dev/null |
    " sed "/bin/sed -n 's/^password=//p')
  if [ -n \"$token\" ]; then export GH_TOKEN=$token; fi
fi
exec " github-cli "/bin/gh \"$@\"
"))

(define-public gh-git-credential
  (package
    (name "gh-git-credential")
    (version (package-version github-cli))
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list #:builder
           #~(let ((bin (string-append #$output "/bin")))
               (mkdir #$output)
               (mkdir bin)
               (copy-file #$gh-git-credential-script (string-append bin "/gh"))
               (chmod (string-append bin "/gh") #o555))))
    ;; gh, in Go, finds CA certificates through these, which github-cli does
    ;; not declare: without them a profile with nss-certs but no OpenSSL
    ;; package, such as the Paseo daemon's, leaves gh unable to verify TLS.
    (native-search-paths (list $SSL_CERT_DIR $SSL_CERT_FILE))
    (home-page (package-home-page github-cli))
    (synopsis "GitHub CLI authenticated by git's credential helpers")
    (description "This @command{gh} runs GitHub CLI with the token that git's
credential helpers give for the current repository's origin, when
@env{GH_TOKEN} is unset.")
    (license (package-license github-cli))))

;;; Browser tasks share browser-profile with the OpenClaw sandbox image.  The
;;; host keeps the login identity and publishes snapshots of it, which
;;; contained agents only fork, in their tmpfs home (see contained-agent).
;;; Both sides run agent-browser's Chromium with the basic password store:
;;; cookies encrypted with the host's keyring would be unreadable inside.
(define browser-profile-source
  (local-file (project-path "env/docker/openclaw-sandbox/browser-profile")
              "browser-profile.py"))

(define %browser-arguments
  "--disable-blink-features=AutomationControlled,--password-store=basic")

(define (browser-profile-package name programs description)
  "PROGRAMS are (NAME FILE) entries installed in bin/."
  (package
    (name name)
    (version (package-version agent-browser))
    (source #f)
    (build-system trivial-build-system)
    (arguments
     (list #:builder
           #~(let ((bin (string-append #$output "/bin")))
               (mkdir #$output)
               (mkdir bin)
               (for-each (lambda (program)
                           (let ((file (string-append bin "/" (car program))))
                             (copy-file (cadr program) file)
                             (chmod file #o555)))
                         (list #$@(map (lambda (program)
                                         #~(list #$(car program)
                                                 #$(cadr program)))
                                       programs))))))
    (home-page (package-home-page agent-browser))
    (synopsis "Browser login snapshots and task profiles for agent-browser")
    (description description)
    (license license:expat)))

;;; The user logs in in a window of the desktop session.
(define browser-profile
  (browser-profile-package
   "browser-profile"
   `(("browser-profile"
      ,(mixed-text-file "browser-profile"
         "#!" bash-minimal "/bin/sh
# contained-agent exposes the default's published/; tests choose another.
export BROWSER_PROFILE_ROOT=${BROWSER_PROFILE_ROOT:-$HOME/.local/state/agent-browser}
export BROWSER_PROFILE_PUBLISHED=$BROWSER_PROFILE_ROOT/published
# Daemons of their own: one started elsewhere keeps its own arguments.
export AGENT_BROWSER_SOCKET_DIR=$BROWSER_PROFILE_ROOT/daemons
export AGENT_BROWSER_HEADED=1
export AGENT_BROWSER_ARGS=" %browser-arguments "
# Terminals started by services, such as Paseo's, lack the session's display.
if [ -z \"${WAYLAND_DISPLAY-}${DISPLAY-}\" ]; then
  runtime=${XDG_RUNTIME_DIR:-/run/user/$(" coreutils "/bin/id -u)}
  for socket in \"$runtime\"/wayland-*; do
    if [ -S \"$socket\" ]; then
      export XDG_RUNTIME_DIR=$runtime WAYLAND_DISPLAY=${socket##*/}
      break
    fi
  done
fi
# Chromium picks X11 otherwise, which niri lacks.
if [ -n \"${WAYLAND_DISPLAY-}\" ]; then
  AGENT_BROWSER_ARGS=$AGENT_BROWSER_ARGS,--ozone-platform=wayland
elif [ -z \"${DISPLAY-}\" ] && [ \"${1-}\" = login ]; then
  echo 'browser-profile: login needs a desktop session: neither WAYLAND_DISPLAY nor DISPLAY is set' >&2
  exit 1
fi
export PATH=" agent-browser "/bin:$PATH
exec " python "/bin/python3 " browser-profile-source " \"$@\"
")))
   "This @command{browser-profile} keeps the host's browser login identity
and publishes snapshots of it for contained agents."))

(define %browser-fonts
  (list font-google-noto font-google-noto-sans-cjk font-google-noto-emoji
        font-liberation))

(define contained-browser-fontconfig
  (apply mixed-text-file "fonts.conf"
         "<?xml version=\"1.0\"?>
<!DOCTYPE fontconfig SYSTEM \"fonts.dtd\">
<fontconfig>
"
         (append
          (append-map (lambda (font) (list "  <dir>" font "/share/fonts</dir>\n"))
                      %browser-fonts)
          (list "  <cachedir prefix=\"xdg\">fontconfig</cachedir>
</fontconfig>
"))))

;;; Mesa's hardware Vulkan drivers, without lavapipe.
(define %contained-vulkan-drivers
  '("intel" "intel_hasvk" "radeon" "nouveau" "virtio"))

;;; Like the OpenClaw sandbox's sandbox-chromium, run headed Chromium in a
;;; private cage on wlroots' headless backend: headless mode changes what
;;; sites see.  cage exits with Chromium.  With a render node, compositing
;;; and WebGL use it and software rendering stays refused, so a broken GPU
;;; path shows; without one, allow SwiftShader, which agent-browser enables
;;; only in headless mode.
(define contained-chromium-script
  (apply mixed-text-file "contained-chromium"
         "#!" bash-minimal "/bin/sh
set -eu
export XDG_RUNTIME_DIR=$HOME/.browser-profile/runtime
" coreutils "/bin/mkdir -m 700 -p \"$XDG_RUNTIME_DIR\"
# agent-browser reads stderr only once the browser is up, but cage logs more
# than a pipe holds before it starts Chromium, and would block for good.
exec 2>\"$XDG_RUNTIME_DIR/browser-$$.log\"
export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1
render=
for node in /dev/dri/renderD*; do
  if [ -c \"$node\" ]; then render=$node; break; fi
done
if [ -n \"$render\" ]; then
  export WLR_RENDERER=vulkan WLR_RENDER_DRM_DEVICE=$render
  # Without Chromium's own SwiftShader driver.
  export VK_DRIVER_FILES="
         (append
          (cdr (append-map (lambda (driver)
                             (list ":" mesa "/share/vulkan/icd.d/"
                                   driver "_icd.x86_64.json"))
                           %contained-vulkan-drivers))
          (list "
  for arg do
    shift
    case \"$arg\" in
      --enable-unsafe-swiftshader) ;;
      *) set -- \"$@\" \"$arg\" ;;
    esac
  done
else
  export WLR_RENDERER=pixman
  set -- --enable-unsafe-swiftshader \"$@\"
fi
exec " cage "/bin/cage -- " ungoogled-chromium
"/bin/chromium --ozone-platform=wayland \"$@\"
"))))

(define contained-browser-profile
  (browser-profile-package
   "contained-browser-profile"
   `(("contained-chromium" ,contained-chromium-script)
     ("browser-profile"
      ,(mixed-text-file "browser-profile"
         "#!" bash-minimal "/bin/sh
# agent-browser keeps its daemons' files in ~/.agent-browser.
export BROWSER_PROFILE_ROOT=$HOME/.browser-profile
export BROWSER_PROFILE_PUBLISHED=/run/contained-agent/browser
export BROWSER_PROFILE_IDENTITY_HINT='Browser logins are kept on the host. \
Ask the user to run `browser-profile login URL` there, sign in in its window, \
then run `browser-profile publish`; then create a new task.'
export AGENT_BROWSER_HEADED=1
export AGENT_BROWSER_EXECUTABLE_PATH=${0%/*}/contained-chromium
export AGENT_BROWSER_ARGS=" %browser-arguments
         ",--enable-gpu,--use-gl=angle,--use-angle=vulkan
export AGENT_BROWSER_IDLE_TIMEOUT_MS=1800000
export FONTCONFIG_FILE=" contained-browser-fontconfig "
export PATH=" agent-browser "/bin:$PATH
exec " python "/bin/python3 " browser-profile-source " \"$@\"
")))
   "This @command{browser-profile} forks task profiles from the login
snapshots that the host publishes, for agents in containers."))
