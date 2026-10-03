;;; On-demand IKEv2 connections; only encrypted files enter the store.
(define-module (uraj services strongswan)
  #:use-module (gnu services)
  #:use-module (gnu services base)
  #:use-module (gnu services shepherd)
  #:use-module (gnu packages vpn)
  #:use-module (gnu packages nss)
  #:use-module (gnu packages dns)
  #:use-module (guix gexp)
  #:use-module (sops services sops)
  #:use-module (sops secrets)
  #:use-module (srfi srfi-1)
  #:use-module (srfi srfi-13)
  #:use-module (srfi srfi-14)
  #:use-module (uraj utils file path)
  #:export (strongswan-services))

(define (strongswan-daemon-configuration)
  (mixed-text-file "strongswan.conf"
    "charon {
  load = random nonce aes sha1 sha2 md4 hmac kdf pem pkcs1 pkcs8 x509 constraints pubkey openssl kernel-netlink socket-default vici resolve eap-identity eap-mschapv2 eap-md5 eap-tls eap-ttls eap-peap
  plugins {
    vici {
      socket = unix:///run/strongswan-charon.vici
    }
    resolve {
      resolvconf {
        path = \"" (file-append openresolv "/sbin/resolvconf") " -x\"
        iface = lo.strongswan-charon
      }
    }
  }
  syslog {
    daemon {
      default = -1
    }
    auth {
      default = -1
    }
  }
}\n"))

(define (strongswan-public-connections names)
  ;; Only public names are substituted at build time. Private fields are merged
  ;; by swanctl from root-only runtime includes, never read by this builder.
  (let ((template
         (local-file (project-path "env/strongswan/road-warrior-all-tunnel.conf.tmpl"))))
    (computed-file "strongswan-connections.conf"
      #~(begin
          (use-modules (ice-9 textual-ports) (ice-9 string-fun))
          (let ((text (call-with-input-file #$template get-string-all)))
            (call-with-output-file #$output
              (lambda (port)
                (for-each
                 (lambda (name)
                   (display (string-replace-substring text "@NAME@" name) port))
                 '#$names))))))))

(define (strongswan-services connections)
  "CONNECTIONS is an alist of public names to root-only SOPS secrets.
Each secret contains private swanctl fields in the named IKE and EAP sections.
Legacy full configurations are also accepted; the public template takes
precedence for its fields. Register the secrets with host-sops-services."
  (let* ((names (map car connections))
         (files (map (lambda (entry) (sops-secret->secret-file (cdr entry)))
                     connections))
         (swanctl (file-append strongswan "/sbin/swanctl"))
         ;; Resolve requests DNS attributes and reference-counts them across
         ;; IKE SAs. openresolv keeps the physical link's DNS for disconnect.
         ;; -x excludes physical-link DNS while the VPN DNS entry exists.
         (daemon-config (strongswan-daemon-configuration))
         (config
          (mixed-text-file "swanctl.conf"
            "authorities {\n  isrg-x1 {\n    cacert = "
            (file-append nss-certs "/etc/ssl/certs/ISRG_Root_X1.pem")
            "\n  }\n  isrg-x2 {\n    cacert = "
            (file-append nss-certs "/etc/ssl/certs/ISRG_Root_X2.pem")
            "\n  }\n}\n"
            (string-concatenate
             (map (lambda (file) (string-append "include " file "\n")) files))
            "include " (strongswan-public-connections names) "\n"))
         (uri "unix:///run/strongswan-charon.vici"))
    (unless (and (= (length names) (length (delete-duplicates names)))
                 (every (lambda (name)
                          (and (string? name) (positive? (string-length name))
                               (string-every
                                (lambda (c)
                                  (char-set-contains? char-set:ascii c)) name)
                               (string-every
                                (lambda (c) (or (char-alphabetic? c)
                                                (char-numeric? c)
                                                (memv c '(#\- #\_)))) name)))
                        names))
      (error "VPN names must be unique ASCII letters, digits, hyphens or underscores"))
    (for-each
     (lambda (entry)
       (let ((secret (cdr entry)))
         (unless (and (string=? (sops-secret-user secret) "root")
                      (string=? (sops-secret-group secret) "root")
                      (= (sops-secret-permissions secret) #o400))
           (error "VPN secrets must be root:root 0400"))))
     connections)
    (list
     (simple-service 'strongswan-tools profile-service-type
                     (list strongswan openresolv))
     (simple-service 'strongswan-on-demand shepherd-root-service-type
       (cons
        (shepherd-service
         (provision '(strongswan-charon))
         (requirement '(user-processes networking))
         (auto-start? #f)
         (respawn? #f)
         (documentation "On-demand strongSwan VICI daemon.")
         (start #~(make-forkexec-constructor
                   (list #$(file-append strongswan "/libexec/ipsec/charon"))
                   #:environment-variables
                   (list (string-append "STRONGSWAN_CONF=" #$daemon-config))
                   #:log-file "/dev/null"))
         (stop #~(make-kill-destructor)))
        (map
         (lambda (name file)
           (shepherd-service
            (provision (list (string->symbol (string-append "vpn-" name))))
            (requirement '(strongswan-charon sops-secrets))
            (auto-start? #f)
            (respawn? #f)
            (documentation (string-append "Manually connect VPN " name "."))
            (modules '((ice-9 textual-ports) (ice-9 popen) (srfi srfi-13)))
            (start
             #~(lambda _
                 (define (run . args)
                   (zero? (apply system* #$swanctl
                                 (append args (list "--uri" #$uri)))))
                 (when (string-contains (call-with-input-file #$file get-string-all)
                                        "REPLACE_WITH_PASSWORD")
                   (error "Set the VPN password with SOPS before starting" #$name))
                 ;; Charon's process can exist before its VICI socket is ready.
                 (let wait ((remaining 50))
                   (unless (file-exists? "/run/strongswan-charon.vici")
                     (if (zero? remaining)
                         (error "Timed out waiting for charon")
                         (begin (usleep 100000) (wait (- remaining 1))))))
                 ;; Always load the aggregate: --load-conns removes definitions
                 ;; absent from its input. Never clear another VPN's credentials.
                 (and (run "--load-creds" "--noprompt" "--file" #$config)
                      (run "--load-authorities" "--file" #$config)
                      (run "--load-conns" "--file" #$config)
                      (or (run "--initiate" "--child" #$name "--timeout" "30")
                          (begin
                            (run "--terminate" "--ike" #$name "--timeout" "10")
                            #f)))))
            (stop
             #~(lambda _
                 (if (zero? (system* #$swanctl "--terminate" "--ike" #$name
                                    "--timeout" "10" "--uri" #$uri))
                     #f
                     ;; A peer may already have disconnected. Only mark stopped
                     ;; if a successful query confirms no matching IKE SA.
                     (let* ((port (open-pipe* OPEN_READ #$swanctl "--list-sas"
                                              "--ike" #$name
                                              "--uri" #$uri))
                            (output (get-string-all port))
                            (status (close-pipe port)))
                       (not (and (zero? status)
                                 (string-null? (string-trim-both output))))))))))
         names files))))))
