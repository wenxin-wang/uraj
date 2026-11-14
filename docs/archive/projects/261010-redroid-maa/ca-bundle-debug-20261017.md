# 日常任务找不到 CA 证书包

The scheduled command sets `SSL_CERT_DIR` to the `nss-certs` store
directory and clears `SSL_CERT_FILE`. This package contains individual
certificates, not `etc/ssl/certs/ca-certificates.crt`. The 2026-10-17
21:00 scheduled run pointed at that nonexistent bundle and aborted with
`No CA certificates were loaded from the system`. Interactive validation
does not validate the scheduler's certificate environment; after deploying
the fix, check the dedicated account's scheduled invocation as well.
