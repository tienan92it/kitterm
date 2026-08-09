/*
 * kitterm-spawn-helper — runs after posix_spawn(SETSID) with the PTY slave on
 * stdin/out/err. Acquires a controlling terminal (required for ISIG → SIGINT on
 * Ctrl+C / VINTR), then execs the login shell.
 *
 * Usage: kitterm-spawn-helper <cwd> <shellPath> <argv0> [args...]
 */
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifdef __APPLE__
#include <sys/ioctl.h>
#endif

int main(int argc, char **argv) {
  if (argc < 4) {
    return 127;
  }

  /* Become a session leader before claiming a terminal. macOS asks posix_spawn
   * for this with POSIX_SPAWN_SETSID, but glibc keeps that flag behind
   * __USE_GNU and Swift cannot see it, so doing it here works the same on both
   * and leaves one code path instead of two. EPERM only means we already are
   * one — which is the macOS case — and is not a failure.
   *
   * setsid, then open the slave, then TIOCSCTTY is what glibc's own login_tty
   * does, and what tmux and node-pty do. */
  (void)setsid();

  /* Attach controlling TTY: session has no ctty yet (SETSID); opening the slave
   * without O_NOCTTY makes it the controlling terminal.
   *
   * O_NONBLOCK because this open blocks forever if the master has already been
   * closed — which happens whenever a session is torn down in the moment
   * between spawning us and our reaching this line. We would then sleep here
   * for good, be reparented to init when the daemon exits, and leak a process
   * per occurrence. The flag only governs this open; the ioctl below is what
   * actually acquires the terminal, and the descriptor is closed immediately. */
  char *slave_path = ttyname(STDIN_FILENO);
  if (slave_path != NULL) {
    int fd = open(slave_path, O_RDWR | O_NONBLOCK);
    if (fd >= 0) {
      close(fd);
    }
  }

#ifdef __APPLE__
  /* Explicit acquire — matches login_tty / node-pty behavior on Darwin. */
  (void)ioctl(STDIN_FILENO, TIOCSCTTY, 0);
#endif

  char *cwd = argv[1];
  char *shell_path = argv[2];
  /* argv[3..] become the new argv (argv[3] is typically "-zsh"). */
  char **new_argv = &argv[3];

  if (cwd[0] != '\0' && chdir(cwd) != 0) {
    return 126;
  }

  execv(shell_path, new_argv);
  return 127;
}
