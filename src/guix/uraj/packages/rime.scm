(define-module (uraj packages rime)
  #:use-module (guix build-system copy)
  #:use-module (guix gexp)
  #:use-module (guix git)
  #:use-module (guix git-download)
  #:use-module ((guix licenses) #:prefix license:)
  #:use-module (guix packages)
  #:export (rime-ice
            rime-ice-data-files))

;;; Mirrors the `install_files' list in the upstream recipe.yaml -- the data
;;; files that plum installs into a Rime user directory (dictionaries,
;;; schemas, Lua scripts, OpenCC data), not the repo's docs and tooling.
;;; Keep it in sync with the recipe when bumping the version.
(define rime-ice-data-files
  '("cn_dicts"
    "en_dicts"
    "opencc"
    "lua"
    "default.yaml"
    "squirrel.yaml"
    "weasel.yaml"
    "rime_ice.schema.yaml"
    "rime_ice.dict.yaml"
    "t9.schema.yaml"
    "double_pinyin.schema.yaml"
    "double_pinyin_abc.schema.yaml"
    "double_pinyin_mspy.schema.yaml"
    "double_pinyin_sogou.schema.yaml"
    "double_pinyin_flypy.schema.yaml"
    "double_pinyin_ziguang.schema.yaml"
    "double_pinyin_jiajia.schema.yaml"
    "symbols_v.yaml"
    "symbols_caps_v.yaml"
    "radical_pinyin.schema.yaml"
    "radical_pinyin.dict.yaml"
    "melt_eng.schema.yaml"
    "melt_eng.dict.yaml"
    "custom_phrase.txt"))

(define-public rime-ice
  (package
    (name "rime-ice")
    (version "2026.06.30")
    (source
     (origin
       (method git-fetch)
       (uri (git-reference
             (url "https://github.com/iDvel/rime-ice")
             (commit "6810e8916d160498620a16fef2135956fecbd485")))
       (file-name (git-file-name name version))
       (sha256
        (base32 "1jvnwaaykr78917y4sl8mg8f2f1yn1z0354xm4hxmpx1i0aq25qx"))))
    (build-system copy-build-system)
    (arguments
     (list #:phases
           #~(modify-phases %standard-phases
               (add-after 'unpack 'fix-luajit-pin-cand-patterns
                 (lambda _
                   ;; Guix's librime uses LuaJIT (Lua 5.1): patterns cannot
                   ;; contain literal NUL bytes.  %z matches the same separator.
                   (substitute* "lua/pin_cand_filter.lua"
                     (("\"\\[\\^\" \\.\\. delimiter \\.\\. \"\\]\\+\"")
                      "\"[^%z]+\"")))))
           #:install-plan
           ;; The plan is spliced into the builder as an expression tree, so
           ;; it needs to be quoted there for the lists to be data rather
           ;; than calls.
           #~(quote #$(map (lambda (file)
                             (list file (string-append "share/rime-ice/" file)))
                           rime-ice-data-files))))
    (home-page "https://github.com/iDvel/rime-ice")
    (synopsis "Rime schemas, dictionaries and plugins for Pinyin input")
    (description
     "Rime-ice (雾凇拼音) is a collection of Rime input schemas that work
out of the box: it ships its own dictionaries, OpenCC transform data and
Lua plugins, and outputs Simplified Chinese by default.  This package only
provides the data files; link them into a Rime user directory (for fcitx5
users, @file{~/.local/share/fcitx5/rime}) and add @code{rime_ice} to
@code{schema_list} to use it.")
    (license license:gpl3)))
