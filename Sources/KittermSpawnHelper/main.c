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

  /* Attach controlling TTY: session has no ctty yet (SETSID); opening the slave
   * without O_NOCTTY makes it the controlling terminal. */
  char *slave_path = ttyname(STDIN_FILENO);
  if (slave_path != NULL) {
    int fd = open(slave_path, O_RDWR);
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
