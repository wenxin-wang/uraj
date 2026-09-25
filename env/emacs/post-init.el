;;; -*- lexical-binding: t; -*-

;; Straight package pananger.
;; Also load during byte-compilation, else the following
;; `use-package` macros would expand without calls to `straight-use-package`.
(eval-and-compile
  (setq
   straight-vc-git-default-clone-depth 1
   straight-repository-branch "develop"
   straight-check-for-modifications nil
   straight-use-package-by-default t)
  (defvar bootstrap-version)
  (let ((bootstrap-file
         (expand-file-name
          "straight/repos/straight.el/bootstrap.el"
          (or (bound-and-true-p straight-base-dir)
              user-emacs-directory)))
        (bootstrap-version 7))
    (unless (file-exists-p bootstrap-file)
      (with-current-buffer
          (url-retrieve-synchronously
           "https://raw.githubusercontent.com/radian-software/straight.el/develop/install.el"
           'silent 'inhibit-cookies)
        (goto-char (point-max))
        (eval-print-last-sexp)))
    (load bootstrap-file nil 'nomessage)))

;; Byte-compilation requirements.
(eval-when-compile
  (setq use-package-always-defer t)
  (require 'use-package)
  (require 'cl-lib)
  ;; For LSP
  (setenv "LSP_USE_PLISTS" "true"))

;; I don't care about this even when debugging, and it messes up with byte-compilation, so turn it off.
(setq use-package-compute-statistics nil)

;; Setup no-littering as early as possible.
;; https://github.com/emacscollective/no-littering
(use-package no-littering
  :demand t
  :config
  (setq custom-file (expand-file-name "custom.el" no-littering-etc-directory))
  (no-littering-theme-backups))

;; Patches
(use-package el-patch
  :demand t)

;; Basic UI.

(when (display-graphic-p)
  ;; https://emacs.stackexchange.com/questions/20240/how-to-distinguish-c-m-from-return
  ;; to define C-m key
  (define-key input-decode-map [?\C-m] [C-m])
  ;; remove some keybindings that can be accidentally triggered..
  ;; suspend-frame
  (define-key global-map (kbd "C-x C-z") nil)
  ;; save-buffers-kill-terminal
  (define-key global-map (kbd "C-x C-c") nil)
  ;; Sane common mouse actions, see
  ;; https://christiantietze.de/posts/2022/07/shift-click-in-emacs-to-select/
  (global-set-key (kbd "S-<down-mouse-1>") #'mouse-set-mark)
  (global-set-key (kbd "C-S-<down-mouse-1>") #'mouse-drag-region-rectangle))

;; Blackout: hide minor modes from modeline
(use-package blackout
  :demand t)

;; Better help.
(when (version< emacs-version "30.0") (straight-use-package 'which-key))
(use-package which-key
  :straight nil ; Built-in after emacs 30.
  :ensure nil ; Built-in after emacs 30.
  :blackout t
  :hook (emacs-startup . which-key-mode)

  :custom
  ;; We configure it so that `which-key' is triggered by typing C-h
  ;; during a key sequence (the usual way to show bindings). See
  ;; <https://github.com/justbur/emacs-which-key#manual-activation>.
  (which-key-show-early-on-C-h t)
  (which-key-idle-delay most-positive-fixnum)
  (which-key-idle-secondary-delay 0.05))

;; Better repeat.
(use-package repeat-fu
  :blackout t
  ;; repeat-fu defines ~incf~ & ~decf~ instead of using ~cl-lib~,
  ;; inside a ~eval-when-compile~. This causes trouble for byte-compile
  ;; and native-compile, where we must load the uncompiled ~repeat-fu.el~
  ;; when compiling ~repeat-fu-preset-meow.el~. I can control this order
  ;; for byte-compile by explicitly setting the loading order for ~straight.el~,
  ;; but I cannot do the same thing for native-compile (as native-compile must
  ;; use ~.elc~ files instead, so I just disable native-compile for
  ;; ~repeat-fu-preset-meow.el~.
  ;; Something I don't understand: I think the macros should be gone in the ~.elc~
  ;; and native-compile should have nothing to do with them. So how did things
  ;; happen?
  ;; :straight (:build (:not compile))
  :straight (:files ("repeat-fu-preset-meow.el" "repeat-fu.el"))
  :commands (repeat-fu-mode repeat-fu-execute)

  :custom
  (repeat-fu-preset 'meow)

  :hook
  (meow-mode . (lambda ()
                 (when (and (not (minibufferp)) (not (derived-mode-p 'special-mode)))
                   (repeat-fu-mode)))))

;; Better undo.
(use-package undo-tree
  :blackout t
  :hook
  (emacs-startup . global-undo-tree-mode))

;; Redefine pop-global-mark so that we can rotate in another
;; direction.
(use-package simple
  :straight (:type built-in)
  :blackout column-number-mode
  :hook
  (emacs-startup . column-number-mode)
  :config/el-patch
  (defun pop-global-mark ((el-patch-add N))
    "Pop off global mark ring and jump to the top location."
    (interactive (el-patch-add "P"))
    ;; Pop entries that refer to non-existent buffers.
    (while (and global-mark-ring (not (marker-buffer (car global-mark-ring))))
      (setq global-mark-ring (cdr global-mark-ring)))
    (or global-mark-ring
        (error "No global mark set"))
    ;; (message "pop-global-mark %s %s" N global-mark-ring)
    (let* ((el-patch-add
             (head (if (not N)
                       (list (car global-mark-ring))
                     (last global-mark-ring)))
             (remaining (if (not N)
                            (cdr global-mark-ring)
                          (butlast global-mark-ring))))
           (marker
            (car (el-patch-swap global-mark-ring head)))
           (buffer (marker-buffer marker))
           (position (marker-position marker)))
      (setq global-mark-ring
            (el-patch-swap
              (nconc (cdr global-mark-ring)
    			     (list (car global-mark-ring)))
              (if (not N)
                  (nconc remaining head)
                (nconc head remaining))))
      (set-buffer buffer)
      (or (and (>= position (point-min))
               (<= position (point-max)))
          (if widen-automatically
              (widen)
            (error "Global mark position is outside accessible part of buffer %s"
                   (buffer-name buffer))))
      (goto-char position)
      (switch-to-buffer buffer))))

(use-package scroll-on-jump
  :demand t
  :custom
  (isearch-allow-motion t)
  (isearch-allow-scroll t)
  :config
  (scroll-on-jump-advice-add isearch-forward)
  (scroll-on-jump-advice-add isearch-backward)

  (scroll-on-jump-with-scroll-advice-add recenter-top-bottom)
  (scroll-on-jump-with-scroll-advice-add scroll-up-command)
  (scroll-on-jump-with-scroll-advice-add scroll-down-command))

(use-package ace-window
  :bind
  ("M-o" . ace-window)
  :custom
  (aw-minibuffer-flag t))

;; Modal editing.
(use-package meow
  ;; Somehow ~meow-global-mode~ does not trigger evaluation
  ;; of :config block.
  :demand t
  :custom
  (meow-expand-exclude-mode-list '())
  :config
  (setq meow-cheatsheet-layout meow-cheatsheet-layout-qwerty)

  ;; Advice to set last-command-event when meow dispatches kbd macros,
  ;; so that when under ~eat-semi-char-mode~, ~eat-self-input~ actually
  ;; inserts ~C-n~ instead of ~j~ when pressing ~j~ under ~meow-normal-mode~.
  (defun my/meow-set-last-command-event (orig-fun kbd-macro-or-defun)
    "Advice around `meow--execute-kbd-macro' to set `last-command-event'.
When KBD-MACRO-OR-DEFUN is a string (kbd macro), set `last-command-event'
to the event that the macro represents, so the dispatched command sees
the macro key instead of the original key."
    (if (stringp kbd-macro-or-defun)
        (let* ((keys (read-kbd-macro kbd-macro-or-defun))
               ;; Get the first (and typically only) key from the macro
               (event (if (and (vectorp keys) (> (length keys) 0))
                          (aref keys 0)
                        last-command-event)))
          ;; Bind last-command-event to the macro's key event
          (let ((last-command-event event))
            (funcall orig-fun kbd-macro-or-defun)))
      ;; If it's not a string, just call the original function
      (funcall orig-fun kbd-macro-or-defun)))

  (advice-add 'meow--execute-kbd-macro :around #'my/meow-set-last-command-event)

  (add-to-list
   'meow-char-thing-table
   '(?\( . round))
  (add-to-list
   'meow-char-thing-table
   '(?\[ . square))
  (add-to-list
   'meow-char-thing-table
   '(?\{ . curly))
  (add-to-list
   'meow-char-thing-table
   '(?\' . string))
  (add-to-list
   'meow-char-thing-table
   '(?t . buffer))
  (add-to-list
   'meow-char-thing-table
   '(?y . buffer))

  ;; Fix digit-arguments.
  (eval-when-compile
    (defmacro meow-expand-n (name n)
      `(defun ,name ()
         (interactive)
         (let ((this-command 'meow-expand))
           (meow-expand ,n)))))
  (meow-expand-n meow-expand-1 1)
  (meow-expand-n meow-expand-2 2)
  (meow-expand-n meow-expand-3 3)
  (meow-expand-n meow-expand-4 4)
  (meow-expand-n meow-expand-5 5)
  (meow-expand-n meow-expand-6 6)
  (meow-expand-n meow-expand-7 7)
  (meow-expand-n meow-expand-8 8)
  (meow-expand-n meow-expand-9 9)
  (meow-expand-n meow-expand-0 0)

  ;; Copied from https://github.com/meow-edit/meow/issues/506
  ;; -------------------- ;;
  ;;         UTILS        ;;
  ;; -------------------- ;;
  (defun meow-kill-line ()
    "Kill till the end of line."
    (interactive)
    (let ((select-enable-clipboard meow-use-clipboard))
      (kill-line)))

  (defun meow-change-line ()
    "Kill till end of line and switch to INSERT state."
    (interactive)
    (meow--cancel-selection)
    (meow-end-of-thing
     (car (rassoc 'line meow-char-thing-table)))
    (meow-change))

  (defun meow-save-clipboard ()
    "Copy in clipboard."
    (interactive)
    (let ((meow-use-clipboard t))
      (meow-save)))

  (defun meow-smart-reverse ()
    "Reverse selection or begin negative argument."
    (interactive)
    (if (use-region-p)
        (meow-reverse)
      (negative-argument nil)))

  (add-to-list
   'meow-selection-command-fallback
   '(meow-kill . meow-delete))
  (meow-motion-define-key
   '("j" . meow-next)
   '("k" . meow-prev)
   '("SPC" . nil)
   '("S-SPC" . meow-keypad)
   '("<escape>" . meow-cancel-selection))
  (meow-define-keys 'normal
    ;; expansion
    '("0" . meow-expand-0)
    '("1" . meow-expand-1)
    '("2" . meow-expand-2)
    '("3" . meow-expand-3)
    '("4" . meow-expand-4)
    '("5" . meow-expand-5)
    '("6" . meow-expand-6)
    '("7" . meow-expand-7)
    '("8" . meow-expand-8)
    '("9" . meow-expand-9)
    '("-" . meow-smart-reverse)

    ;; movement
    '("k" . meow-prev)
    '("j" . meow-next)
    '("h" . meow-left)
    '("l" . meow-right)

    `("n" . ,(scroll-on-jump-interactive #'meow-search))
    `("/" . ,(scroll-on-jump-interactive #'meow-visit))

    '("<backspace>" . meow-page-up)
    '("RET" . meow-page-down)

    ;; expansion
    '("K" . meow-prev-expand)
    '("J" . meow-next-expand)
    '("H" . meow-left-expand)
    '("L" . meow-right-expand)

    '("i" . meow-back-word)
    '("I" . meow-back-symbol)
    '("o" . meow-next-word)
    '("O" . meow-next-symbol)

    '("a" . meow-mark-word)
    '("A" . meow-mark-symbol)
    '("w" . meow-line)
    '("W" . meow-block)
    '("q" . meow-join)
    '("m" . meow-grab)
    '("M" . meow-pop-grab)
    '(",w" . meow-swap-grab)
    '(",s" . meow-sync-grab)
    '("p" . meow-cancel-selection)
    '("P" . meow-pop-selection)
    '("." . repeat-fu-execute)

    '("f" . meow-till)
    '("F" . meow-find)
    '("z" . avy-goto-char-timer)

    `("t" . ,(scroll-on-jump-interactive #'meow-beginning-of-thing))
    `("y" . ,(scroll-on-jump-interactive #'meow-end-of-thing))
    `("T" . ,(scroll-on-jump-interactive #'meow-inner-of-thing))
    `("Y" . ,(scroll-on-jump-interactive #'meow-bounds-of-thing))

    ;; editing
    '("d" . meow-kill)
    '("D" . meow-kill-line)
    '("s" . meow-change)
    '("S" . meow-change-line)
    '("c" . meow-save)
    '("C" . meow-save-clipboard)
    '("v" . meow-yank)
    '("V" . meow-yank-pop)

    '("e" . meow-insert)
    '("E" . meow-open-above)
    '("r" . meow-append)
    '("R" . meow-open-below)

    `("u" . ,(scroll-on-jump-interactive #'undo-tree-undo))
    `("U" . ,(scroll-on-jump-interactive #'undo-tree-redo))

    '("b" . open-line)
    '("B" . split-line)

    '("[" . indent-rigidly-left-to-tab-stop)
    '("]" . indent-rigidly-right-to-tab-stop)

    ;; prefix ;
    '(";f" . save-buffer)
    '(";F" . save-some-buffers)
    '(";d" . meow-query-replace-regexp)
    '(";c" . meow-comment)
    '(";t" . meow-start-kmacro-or-insert-counter)
    '(";r" . meow-start-kmacro)
    '(";e" . meow-end-or-call-kmacro)
    '(";g" . magit)
    '(";q" . meow-quit)
    '(";Q" . kill-emacs)

    ;; prefix g
    `("gl" . ,(scroll-on-jump-interactive #'meow-goto-line))
    `("gi" .
      ,(scroll-on-jump-interactive
        (lambda () (interactive)
          (setq current-prefix-arg '(4)) ; C-u
          (call-interactively 'pop-global-mark))))
    `("go" . ,(scroll-on-jump-interactive #'pop-global-mark))
    `("gO" . ,(scroll-on-jump-interactive #'meow-pop-to-global-mark))
    `("gd" . ,(scroll-on-jump-interactive #'meow-find-ref))

    ;; ignore escape
    '("<escape>" . meow-cancel-selection))
  (meow-global-mode))

(use-package avy
  :commands (avy-goto-char-timer)
  :custom
  (avy-style 'pre)
  (avy-timeout-seconds 0.8))

;; This is very rigid, and I haven't think of how to integrate with my keys.
;; 'strict mode' keeps shooting me in the foot, so disable it for now.
(use-package smartparens
  :hook
  (emacs-startup . show-smartparens-global-mode)
  (prog-mode . turn-on-smartparens-mode)
  (markdown-mode . turn-on-smartparens-mode)
  (org-mode . turn-on-smartparens-mode)
  :config
  ;; load default config
  (require 'smartparens-config))

;; Clipboard.
(setq save-interprogram-paste-before-kill t)

;; Mouse.
(setq mouse-drag-and-drop-region-cross-program t)

;; Scrolling.
(unless (and (eq window-system 'mac)
             (bound-and-true-p mac-carbon-version-string))
  ;; Enables `pixel-scroll-precision-mode' on all operating systems and Emacs
  ;; versions, except for emacs-mac.
  ;;
  ;; Enabling `pixel-scroll-precision-mode' is unnecessary with emacs-mac, as
  ;; this version of Emacs natively supports smooth scrolling.
  ;; https://bitbucket.org/mituharu/emacs-mac/commits/65c6c96f27afa446df6f9d8eff63f9cc012cc738
  (setq pixel-scroll-precision-use-momentum nil) ; Precise/smoother scrolling
  (pixel-scroll-precision-mode 1))

;; Completion.

;; Corfu enhances in-buffer completion by displaying a compact popup with
;; current candidates, positioned either below or above the point. Candidates
;; can be selected by navigating up or down.
(use-package corfu
  :commands (corfu-mode global-corfu-mode)

  :hook (emacs-startup . global-corfu-mode)

  :custom
  (corfu-cycle t)                ;; Enable cycling for `corfu-next/previous'
  (corfu-quit-at-boundary 'separator)   ;; Never quit at completion boundary
  (corfu-auto t)
  (corfu-auto-delay 0.2)
  ;; (corfu-auto-trigger ".")         ;; Custom trigger characters)
  (corfu-quit-no-match 'separator) ;; or t)
  ;; (corfu-quit-no-match nil)      ;; Never quit, even if there is no match
  (corfu-preview-current nil)    ;; Disable current candidate preview
  (corfu-preselect 'prompt)      ;; Preselect the prompt
  (corfu-on-exact-match 'insert) ;; Configure handling of exact matches
  ;; Hide commands in M-x which do not apply to the current mode.
  (read-extended-command-predicate #'command-completion-default-include-p)
  ;; Disable Ispell completion function. As an alternative try `cape-dict'.
  (text-mode-ispell-word-completion nil)
  (tab-always-indent 'complete)
  :config
  (corfu-history-mode)
  (corfu-popupinfo-mode))

;; Cape, or Completion At Point Extensions, extends the capabilities of
;; in-buffer completion. It integrates with Corfu or the default completion UI,
;; by providing additional backends through completion-at-point-functions.
(use-package cape
  :commands (cape-dabbrev cape-file cape-elisp-block)
  :bind ("C-c p" . cape-prefix-map)
  :init
  ;; Add to the global default value of `completion-at-point-functions' which is
  ;; used by `completion-at-point'.
  (add-hook 'completion-at-point-functions #'cape-dabbrev)
  (add-hook 'completion-at-point-functions #'cape-file)
  (add-hook 'completion-at-point-functions #'cape-elisp-block))

;; Command prompts.

;; Vertico provides a vertical completion interface, making it easier to
;; navigate and select from completion candidates (e.g., when `M-x` is pressed).
(use-package vertico
  ;; (Note: It is recommended to also enable the savehist package.)
  :hook (emacs-startup . vertico-mode))

;; Vertico leverages Orderless' flexible matching capabilities, allowing users
;; to input multiple patterns separated by spaces, which Orderless then
;; matches in any order against the candidates.
(use-package orderless
  :demand t
  :custom
  (completion-styles '(orderless basic))
  (completion-category-defaults nil)
  (completion-category-overrides '((file (styles partial-completion)))))

;; Marginalia allows Embark to offer you preconfigured actions in more contexts.
;; In addition to that, Marginalia also enhances Vertico by adding rich
;; annotations to the completion candidates displayed in Vertico's interface.
(use-package marginalia
  :commands (marginalia-mode marginalia-cycle)
  :hook (emacs-startup . marginalia-mode))

;; Embark integrates with Consult and Vertico to provide context-sensitive
;; actions and quick access to commands based on the current selection, further
;; improving user efficiency and workflow within Emacs. Together, they create a
;; cohesive and powerful environment for managing completions and interactions.
(use-package embark
  ;; Embark is an Emacs package that acts like a context menu, allowing
  ;; users to perform context-sensitive actions on selected items
  ;; directly from the completion interface.
  :commands (embark-act
             embark-dwim
             embark-export
             embark-collect
             embark-bindings
             embark-prefix-help-command)
  :bind
  (("C-." . embark-act)         ;; pick some comfortable binding
   ("C-;" . embark-dwim)        ;; good alternative: M-.
   ("C-h B" . embark-bindings)) ;; alternative for `describe-bindings'

  :init
  (setq prefix-help-command #'embark-prefix-help-command)

  :config
  ;; Hide the mode line of the Embark live/completions buffers
  (add-to-list 'display-buffer-alist
               '("\\`\\*Embark Collect \\(Live\\|Completions\\)\\*"
                 nil
                 (window-parameters (mode-line-format . none)))))

(use-package embark-consult
  :hook
  (embark-collect-mode . consult-preview-at-point-mode))

;; Consult offers a suite of commands for efficient searching, previewing, and
;; interacting with buffers, file contents, and more, improving various tasks.
(use-package consult
  :bind (;; C-c bindings in `mode-specific-map'
         ("C-c M-x" . consult-mode-command)
         ("C-c h" . consult-history)
         ("C-c k" . consult-kmacro)
         ("C-c m" . consult-man)
         ("C-c i" . consult-info)
         ([remap Info-search] . consult-info)
         ;; C-x bindings in `ctl-x-map'
         ("C-x M-:" . consult-complex-command)
         ("C-x b" . consult-buffer)
         ("C-x 4 b" . consult-buffer-other-window)
         ("C-x 5 b" . consult-buffer-other-frame)
         ("C-x t b" . consult-buffer-other-tab)
         ("C-x r b" . consult-bookmark)
         ("C-x p b" . consult-project-buffer)
         ;; Custom M-# bindings for fast register access
         ("M-#" . consult-register-load)
         ("M-'" . consult-register-store)
         ("C-M-#" . consult-register)
         ;; Other custom bindings
         ("M-y" . consult-yank-pop)
         ;; M-g bindings in `goto-map'
         ("M-g e" . consult-compile-error)
         ("M-g f" . consult-flymake)
         ("M-g g" . consult-goto-line)
         ("M-g M-g" . consult-goto-line)
         ("M-g o" . consult-outline)
         ("M-g m" . consult-mark)
         ("M-g k" . consult-global-mark)
         ("M-g i" . consult-imenu)
         ("M-g I" . consult-imenu-multi)
         ;; M-s bindings in `search-map'
         ("M-s d" . consult-find)
         ("M-s c" . consult-locate)
         ("M-s g" . consult-grep)
         ("M-s G" . consult-git-grep)
         ("M-s r" . consult-ripgrep)
         ("M-s l" . consult-line)
         ("M-s L" . consult-line-multi)
         ("M-s k" . consult-keep-lines)
         ("M-s u" . consult-focus-lines)
         ;; Isearch integration
         ("M-s e" . consult-isearch-history)
         :map isearch-mode-map
         ("M-e" . consult-isearch-history)
         ("M-s e" . consult-isearch-history)
         ("M-s l" . consult-line)
         ("M-s L" . consult-line-multi)
         ;; Minibuffer history
         :map minibuffer-local-map
         ("M-s" . consult-history)
         ("M-r" . consult-history))

  ;; Enable automatic preview at point in the *Completions* buffer.
  :hook (completion-list-mode . consult-preview-at-point-mode)

  :init
  ;; Optionally configure the register formatting. This improves the register
  (setq register-preview-delay 0.5
        register-preview-function #'consult-register-format)

  ;; Optionally tweak the register preview window.
  (advice-add #'register-preview :override #'consult-register-window)

  ;; Use Consult to select xref locations with preview
  (setq xref-show-xrefs-function #'consult-xref
        xref-show-definitions-function #'consult-xref)

  ;; Aggressive asynchronous that yield instantaneous results. (suitable for
  ;; high-performance systems.) Note: Minad, the author of Consult, does not
  ;; recommend aggressive values.
  ;; Read: https://github.com/minad/consult/discussions/951
  ;;
  ;; However, the author of minimal-emacs.d uses these parameters to achieve
  ;; immediate feedback from Consult.
  ;; (setq consult-async-input-debounce 0.02
  ;;       consult-async-input-throttle 0.05
  ;;       consult-async-refresh-delay 0.02)

  :config
  (consult-customize
   consult-theme :preview-key '(:debounce 0.2 any)
   consult-ripgrep consult-git-grep consult-grep
   consult-bookmark consult-recent-file consult-xref
   consult-source-bookmark consult-source-file-register
   consult-source-recent-file consult-source-project-recent-file
   ;; :preview-key "M-."
   :preview-key '(:debounce 0.4 any))
  (setq consult-narrow-key "<"))

;; History & stuffs.

;; Auto-revert in Emacs is a feature that automatically updates the
;; contents of a buffer to reflect changes made to the underlying file
;; on disk.
(use-package autorevert
  :straight (:type built-in)
  :commands (auto-revert-mode global-auto-revert-mode)
  :hook
  (emacs-startup . global-auto-revert-mode)
  :custom
  (auto-revert-interval 3)
  (auto-revert-remote-files nil)
  (auto-revert-use-notify t)
  (auto-revert-avoid-polling t)
  (auto-revert-verbose t))

;; Recentf is an Emacs package that maintains a list of recently
;; accessed files, making it easier to reopen files you have worked on
;; recently.
(use-package recentf
  :straight (:type built-in)
  :commands (recentf-mode recentf-cleanup)
  :hook
  (emacs-startup . recentf-mode)

  :custom
  (recentf-auto-cleanup (if (daemonp) 300 'never))
  (recentf-exclude
   (list "\\.tar$" "\\.tbz2$" "\\.tbz$" "\\.tgz$" "\\.bz2$"
         "\\.bz$" "\\.gz$" "\\.gzip$" "\\.xz$" "\\.zip$"
         "\\.7z$" "\\.rar$"
         "COMMIT_EDITMSG\\'"
         "\\.\\(?:gz\\|gif\\|svg\\|png\\|jpe?g\\|bmp\\|xpm\\)$"
         "-autoloads\\.el$" "autoload\\.el$"))

  :config
  ;; A cleanup depth of -90 ensures that `recentf-cleanup' runs before
  ;; `recentf-save-list', allowing stale entries to be removed before the list
  ;; is saved by `recentf-save-list', which is automatically added to
  ;; `kill-emacs-hook' by `recentf-mode'.
  (add-hook 'kill-emacs-hook #'recentf-cleanup -90))

;; savehist is an Emacs feature that preserves the minibuffer history between
;; sessions. It saves the history of inputs in the minibuffer, such as commands,
;; search strings, and other prompts, to a file. This allows users to retain
;; their minibuffer history across Emacs restarts.
(use-package savehist
  :straight (:type built-in)
  :commands (savehist-mode savehist-save)
  :hook
  (emacs-startup . savehist-mode)
  :custom
  (savehist-autosave-interval 600)
  (savehist-additional-variables
   '(kill-ring                        ; clipboard
     register-alist                   ; macros
     mark-ring global-mark-ring       ; marks
     search-ring regexp-search-ring)))

;; save-place-mode enables Emacs to remember the last location within a file
;; upon reopening. This feature is particularly beneficial for resuming work at
;; the precise point where you previously left off.
(use-package saveplace
  :straight (:type built-in)
  :commands (save-place-mode save-place-local-mode)
  :hook
  (emacs-startup . save-place-mode)
  :custom  (save-place-limit 400))

;; Enable `auto-save-mode' to prevent data loss. Use `recover-file' or
;; `recover-session' to restore unsaved changes.
(setq auto-save-default t)
(setq auto-save-interval 300)
(setq auto-save-timeout 30)

;; Dired.
(use-package dired
  :straight (:type built-in)
  :hook
  (dired-mode . dired-omit-mode)
  :custom
  (dired-mouse-drag-files t)
  (dired-free-space nil)
  (dired-kill-when-opening-new-dired-buffer t)
  (dired-listing-switches "-l --almost-all --human-readable --group-directories-first --no-group")
  (dired-omit-files (concat "\\`[.]?#\\|\\`[.][.]?\\'" "\\|^\\..*$"))
  :config
  (require 'dired-x))

(use-package image-dired
  :straight (:type built-in)
  :custom (image-dired-thumbnail-storage 'standard))

(use-package dirvish
  :commands (dirvish dirvish-dwim dirvish-dispatch dirvish-override-dired-mode)
  :bind
  (("C-c F" . dirvish-dwim)
   :map dirvish-mode-map               ; Dirvish inherits `dired-mode-map'
   ("?"   . dirvish-dispatch)          ; [?] a helpful cheatsheet
   ("a"   . dirvish-setup-menu)        ; [a]ttributes settings:`t' toggles mtime, `f' toggles fullframe, etc.
   ("f"   . dirvish-file-info-menu)    ; [f]ile info
   ("o"   . dirvish-quick-access)      ; [o]pen `dirvish-quick-access-entries'
   ("s"   . dirvish-quicksort)         ; [s]ort flie list
   ("r"   . dirvish-history-jump)      ; [r]ecent visited
   ("l"   . dirvish-ls-switches-menu)  ; [l]s command flags
   ("v"   . dirvish-vc-menu)           ; [v]ersion control commands
   ("*"   . dirvish-mark-menu)
   ("y"   . dirvish-yank-menu)
   ("N"   . dirvish-narrow)
   (";"   . dirvish-history-last)
   ("TAB" . dirvish-subtree-toggle)
   ("M-f" . dirvish-history-go-forward)
   ("M-b" . dirvish-history-go-backward)
   ("M-e" . dirvish-emerge-menu))
  :custom
  (dirvish-quick-access-entries ; It's a custom option, `setq' won't work
   '(("h" "~/"                          "Home")
     ("d" "~/Downloads/"                "Downloads")
     ("a" "~/work/ponyai/.sub-repos"    "ponyai")
     ("b" "~/work/ponyai1/.sub-repos"   "ponyai1")
     ("c" "~/work/ponyai2/.sub-repos"   "ponyai2")))
  (dirvish-mode-line-format
   '(:left (sort symlink) :right (omit yank index)))
  (dirvish-mode-line-height 10)
  (dirvish-attributes
   '(nerd-icons file-time file-size collapse subtree-state vc-state git-msg))
  (dirvish-subtree-state-style 'nerd)
  (dirvish-path-separators (list
                            (format "  %s " (nerd-icons-codicon "nf-cod-home"))
                            (format "  %s " (nerd-icons-codicon "nf-cod-root_folder"))
                            (format " %s " (nerd-icons-faicon "nf-fa-angle_right"))))
  :init
  (with-eval-after-load 'dired
    (dirvish-override-dired-mode)))

;; Visual cues & general editor config.
(add-hook
 'prog-mode-hook
 (lambda ()
   ;; (display-line-numbers-mode)
   (toggle-truncate-lines 0)
   (setq show-trailing-whitespace t)))

(blackout 'display-line-numbers-mode)
(blackout 'visual-line-mode)

(custom-set-variables
 ;; editing
 '(truncate-lines t)
 '(tab-width 4))

;; (use-package whitespace
;;   :straight (:type built-in)
;;   :hook (prog-mode . whitespace-mode)
;;   :blackout whitespace-mode)

(use-package hl-line
  :straight (:type built-in)
  :blackout hi-line-mode
  :hook
  (prog-mode . hl-line-mode)
  (tabulated-list-mode . hl-line-mode))

;; Version control.
(use-package magit
  :bind
  (:map magit-status-mode-map
        ("p" . magit-push)
        ("n" . magit-status-jump)
        ("x" . magit-discard))
  :commands (magit))

(use-package diff-hl
  :hook
  (emacs-startup . global-diff-hl-mode)
  (magit-post-refresh-hook . diff-hl-magit-post-refresh)
  :config
  (diff-hl-flydiff-mode))

;; Terminal emulator.

(use-package with-editor
  :commands with-editor)

;; Thank you, sire!
;; https://github.com/blahgeek/emacs.d/blob/master/init.el#L3558
(use-package server
  :straight (:type built-in)
  :demand t
  :config
  ;; Make sure the server is running.
  ;; (copied from with-editor)
  ;; we don't want to use with-editor because it would add process filter
  ;; (for its fallback sleeping editor) which is slow
  (unless (process-live-p server-process)
    (when (server-running-p server-name)
      (setq server-name (format "server%s" (emacs-pid)))
      (when (server-running-p server-name)
        (server-force-delete server-name)))
    (server-start))
  (let ((server_socket (expand-file-name server-name server-socket-dir)))
    (setenv "EMACS_SERVER_SOCKET" server_socket)
    (setenv "EDITOR" (concat "emacsclient -s " server_socket))))

(use-package eat
  :straight (eat :type git :host codeberg :repo "akib/emacs-eat"
                 :fork (:host github :repo "blahgeek/emacs-eat" :branch "dev"))
  :bind
  (("C-c E" . eat-project-other-window))
  :custom
  (eat-kill-buffer-on-exit t)
  ;; disable the default process-kill-buffer-query-function
  ;; see above my/term-process-kill-buffer-query-function
  (eat-query-before-killing-running-terminal nil)
  (eat-term-scrollback-size (* 64 10000))  ;; chars. ~10k lines?
  (eat-term-name "xterm-256color")
  :commands (eat eat-mode eat-exec)
  :config
  (add-hook
   'eat-mode-hook
   #'(lambda ()
       (add-hook 'meow-insert-enter-hook #'eat-char-mode 0 t)
       (add-hook 'meow-insert-exit-hook #'eat-line-mode 0 t))))

;; Project management.

(use-package find-file
  :straight (:type built-in)
  :custom
  ;; (ff-ignore-include t)
  (cc-other-file-alist
   ;; modified so that .h is the first item, which will be created when not found
   `((,(rx "." (or "c" "cc" "c++" "cpp" "cxx" "CC" "C" "C++" "CPP" "CXX") eos)
      (".h" ".hh" ".hpp" ".hxx" ".H" ".HPP" ".HH"))
     (,(rx "." (or "h" "hh" "hpp" "hxx" "H" "HPP" "HH") eos)
      (".cc" ".c" ".cxx" ".cpp" ".c++" ".CC" ".C" ".CXX" ".CPP" ".C++")))))

(use-package project
  :straight (:type built-in)
  :demand t
  :bind
  ;; I don't use this for ~mark-page~ and this "conflicts" with ~C-x p~ in ~meow-mode~, so unbind it.
  (("C-x C-p" . nil)
   :map project-prefix-map
   ("f" . consult-fd)
   ("h" . ff-find-other-file)
   ("/" . consult-ripgrep))
  :config
  ;; I owe you so much, sire.
  ;; https://github.com/blahgeek/emacs.d/blob/master/init.el#L1929C5-L1948C1
  (add-to-list 'project-kill-buffer-conditions '(major-mode . eat-mode) 'append)

  (defvar-local my/project-cache nil
    "Cached result of `my/project-try'.
nil means not cached;
otherwise it should be '(dir . value). (value may be nil).
dir is the directory of the buffer (param of my/project-try), when it's changed, the cache is invalidated")

  (defun my/project-try (dir)
    (cond
     ((equal (car my/project-cache) dir)
      (cdr my/project-cache))
     ((file-remote-p dir)
      nil)
     (t
      (let* ((try-markers '((".dir-locals.el" ".projectile" ".project" "WORKSPACE")
                            (".git" ".svn")))
             (res (cl-loop for markers in try-markers
                           for root = (locate-dominating-file
                                       dir
                                       (lambda (x)
                                         (seq-some
                                          (lambda (marker) (file-exists-p (expand-file-name marker x)))
                                          markers)))
                           when root return (cons 'my/proj root))))
        (setq-local my/project-cache (cons dir res))  ;; res may be nil, but also cache
        res))))

  ;; NOTE: Remove the default #'project-try-vc! Only keep blahgeek's version. The default implementation is slow.
  ;; bug#78545
  (setq project-find-functions (list #'my/project-try))

  (cl-defmethod project-root ((project (head my/proj)))
    (cdr project))

  (cl-defmethod project-name ((project (head my/proj)))
    ;; support for pony style project name (.sub-repos)
    (or (let* ((dir (project-root project))
               (parts (nreverse (string-split dir "/" t))))
          (when (and (length> parts 1)
                     (string-prefix-p "." (car parts)))
            (format "%s/%s" (cadr parts) (car parts))))
        (cl-call-next-method)))

  (defun my/current-project-root ()
    (when-let* ((p (project-current)))
      (project-root p)))

  :custom
  (project-vc-extra-root-markers '(".projectile" ".project"))
  (project-mode-line t))

(use-package ibuffer  ;; builtin
  :straight (:type built-in)
  :bind
  (("C-x C-b" . ibuffer))
  :custom
  (ibuffer-default-sorting-mode 'filename/process))

;; (use-package bufler
;;   :bind
;;   (("C-x C-b" . bufler-switch-buffer))
;;   :commands (bufler)
;;   :hook
;;   (emacs-startup . bufler-mode)
;;   (emacs-startup . bufler-workspace-workspaces-as-tabs-mode)
;;   :config
;;   ;; Somehow the autoload for bufler-workspace-workspaces-as-tabs-mode is incorrect.
;;   (require 'bufler-workspace-tabs))

;; The easysession Emacs package is a session manager for Emacs that can persist
;; and restore file editing buffers, indirect buffers/clones, Dired buffers,
;; windows/splits, the built-in tab-bar (including tabs, their buffers, and
;; windows), and Emacs frames. It offers a convenient and effortless way to
;; manage Emacs editing sessions and utilizes built-in Emacs functions to
;; persist and restore frames.
(use-package easysession
  :blackout easysession-save-mode
  :commands (easysession-switch-to
             easysession-save-as
             easysession-save-mode
             easysession-load-including-geometry)

  :custom
  (easysession-mode-line-misc-info t)  ; Display the session in the modeline
  (easysession-save-interval (* 10 60))  ; Save every 10 minutes
  (easysession-directory (expand-file-name "easysession" no-littering-var-directory))

  :bind
  ;; Key mappings:
  ;; C-c l for switching sessions
  ;; and C-c s for saving the current session
  ("C-c s l" . 'easysession-switch-to)
  ("C-c s s" . 'easysession-save-as)

  :init
  ;; The depth 102 and 103 have been added to to `add-hook' to ensure that the
  ;; session is loaded after all other packages. (Using 103/102 is particularly
  ;; useful for those using minimal-emacs.d, where some optimizations restore
  ;; `file-name-handler-alist` at depth 101 during `emacs-startup-hook`.)
  ;; (add-hook 'emacs-startup-hook #'easysession-load-including-geometry 102)
  (add-hook
   'emacs-startup-hook
   #'(lambda ()
       (easysession-save-mode)
       ;; Add these hooks later so that we do not reset when first entering save mode,
       ;; to avoid killing async compilation buffers from compile-angel.
       (add-hook 'easysession-before-load-hook #'easysession-reset)
       (add-hook 'easysession-new-session-hook #'easysession-reset))
   103))

(use-package buffer-terminator
  :hook
  (emacs-startup . buffer-terminator-mode))

;; Org.

;; Org mode is a major mode designed for organizing notes, planning, task
;; management, and authoring documents using plain text with a simple and
;; expressive markup syntax. It supports hierarchical outlines, TODO lists,
;; scheduling, deadlines, time tracking, and exporting to multiple formats
;; including HTML, LaTeX, PDF, and Markdown.
(use-package org
  :straight (:type built-in)
  :commands (org-mode org-version)
  :mode
  ("\\.org\\'" . org-mode)
  :custom
  (org-adapt-indentation nil)
  (org-edit-src-content-indentation 0)
  (org-id-method 'ts)
  (org-id-ts-format "%Y%m%dT%H%M%S")
  (org-download-screenshot-method "flameshot gui --raw > %s")
  (org-src-preserve-indentation t)
  (org-fontify-done-headline t)
  (org-fontify-todo-headline t)
  (org-fontify-whole-heading-line t)
  (org-fontify-quote-and-verse-blocks t)
  :config
  (require 'org-tempo))

(use-package org-journal
  :bind ("C-c n j" . org-journal-new-entry)
  :custom
  (org-journal-dir (file-truename "~/pylon/journals/"))
  (org-journal-date-prefix "#+TITLE: ")
  (org-journal-date-format "%A, %B %d %Y"))

(use-package org-roam
  :init
  (with-eval-after-load
      'org
    (org-roam-db-autosync-mode))
  :bind
  ("C-c n c" . org-roam-capture)
  ("C-c n d" . org-roam-dailies-goto-today)
  ("C-c n g" . org-roam-graph)
  ("C-c n f" . org-roam-node-find)
  ("C-c n i" . org-roam-node-insert)
  :custom
  (org-roam-capture-templates
   '(("d" "default" plain "%?" :target
      (file+head
       "%<%Y%m%dT%H%M%S>-${slug}.org"
       ":PROPERTIES:\n:ID:       %(car (split-string (file-name-nondirectory (org-roam-capture--get :new-file)) \"-\"))\n:END:\n#+title: ${title}\n")
      :unnarrowed t)))
  (org-roam-extract-new-file-path "%<%Y%m%dT%H%M%S>-${slug}.org")
  (org-roam-directory (file-truename "~/pylon")))

;; Programming.

(use-package dumb-jump
  :commands
  dumb-jump-xref-activate
  :init
  (add-hook 'xref-backend-functions #'dumb-jump-xref-activate))

;; Tree-sitter in Emacs is an incremental parsing system introduced in Emacs 29
;; that provides precise, high-performance syntax highlighting. It supports a
;; broad set of programming languages, including Bash, C, C++, C#, CMake, CSS,
;; Dockerfile, Go, Java, JavaScript, JSON, Python, Rust, TOML, TypeScript, YAML,
;; Elisp, Lua, Markdown, and many others.
(use-package treesit-auto
  :hook
  (emacs-startup . global-treesit-auto-mode)
  :custom
  (treesit-auto-install 'prompt)
  :config
  (treesit-auto-add-to-auto-mode-alist 'all)

  (add-to-list 'major-mode-remap-alist '(c-mode . c-ts-mode))
  (add-to-list 'major-mode-remap-alist '(c++-mode . c++-ts-mode))
  (add-to-list 'major-mode-remap-alist
               '(c-or-c++-mode . c-or-c++-ts-mode)))

(use-package flycheck
  :blackout global-flycheck-mode
  :hook
  (emacs-startup . global-flycheck-mode))

(use-package lsp-mode
  :blackout lsp-mode
  :init
  (setenv "LSP_USE_PLISTS" "true")
  (setq lsp-keymap-prefix "C-c l")
  :commands (lsp lsp-deferred)
  :hook
  (c-ts-base-mode . lsp-deferred)
  :config
  (unless lsp-use-plists
    (error "`lsp-use-plists' is not set!"))
  ;; I owe you so much, sire.
  ;; https://github.com/blahgeek/emacs.d/blob/master/init.el#L3032C44-L3034C104
  ;; https://emacs-lsp.github.io/lsp-mode/page/faq/
  ;; forget the workspace folders for multi root servers so the workspace folders are added on demand
  (define-advice lsp (:before (&rest _) ignore-multi-root)
    "Ignore multi-root while starting lsp."
    (eval '(setf (lsp-session-server-id->folders (lsp-session)) (ht))))

  (defun lsp-booster--advice-json-parse (old-fn &rest args)
    "Try to parse bytecode instead of json."
    (or
     (when (equal (following-char) ?#)
       (let ((bytecode (read (current-buffer))))
         (when (byte-code-function-p bytecode)
           (funcall bytecode))))
     (apply old-fn args)))
  (advice-add (if (progn (require 'json)
                         (fboundp 'json-parse-buffer))
                  'json-parse-buffer
                'json-read)
              :around
              #'lsp-booster--advice-json-parse)

  (defun lsp-booster--advice-final-command (old-fn cmd &optional test?)
    "Prepend emacs-lsp-booster command to lsp CMD."
    (let ((orig-result (funcall old-fn cmd test?)))
      (if (and (not test?)                             ;; for check lsp-server-present?
               (not (file-remote-p default-directory)) ;; see lsp-resolve-final-command, it would add extra shell wrapper
               lsp-use-plists
               (not (functionp 'json-rpc-connection))  ;; native json-rpc
               (executable-find "emacs-lsp-booster"))
          (progn
            (when-let ((command-from-exec-path (executable-find (car orig-result))))  ;; resolve command from exec-path (in case not found in $PATH)
              (setcar orig-result command-from-exec-path))
            (message "Using emacs-lsp-booster for %s!" orig-result)
            (cons "emacs-lsp-booster" orig-result))
        orig-result)))
  (advice-add 'lsp-resolve-final-command :around #'lsp-booster--advice-final-command)

  ;; this is mostly for bazel. to avoid jumping to bazel execroot
  (define-advice lsp--uri-to-path (:filter-return (path) follow-symlink)
    (file-truename path)))

(use-package lsp-ui)

(use-package lsp-pyright
  :custom
  (lsp-pyright-multi-root nil)
  (lsp-pyright-langserver-command "pyright")
  :hook
  (python-base-mode
   .
   (lambda ()
     (require 'lsp-pyright)
     (lsp-deferred))))

(use-package jsonnet-mode)

(use-package google-c-style
  :demand t
  :config (c-add-style "Google" google-c-style))

(use-package eldoc
  :blackout t
  :straight (:type built-in))

(use-package dtrt-indent
  :blackout t
  :hook (prog-mode . dtrt-indent-mode)
  :config
  (add-to-list 'dtrt-indent-hook-mapping-list
               '(cmake-mode default cmake-tab-width)))

(use-package apheleia
  :hook (emacs-startup . apheleia-global-mode)
  :config
  (setf (alist-get 'python-mode apheleia-mode-alist)
        '(ruff-isort ruff))
  (setf (alist-get 'python-ts-mode apheleia-mode-alist)
        '(ruff-isort ruff)))

(use-package nix-mode
  :mode "\\.nix\\'")

(use-package bazel)

;; AIs.

;; Github Copilot integration that uses copliot-language-server
(use-package copilot
  :straight (:host github :repo "copilot-emacs/copilot.el")
  :commands copilot-mode copilot-completion)

(use-package copilot-chat
  :straight (:host github :repo "chep/copilot-chat.el" :files ("*.el"))
  :after (request org markdown-mode)
  :commands copilot-chat copilot-chat-display)

(use-package gptel
  :commands gptel gptel-send gptel-rewrite gptel-add gptel-add-file gptel-org-set-topic
  :bind ("C-c g" . gptel-menu)
  :hook
  (gptel-mode . (lambda () (toggle-truncate-lines 1)))
  :custom
  (gptel-default-mode 'org-mode)
  :config
  (defun read-gptel-backend-config (path)
    (with-temp-buffer
      (insert-file-contents path)
      (let* ((parsed-json (json-parse-buffer :object-type 'alist :array-type 'list))
             (kwargs (mapcar (lambda (item) `(,(intern (concat ":" (symbol-name (car item)))) ,(cdr item))) parsed-json)))
        (apply #'append kwargs))))

  (if (file-exists-p "~/.config/github-copilot/apps.json")
      (setq gptel-backend (gptel-make-gh-copilot "Copilot")))
  (if (file-exists-p "~/.config/minimaxi-chat-token.json")
      (setq gptel-backend
            (apply #'gptel-make-anthropic "Minimaxi"
                   (read-gptel-backend-config "~/.config/minimaxi-chat-token.json"))))
  (if (file-exists-p "~/.config/deepseek-token.json")
      (setq gptel-backend
            (apply #'gptel-make-deepseek "DeepSeek"
                   (read-gptel-backend-config "~/.config/deepseek-token.json"))))
  (if (file-exists-p "~/.config/openweb-ui-token.json")
      (setq gptel-backend
            (apply #'gptel-make-openai "OpenWebUI"
                   (read-gptel-backend-config "~/.config/openweb-ui-token.json")))))

(use-package ob-gptel
  :straight (:type git :host github :repo "jwiegley/ob-gptel")
  :hook ((org-mode . ob-gptel-install-completions))
  :defines ob-gptel-install-completions
  :config
  (add-to-list 'org-babel-load-languages '(gptel . t))
  ;; Optional, for better completion-at-point
  (defun ob-gptel-install-completions ()
    (add-hook 'completion-at-point-functions
              'ob-gptel-capf nil t)))

(use-package aider
  :bind ("C-c a" . aider-transient-menu)
  :config
  ;; or use aider-transient-menu-2cols / aider-transient-menu-1col, for narrow screen
  ;; add aider magit function to magit menu
  (aider-magit-setup-transients))

(use-package agent-shell
  :commands agent-shell
  :bind ("C-c d" . agent-shell-help-menu))


(use-package claude-code-ide
  :straight (:type git :host github :repo "manzaltu/claude-code-ide.el")
  :bind ("C-c D" . claude-code-ide-menu) ; Set your favorite keybinding
  :custom
  (claude-code-ide-terminal-backend 'eat)
  :config
  (claude-code-ide-emacs-tools-setup))

(use-package opencode
  :straight (opencode :type git :host codeberg :repo "sczi/opencode.el")
  :bind ("C-c o" . opencode))

;; More speed optimizations.

;; Copied from
;; https://github.com/jamescherti/minimal-emacs.d?tab=readme-ov-file#optimization-native-compilation.
;; Native compilation enhances Emacs performance by converting Elisp code into
;; native machine code, resulting in faster execution and improved
;; responsiveness.
;;
;; Ensure adding the following compile-angel code at the very beginning
;; of your `~/.emacs.d/post-init.el` file, before all other packages.
(use-package compile-angel
  :blackout compile-angel-on-load-mode
  :demand t
  :custom
  ;; Set `compile-angel-verbose` to nil to suppress output from compile-angel.
  ;; Drawback: The minibuffer will not display compile-angel's actions.
  (compile-angel-verbose t)

  :config
  ;; See above ~use-package repeat-fu~ for explanation.
  (push "/repeat-fu-preset-meow.el" compile-angel-excluded-files)
  ;; The following directive prevents compile-angel from compiling your init
  ;; files. If you choose to remove this push to `compile-angel-excluded-files'
  ;; and compile your pre/post-init files, ensure you understand the
  ;; implications and thoroughly test your code. For example, if you're using
  ;; the `use-package' macro, you'll need to explicitly add:
  ;; (eval-when-compile (require 'use-package))
  ;; at the top of your init file.
  (push "/init.el" compile-angel-excluded-files)
  (push "/early-init.el" compile-angel-excluded-files)
  (push "/pre-init.el" compile-angel-excluded-files)
  (push "/post-init.el" compile-angel-excluded-files)
  (push "/pre-early-init.el" compile-angel-excluded-files)
  (push "/post-early-init.el" compile-angel-excluded-files)

  ;; A local mode that compiles .el files whenever the user saves them.
  ;; (add-hook 'emacs-lisp-mode-hook #'compile-angel-on-save-local-mode)

  ;; A global mode that compiles .el files prior to loading them via `load' or
  ;; `require'. Additionally, it compiles all packages that were loaded before
  ;; the mode `compile-angel-on-load-mode' was activated.
  ;; Disable this in debug mode because it may trigger loading of code not defined
  ;; during normal compilation.
  (when (not minimal-emacs-debug)
    (compile-angel-on-load-mode 1)))

;; See https://emacsredux.com/blog/2026/04/07/stealing-from-the-best-emacs-configs/
(setq-default bidi-display-reordering 'left-to-right
              bidi-paragraph-direction 'left-to-right)
(setq bidi-inhibit-bpa t)

;; Theme.
(use-package modus-themes
  :demand t
  :config
  ;; Load the specific theme
  (load-theme 'modus-operandi t))
;; Do not use the theme bundled with emacs as it somehow causes slow start.
;; (load-theme 'modus-operandi t)
;; (setq modus-themes-mixed-fonts t
;;       modus-themes-variable-pitch-ui t
;;       modus-themes-italic-constructs t
;;       modus-themes-bold-constructs t
;;       modus-themes-completions '((t . (bold)))
;;       modus-themes-prompts '(bold)
;;       modus-themes-headings
;;       '((agenda-structure . (variable-pitch light 2.2))
;;         (agenda-date . (variable-pitch regular 1.3))
;;         (t . (regular 1.15))))
;; (setq modus-themes-common-palette-overrides nil)

;; It seems that if I set-frame-font here, then the
;; daemon would give very small font size for emacsclient.
(custom-set-variables
 '(text-scale-mode-step 1.02))
(setq
 list-faces-sample-text
 "abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ 天地玄黄，宇宙洪荒。 てんちげんこう、うちゅうこうこう。"
 use-default-font-for-symbols nil)
(when (display-graphic-p)
  (cl-dolist (fontname '("JetBrains Mono-11" "Hack-12" "Ubuntu Mono-14"))
    (when (find-font (font-spec :name fontname))
      (set-face-font 'default fontname)
      (set-face-font 'fixed-pitch fontname)
      (cl-return fontname)))
  (cl-dolist (fontname '("Sarasa Mono SC" "Source Han Sans CN" "Noto Sans CJK SC"))
    (when (find-font (font-spec :name fontname))
      (dolist (scriptname '(han kana))
        (set-fontset-font (frame-parameter nil 'font) scriptname (font-spec :name fontname)))
      (cl-return fontname)))
  ;; See https://baohaojun.github.io/perfect-emacs-chinese-font.html.
  (cl-dolist (item '(("JetBrains Mono" 1.25) ("Hack" 1.2)))
    (pcase-let ((`(,fontname ,scale) item))
      (when (string= (font-get (face-attribute 'default :font) :family) fontname)
        (setq face-font-rescale-alist `(("Sarasa Mono SC" . ,scale)))
        (cl-return fontname)))))

(use-package nerd-icons-completion
  :hook
  (emacs-startup . nerd-icons-completion-mode)
  (marginalia-mode-hook . nerd-icons-completion-marginalia-setup))

(use-package nerd-icons-corfu
  :init
  (with-eval-after-load 'corfu
    (add-to-list 'corfu-margin-formatters #'nerd-icons-corfu-formatter)))

(use-package doom-modeline
  :hook (emacs-startup . doom-modeline-mode)
  :custom
  (doom-modeline-buffer-encoding nil)
  ;; Don't abbreviate vc branch name too eagerly.
  (doom-modeline-vcs-max-length 30)
  ;; Define custom modeline with vcs before misc-info (easysession).
  :config
  (doom-modeline-def-modeline 'main
    '(eldoc bar window-state workspace-name window-number modals matches follow buffer-info remote-host buffer-position word-count parrot selection-info vcs)
    '(compilation objed-state misc-info project-name persp-name battery grip irc mu4e gnus github debug repl lsp minor-modes input-method indent-info buffer-encoding major-mode process check time))
  (doom-modeline-set-modeline 'main 'default))

(use-package popper
  :hook
  (emacs-startup . popper-mode)
  (emacs-startup . popper-echo-mode)
  :custom
  (popper-reference-buffers
   '("\\*Messages\\*"
     "Output\\*$"
     "\\*Async Shell Command\\*"
     help-mode
     compilation-mode))
  (popper-group-function #'popper-group-by-project))

(load custom-file 'noerror 'no-message)
