/* Linux execution lifetime boundary for paseo-broker.  No setuid installation.
 * The launcher and all its preparation run beneath a trusted PID 1.
 *
 * broker -> supervisor (main parent branch) -> namespace PID 1 -> launcher
 * Each of the first two parent-child links uses PDEATHSIG plus a pidfd check.
 * PID 1 exits when the launcher finishes; the kernel then kills its
 * descendants. The outer supervisor waits for teardown and returns the
 * launcher's status. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <sched.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t stopping;
static void record_stop_signal(int sig) { stopping = sig; }
static void exit_with_error(const char* s) {
  perror(s);
  _exit(125);
}
static int64_t monotonic_milliseconds(void) {
  struct timespec t;
  if (clock_gettime(CLOCK_MONOTONIC, &t)) exit_with_error("clock_gettime");
  return (int64_t)t.tv_sec * 1000 + t.tv_nsec / 1000000;
}
static int open_process_handle(pid_t pid) {
  int fd = syscall(SYS_pidfd_open, pid, 0);
  if (fd < 0) exit_with_error("pidfd_open");
  return fd;
}
static void exit_when_parent_dies(int parent) {
  struct pollfd p = {.fd = parent, .events = POLLIN};
  if (prctl(PR_SET_PDEATHSIG, SIGKILL)) exit_with_error("PDEATHSIG");
  int n;
  do {
    n = poll(&p, 1, 0);
  } while (n < 0 && errno == EINTR);
  if (n < 0) exit_with_error("poll parent");
  if (n) _exit(125);
}
static void write_namespace_mapping(const char* path, const char* value) {
  int fd = open(path, O_WRONLY | O_CLOEXEC);
  if (fd < 0) exit_with_error(path);
  size_t len = strlen(value);
  if (write(fd, value, len) != (ssize_t)len) exit_with_error(path);
  close(fd);
}
static void install_signal_handlers(void) {
  sigset_t empty;
  sigemptyset(&empty);
  if (sigprocmask(SIG_SETMASK, &empty, NULL)) exit_with_error("sigprocmask");
  struct sigaction a = {.sa_handler = record_stop_signal};
  sigemptyset(&a.sa_mask);
  if (sigaction(SIGTERM, &a, NULL) || sigaction(SIGINT, &a, NULL) ||
      sigaction(SIGHUP, &a, NULL))
    exit_with_error("sigaction");
  signal(SIGCHLD, SIG_DFL);
}
static void exit_with_workload_status(int status) {
  if (WIFEXITED(status)) _exit(WEXITSTATUS(status));
  if (WIFSIGNALED(status)) {
    int sig = WTERMSIG(status);
    signal(sig, SIG_DFL);
    kill(getpid(), sig);
    _exit(128 + sig);
  }
  _exit(125);
}
static void run_namespace_init(char** command, int result) {
  if (unshare(CLONE_NEWNS)) exit_with_error("unshare mounts");
  if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL))
    exit_with_error("private mounts");
  if (mount("proc", "/proc", "proc", MS_NOSUID | MS_NODEV | MS_NOEXEC, NULL))
    exit_with_error("mount proc");
  install_signal_handlers();
  pid_t leader = fork();
  if (leader < 0) exit_with_error("fork workload");
  if (!leader) {
    close(result);
    signal(SIGTERM, SIG_DFL);
    signal(SIGINT, SIG_DFL);
    signal(SIGHUP, SIG_DFL);
    execvp(command[0], command);
    exit_with_error("exec workload");
  }
  int64_t deadline = 0;
  for (;;) {
    if (stopping && !deadline) {
      /* All signalable processes in this namespace, including setsid children.
       * SIGKILL teardown on init exit handles nested namespace init processes.
       */
      kill(-1, SIGTERM);
      deadline = monotonic_milliseconds() + 2000;
    }
    int status;
    pid_t done = waitpid(-1, &status, WNOHANG);
    if (done == leader) {
      if (send(result, &status, sizeof status, MSG_NOSIGNAL) != sizeof status)
        exit_with_error("send status");
      _exit(0); /* kernel kills/reaps the remaining namespace descendants */
    }
    if (done < 0 && errno != EINTR) exit_with_error("wait workload");
    if (deadline && monotonic_milliseconds() >= deadline) {
      status = SIGKILL; /* Linux wait status for an uncaught SIGKILL */
      (void)send(result, &status, sizeof status, MSG_NOSIGNAL);
      _exit(0);
    }
    struct timespec delay = {.tv_nsec = 10000000};
    nanosleep(&delay, NULL);
  }
}
int main(int argc, char** argv) {
  if (argc < 5 || strcmp(argv[1], "--owner-fd") || strcmp(argv[3], "--")) {
    fprintf(
        stderr,
        "usage: paseo-agent-supervisor --owner-fd FD -- PROGRAM [ARGS...]\n");
    return 125;
  }
  char* end;
  int64_t number = strtol(argv[2], &end, 10);
  if (*end || number < 3 || number > 1048576) return 125;
  int owner = (int)number;
  exit_when_parent_dies(owner);
  uid_t uid = getuid();
  gid_t gid = getgid();
  if (unshare(CLONE_NEWUSER)) exit_with_error("unshare user");
  char mapping[96];
  snprintf(mapping, sizeof mapping, "%u %u 1\n", uid, uid);
  write_namespace_mapping("/proc/self/uid_map", mapping);
  write_namespace_mapping("/proc/self/setgroups", "deny\n");
  snprintf(mapping, sizeof mapping, "%u %u 1\n", gid, gid);
  write_namespace_mapping("/proc/self/gid_map", mapping);
  exit_when_parent_dies(
      owner); /* Credential transitions must not silently disarm the link. */
  close(owner);
  if (unshare(CLONE_NEWPID)) exit_with_error("unshare pid");
  int myself = open_process_handle(getpid()), channel[2];
  if (socketpair(AF_UNIX, SOCK_SEQPACKET | SOCK_CLOEXEC, 0, channel))
    exit_with_error("socketpair");
  install_signal_handlers();
  pid_t child = fork();
  if (child < 0) exit_with_error("fork init");
  if (!child) {
    exit_when_parent_dies(myself);
    close(myself);
    close(channel[0]);
    char ready;
    if (recv(channel[1], &ready, 1, 0) != 1 || ready != 'R') _exit(125);
    run_namespace_init(argv + 4, channel[1]);
    _exit(125);
  }
  close(myself);
  close(channel[1]);
  /* Persist stable identity before releasing the launch gate.  On broker
   * restart this lets admission wait for old namespace teardown, not just
   * the old broker's death. TMPDIR is broker-controlled, outside the sandbox.
   */
  char path[4096], stat_path[96], identity[4096];
  const char* temporary = getenv("TMPDIR");
  if (!temporary || snprintf(path, sizeof path, "%s/namespace.stat",
                             temporary) >= (int)sizeof path) {
    kill(child, SIGKILL);
    _exit(125);
  }
  snprintf(stat_path, sizeof stat_path, "/proc/%d/stat", child);
  int source = open(stat_path, O_RDONLY | O_CLOEXEC);
  if (source < 0) exit_with_error("open namespace identity");
  ssize_t count = read(source, identity, sizeof identity);
  close(source);
  int target = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
  if (target < 0 || count <= 0 || write(target, identity, count) != count)
    exit_with_error("record namespace identity");
  close(target);
  if (send(channel[0], "R", 1, MSG_NOSIGNAL) != 1)
    exit_with_error("release init");
  int status;
  for (;;) {
    if (stopping) {
      kill(child, stopping);
      stopping = 0;
    }
    pid_t done = waitpid(child, &status, 0);
    if (done == child) break;
    if (done < 0 && errno != EINTR) exit_with_error("wait init");
  }
  /* waitpid completes only after namespace teardown, before returning a result.
   */
  int leader_status;
  if (WIFEXITED(status) && WEXITSTATUS(status) == 0 &&
      recv(channel[0], &leader_status, sizeof leader_status, 0) ==
          sizeof leader_status)
    status = leader_status;
  close(channel[0]);
  exit_with_workload_status(status);
}
