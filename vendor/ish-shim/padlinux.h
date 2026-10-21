// PadCode's entry points into the iSH kernel (vendor/ish): an Alpine Linux
// guest running inside the app. Only one guest per process; it can't be shut
// down, only suspended along with the app.
#ifndef PADLINUX_H
#define PADLINUX_H

#ifdef __cplusplus
extern "C" {
#endif

/// Boots the guest from `root`, the directory holding meta.db and data/ (a
/// fakefs root). Starts /sbin/init (busybox, which only reaps orphans) and
/// writes /etc/resolv.conf from the iPad's DNS servers. Kernel messages go to
/// `root`/console.log.
/// Returns 0, or a negative Linux errno. Only the first call boots; later calls
/// return the first call's result.
int padlinux_boot(const char *root);

/// Starts `/bin/sh -c sh_command` as root. The host file descriptors in_fd,
/// out_fd and err_fd become its stdin, stdout and stderr (the guest takes them
/// over). When the process ends, its wait status (an int, as waitpid reports
/// it) is written to exit_fd, which is then closed. Returns the guest pid, or
/// a negative Linux errno (-1 when the guest isn't booted or init has died);
/// on failure exit_fd is closed.
int padlinux_spawn(const char *sh_command, int in_fd, int out_fd, int err_fd, int exit_fd);

/// Files, as root, straight through the guest's kernel: no guest process.
/// Paths are guest paths. Results are 0 (or a count) or a negative Linux errno.
int padlinux_stat(const char *path, int follow, unsigned *mode, unsigned long long *size);
/// Calls `each` for every entry but . and .., with its lstat mode (0 if it
/// vanished meanwhile).
int padlinux_list(const char *dir, void (*each)(void *ctx, const char *name, unsigned mode), void *ctx);
/// Regular files only. `write` creates or truncates. NULL with *err set on failure.
void *padlinux_open(const char *path, int write, int *err);
long padlinux_read(void *file, void *buf, unsigned long n);
long padlinux_write(void *file, const void *buf, unsigned long n);
void padlinux_close(void *file);

/// Call when the app goes to the background / comes back: iOS frees a
/// suspended app's listening sockets, and these let the guest's listeners
/// (a dev server you started) be recreated on resume.
void padlinux_suspend(void);
void padlinux_resume(void);

#ifdef __cplusplus
}
#endif

#endif
