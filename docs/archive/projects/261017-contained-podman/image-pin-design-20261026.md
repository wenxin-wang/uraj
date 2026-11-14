# 运行时镜像的固定

The runtime image is pulled by the digest of quay.io/podman/stable:v5.8.7's
manifest list,
`sha256:2fb39ca923dd9e0ee33f9e319c3a107a2bfde022a6a31560cbd56a862821e7d3`, and
must match the verified image ID
`0e1abc5572ecd4dbc4574f60669bdbbafe804af7f6709b257cc93b8a797106ea` before it is
executed.  A tag would move: the host service's fresh store pulled a newer
:latest and failed this check.  A mismatch still fails closed; it does not
silently upgrade the runtime.
The underlying supervisor accepts explicit image/reference and expected-ID
arguments for a reviewed update.  The active API image is Podman 5.8.7; the
host client is the Guix Podman package.  This image pin is a compatibility pin,
not a signature/provenance verification system.
