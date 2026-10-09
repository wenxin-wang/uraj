;;; guix build -L src/guix -L src/guile -f test/guix/uraj/services/paseo-sandbox.scm
(use-modules (guix gexp) (uraj home paseo) (uraj home paseo-broker))
(file-union
 "paseo-sandbox-test"
 `(("sandbox-helper" ,paseo-sandbox-program)
   ("supervisor" ,supervisor)
   ("service" ,paseo-service-program)
   ("profile" ,paseo-daemon-profile)))
