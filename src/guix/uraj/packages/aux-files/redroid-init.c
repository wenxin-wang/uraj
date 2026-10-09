/* SPDX-License-Identifier: GPL-3.0-or-later
   Protect the host's module-loader setting before Android init starts.
   Run inside the container's mount namespace, with CAP_SYS_ADMIN. */
#include <stdio.h>
#include <stdlib.h>
#include <sys/mount.h>
#include <unistd.h>

int main(int argc, char** argv) {
  const char* path = "/proc/sys/kernel/modprobe";
  (void)argc;
  if (mount(path, path, NULL, MS_BIND, NULL) != 0) {
    perror("redroid-init: bind modprobe");
    return EXIT_FAILURE;
  }
  /* Keep procfs safety flags: dropping them is forbidden in a user
     namespace and unnecessary even in the rootful container. */
  if (mount(NULL, path, NULL,
            MS_BIND | MS_REMOUNT | MS_RDONLY | MS_NOSUID | MS_NODEV |
                MS_NOEXEC | MS_RELATIME,
            NULL) != 0) {
    perror("redroid-init: make modprobe read-only");
    return EXIT_FAILURE;
  }
  argv[0] = "/init";
  execv(argv[0], argv);
  perror("redroid-init: exec Android init");
  return EXIT_FAILURE;
}
