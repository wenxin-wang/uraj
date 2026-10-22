/* SPDX-License-Identifier: GPL-3.0-or-later
   Protect the host's module-loader setting before Android init starts.
   Run inside the container's mount namespace, with CAP_SYS_ADMIN. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <unistd.h>

#define MODPROBE "/proc/sys/kernel/modprobe"
#define INIT_RC "/system/etc/init/hw/init.rc"
/* First-stage init mounts its own tmpfs here; the bind below keeps the copy
   reachable after that. */
#define COPY_DIR "/mnt"
#define INIT_RC_COPY COPY_DIR "/redroid-init.rc"

static int remount_read_only(const char* path) {
  /* Keep procfs and tmpfs safety flags: dropping them is forbidden in a user
     namespace and unnecessary even in the rootful container. */
  return mount(NULL, path, NULL,
               MS_BIND | MS_REMOUNT | MS_RDONLY | MS_NOSUID | MS_NODEV |
                   MS_NOEXEC | MS_RELATIME,
               NULL);
}

/* Whether LINE is init.rc's "write /proc/sys/kernel/modprobe ...". */
static int writes_modprobe(const char* line) {
  line += strspn(line, " \t");
  if (strncmp(line, "write", 5) != 0 || !strchr(" \t", line[5])) return 0;
  line += 5;
  line += strspn(line, " \t");
  return strncmp(line, MODPROBE, strlen(MODPROBE)) == 0 &&
         strchr(" \t", line[strlen(MODPROBE)]) != NULL;
}

/* First-stage init mounts a fresh procfs over /proc, hiding the read-only
   bind, before init.rc empties the global modprobe sysctl and with it host
   module autoloading.  Bind a copy of init.rc without that command. */
static int drop_modprobe_write(void) {
  FILE* in;
  FILE* out;
  char* line = NULL;
  size_t size = 0;
  int dropped = 0;
  int failed;

  if (mount("tmpfs", COPY_DIR, "tmpfs", MS_NOSUID | MS_NODEV | MS_NOEXEC,
            "mode=0755,size=1m") != 0) {
    perror("redroid-init: mount " COPY_DIR);
    return -1;
  }
  in = fopen(INIT_RC, "r");
  if (in == NULL) {
    perror("redroid-init: open " INIT_RC);
    return -1;
  }
  out = fopen(INIT_RC_COPY, "w");
  if (out == NULL) {
    perror("redroid-init: create " INIT_RC_COPY);
    fclose(in);
    return -1;
  }
  while (getline(&line, &size, in) != -1) {
    if (writes_modprobe(line)) {
      dropped++;
    } else if (fputs(line, out) == EOF) {
      break;
    }
  }
  failed = ferror(in) || ferror(out);
  free(line);
  fclose(in);
  if (fclose(out) != 0 || failed) {
    fputs("redroid-init: cannot copy " INIT_RC "\n", stderr);
    return -1;
  }
  /* Fail closed: an image that moved the command must be reviewed. */
  if (dropped == 0) {
    fputs("redroid-init: no modprobe write in " INIT_RC "\n", stderr);
    return -1;
  }
  if (mount(INIT_RC_COPY, INIT_RC, NULL, MS_BIND, NULL) != 0 ||
      remount_read_only(INIT_RC) != 0) {
    perror("redroid-init: bind " INIT_RC);
    return -1;
  }
  return 0;
}

int main(int argc, char** argv) {
  (void)argc;
  if (mount(MODPROBE, MODPROBE, NULL, MS_BIND, NULL) != 0) {
    perror("redroid-init: bind modprobe");
    return EXIT_FAILURE;
  }
  if (remount_read_only(MODPROBE) != 0) {
    perror("redroid-init: make modprobe read-only");
    return EXIT_FAILURE;
  }
  if (drop_modprobe_write() != 0) return EXIT_FAILURE;
  argv[0] = "/init";
  execv(argv[0], argv);
  perror("redroid-init: exec Android init");
  return EXIT_FAILURE;
}
