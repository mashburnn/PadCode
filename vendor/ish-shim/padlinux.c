// PadCode's entry points into iSH (see padlinux.h). Modeled on the fork's
// app/AppDelegate.m -boot and app/ISHShellExecutor.m (not vendored; see
// vendor/ish/PADCODE.md), without the terminal UI, clipboard, location or
// iOS-folder mounts.
#include <TargetConditionals.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <netdb.h>
#include <os/proc.h>
#include <pthread.h>
#include <resolv.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dispatch/dispatch.h>
#include <sys/stat.h>

#include "kernel/init.h"
#include "kernel/calls.h"
#include "kernel/fs.h"
#include "kernel/mm.h"
#include "kernel/task.h"
#include "fs/dev.h"
#include "fs/devices.h"
#include "fs/fd.h"
#include "fs/path.h"
#include "fs/real.h"
#include "fs/sock.h"
#include "fs/sockrestart.h"
#include "cpu-offsets.h"
#include "padlinux.h"

static const char env[] =
    "TERM=xterm-256color\0"
    "HOME=/root\0"
    "USER=root\0"
    "LOGNAME=root\0"
    "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0"
    "PYTHONMALLOC=malloc\0"; // the fork's default for its arm64 guest

static char console_log[1024];
static int boot_result = -1;
static pthread_once_t boot_once = PTHREAD_ONCE_INIT;
static const char *boot_root;
static atomic_bool suspended;
static struct task *init_task;

// MARK: Memory governor (from the fork's AppDelegate.m)

// Feeds the kernel the app's footprint and remaining jetsam allowance, so the
// guest is braked before iOS kills the whole app.
static void governor_tick(bool critical) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    uint64_t footprint = 0;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t) &info, &count) == KERN_SUCCESS)
        footprint = info.phys_footprint;
    uint64_t avail = (uint64_t) os_proc_available_memory();
    if (footprint == 0 || avail == 0)
        return; // the kernel treats a stale feed as "brake"
    ish_set_memory_status(footprint + avail, avail, critical);
}

static void governor_start(void) {
    size_t avail = os_proc_available_memory();
    if (avail > 0)
        ish_set_anon_page_limit((long) ((double) avail * 0.8 / (double) getpagesize()));
    dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    static dispatch_source_t timer, pressure;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC, 50 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{ governor_tick(false); });
    dispatch_resume(timer);
    pressure = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
                                      DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL, q);
    dispatch_source_set_event_handler(pressure, ^{
        governor_tick((dispatch_source_get_data(pressure) & DISPATCH_MEMORYPRESSURE_CRITICAL) != 0);
    });
    dispatch_resume(pressure);
    governor_tick(false);
}

// MARK: Fault recovery (from the fork's main.c)

// The gadget engine marks guest code with `in_jit` and, like the fork's CLI
// (where this setup passed PadCode's SSH tests), turns a host fault there into
// a guest fault. Any other fault goes to the handler that was installed before
// (crash reporting), or the default.
extern __thread volatile sig_atomic_t in_jit;
extern __thread volatile addr_t jit_saved_pc;
extern void jit_crash_trampoline(void);
static struct sigaction previous_segv, previous_bus;

static void fault_handler(int sig, siginfo_t *info, void *ctx) {
    if (in_jit) {
        ucontext_t *uc = ctx;
        uint64_t cpu = uc->uc_mcontext->__ss.__x[1];
        uint64_t guest = (uc->uc_mcontext->__ss.__x[7] - uc->uc_mcontext->__ss.__x[10]) & 0xffffffffffffULL;
        *(addr_t *) (cpu + CPU_segfault_addr) = guest;
        *(bool *) (cpu + CPU_segfault_was_write) = (uc->uc_mcontext->__es.__esr & 0x40) != 0;
        *(uint64_t *) (cpu + CPU_pc) = jit_saved_pc;
        uc->uc_mcontext->__ss.__sp = *(uint64_t *) (cpu + LOCAL_jit_exit_sp);
        uc->uc_mcontext->__ss.__pc = (uint64_t) jit_crash_trampoline;
        sigset_t unblock;
        sigemptyset(&unblock);
        sigaddset(&unblock, sig);
        sigprocmask(SIG_UNBLOCK, &unblock, NULL);
        return;
    }
    struct sigaction *prev = sig == SIGSEGV ? &previous_segv : &previous_bus;
    if (prev->sa_flags & SA_SIGINFO && prev->sa_sigaction != NULL) {
        prev->sa_sigaction(sig, info, ctx);
    } else if (prev->sa_handler != SIG_DFL && prev->sa_handler != SIG_IGN) {
        prev->sa_handler(sig);
    } else {
        sigaction(sig, prev, NULL); // returning re-runs the faulting instruction: a normal crash
    }
}

static void install_fault_handler(void) {
    struct sigaction sa = {0};
    sa.sa_sigaction = fault_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, &previous_segv);
    sigaction(SIGBUS, &sa, &previous_bus);
}

// MARK: Boot

// MARK: Exit codes

// Where each spawned process's wait status goes (see padlinux_spawn).
// ponytail: a fixed table; 256 of PadCode's processes at once is plenty.
static pthread_mutex_t exits_lock = PTHREAD_MUTEX_INITIALIZER;
static struct { int pid, fd; } exits[256];

// The kernel's exit_hook: a whole process (thread group) ended. Runs on the
// exiting guest thread with pids_lock held, so it only writes to a pipe.
static void report_exit(struct task *task, int status) {
    pthread_mutex_lock(&exits_lock);
    for (size_t i = 0; i < sizeof(exits) / sizeof(exits[0]); i++) {
        if (exits[i].fd > 0 && exits[i].pid == task->tgid) {
            (void) write(exits[i].fd, &status, sizeof(status));
            close(exits[i].fd);
            exits[i].fd = 0;
            break;
        }
    }
    pthread_mutex_unlock(&exits_lock);
}

// A guest fd for a host file descriptor (the guest reads and writes it directly).
static struct fd *host_fd(int real) {
    struct fd *fd = adhoc_fd_create(&realfs_fdops);
    if (fd != NULL)
        fd->real_fd = real;
    return fd;
}

static void give_stdio(struct task *task) {
    task->files->files[0] = host_fd(open("/dev/null", O_RDONLY));
    int out = open(console_log, O_WRONLY | O_CREAT | O_APPEND, 0600);
    task->files->files[1] = host_fd(out);
    task->files->files[2] = host_fd(dup(out));
}

static void write_guest_file(const char *path, const char *text) {
    struct fd *fd = generic_open(path, O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0644);
    if (IS_ERR(fd))
        return;
    fd->ops->write(fd, text, strlen(text));
    fd_close(fd);
}

// /etc/resolv.conf from the iPad's DNS settings.
static void configure_dns(void) {
    struct __res_state res;
    if (res_ninit(&res) != 0)
        return;
    char conf[2048] = "";
    size_t n = 0;
    if (res.dnsrch[0] != NULL) {
        n += snprintf(conf + n, sizeof(conf) - n, "search");
        for (int i = 0; res.dnsrch[i] != NULL && n < sizeof(conf); i++)
            n += snprintf(conf + n, sizeof(conf) - n, " %s", res.dnsrch[i]);
        n += snprintf(conf + n, sizeof(conf) - n, "\n");
    }
    union res_sockaddr_union servers[8];
    int found = res_getservers(&res, servers, 8);
    for (int i = 0; i < found && n < sizeof(conf); i++) {
        char addr[NI_MAXHOST];
        if (servers[i].sin.sin_len == 0 ||
            getnameinfo((struct sockaddr *) &servers[i].sin, servers[i].sin.sin_len, addr, sizeof(addr), NULL, 0, NI_NUMERICHOST) != 0)
            continue;
        n += snprintf(conf + n, sizeof(conf) - n, "nameserver %s\n", addr);
    }
    res_ndestroy(&res);
    if (found > 0)
        write_guest_file("/etc/resolv.conf", conf);
}

static void make_device_nodes(void) {
    struct { const char *path; int major, minor; } nodes[] = {
        {"/dev/null", MEM_MAJOR, DEV_NULL_MINOR},
        {"/dev/zero", MEM_MAJOR, DEV_ZERO_MINOR},
        {"/dev/full", MEM_MAJOR, DEV_FULL_MINOR},
        {"/dev/random", MEM_MAJOR, DEV_RANDOM_MINOR},
        {"/dev/urandom", MEM_MAJOR, DEV_URANDOM_MINOR},
        {"/dev/tty", TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR},
        {"/dev/console", TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR},
        {"/dev/ptmx", TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR},
    };
    for (size_t i = 0; i < sizeof(nodes) / sizeof(nodes[0]); i++) // no-ops once they exist
        generic_mknodat(AT_PWD, nodes[i].path, S_IFCHR | 0666, dev_make(nodes[i].major, nodes[i].minor));
    generic_mkdirat(AT_PWD, "/dev/pts", 0755);
}

static void boot(void) {
    char data[1024];
    if (snprintf(data, sizeof(data), "%s/data", boot_root) >= (int) sizeof(data) ||
        snprintf(console_log, sizeof(console_log), "%s/console.log", boot_root) >= (int) sizeof(console_log)) {
        boot_result = _ENAMETOOLONG;
        return;
    }
    struct stat st;
    if (stat(console_log, &st) == 0 && st.st_size > (1 << 20))
        truncate(console_log, 0);

    install_fault_handler();
    governor_start();
#if !TARGET_OS_SIMULATOR
    // Guest Unix sockets are host ones; on the iPad they must live in the app's
    // tmp (the Simulator can use the Mac's /tmp, and its tmp path is too long).
    static char sock_prefix[256];
    const char *tmp = getenv("TMPDIR");
    if (tmp != NULL && snprintf(sock_prefix, sizeof(sock_prefix), "%sishsock", tmp) < (int) sizeof(sock_prefix))
        sock_tmp_prefix = sock_prefix;
#endif

    int err = mount_root(&fakefs, data);
    if (err < 0) {
        boot_result = err;
        return;
    }
    err = become_first_process();
    if (err < 0) {
        boot_result = err;
        return;
    }
    make_device_nodes();
    do_mount(&procfs, "proc", "/proc", "", 0);
    do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);
    configure_dns();

    // init: busybox, with PadCode's /etc/inittab (no services; it reaps orphans).
    give_stdio(current);
    err = do_execve("/sbin/init", 1, "/sbin/init\0", env);
    if (err < 0) {
        boot_result = err;
        return;
    }
    exit_hook = report_exit;
    init_task = current;
    current = NULL;
    task_start(init_task);
    boot_result = 0;
}

int padlinux_boot(const char *root) {
    if (boot_root == NULL)
        boot_root = strdup(root);
    pthread_once(&boot_once, boot);
    return boot_result;
}

// MARK: Processes

static pthread_mutex_t spawn_lock = PTHREAD_MUTEX_INITIALIZER; // task creation isn't thread-safe

int padlinux_spawn(const char *sh_command, int in_fd, int out_fd, int err_fd, int exit_fd) {
    int fds[] = {in_fd, out_fd, err_fd, exit_fd};
    lock(&pids_lock);
    bool alive = boot_result == 0 && pid_get_task(1) != NULL;
    unlock(&pids_lock);
    size_t slot = SIZE_MAX;
    pthread_mutex_lock(&exits_lock);
    for (size_t i = 0; alive && i < sizeof(exits) / sizeof(exits[0]) && slot == SIZE_MAX; i++) {
        if (exits[i].fd <= 0) {
            slot = i;
            exits[i].pid = 0; // claimed; no process has pid 0
            exits[i].fd = exit_fd;
        }
    }
    pthread_mutex_unlock(&exits_lock);
    size_t len = strlen(sh_command);
    char *argv = slot == SIZE_MAX ? NULL : malloc(len + 16);
    if (argv == NULL) {
        if (slot != SIZE_MAX)
            exits[slot].fd = 0;
        for (int i = 0; i < 4; i++)
            close(fds[i]);
        return !alive ? -1 : slot == SIZE_MAX ? _EAGAIN : _ENOMEM;
    }
    memcpy(argv, "/bin/sh\0-c\0", 11);
    memcpy(argv + 11, sh_command, len + 1);
    argv[11 + len + 1] = '\0';

    pthread_mutex_lock(&spawn_lock);
    int err = become_new_init_child();
    struct task *task = err < 0 ? NULL : current;
    if (task != NULL) {
        task->files->files[0] = host_fd(in_fd);
        task->files->files[1] = host_fd(out_fd);
        task->files->files[2] = host_fd(err_fd);
        err = do_execve("/bin/sh", 3, argv, env);
    }
    current = NULL;
    free(argv);
    if (err < 0) {
        // ponytail: a task whose exec failed (no /bin/sh) is left behind, as in the fork.
        pthread_mutex_unlock(&spawn_lock);
        pthread_mutex_lock(&exits_lock);
        exits[slot].fd = 0;
        pthread_mutex_unlock(&exits_lock);
        if (task == NULL)
            close(in_fd), close(out_fd), close(err_fd);
        close(exit_fd);
        return err;
    }
    int pid = task->pid;
    pthread_mutex_lock(&exits_lock);
    exits[slot].pid = pid;
    pthread_mutex_unlock(&exits_lock);
    task_start(task);
    pthread_mutex_unlock(&spawn_lock);
    return pid;
}

// MARK: Files

// Kernel file calls need a task for root, cwd and permissions: they run as
// init (root, in /), one at a time.
static pthread_mutex_t files_lock = PTHREAD_MUTEX_INITIALIZER;

static bool enter(void) {
    if (boot_result != 0)
        return false;
    pthread_mutex_lock(&files_lock);
    current = init_task;
    return true;
}

static void leave(void) {
    current = NULL;
    pthread_mutex_unlock(&files_lock);
}

int padlinux_stat(const char *path, int follow, unsigned *mode, unsigned long long *size) {
    if (!enter())
        return _ENODEV;
    struct statbuf st;
    int err = generic_statat(AT_PWD, path, &st, follow);
    leave();
    if (err == 0) {
        *mode = st.mode;
        *size = st.size;
    }
    return err;
}

int padlinux_list(const char *dir, void (*each)(void *ctx, const char *name, unsigned mode), void *ctx) {
    if (!enter())
        return _ENODEV;
    struct fd *fd = generic_open(dir, O_RDONLY_ | O_DIRECTORY_, 0);
    if (IS_ERR(fd)) {
        leave();
        return PTR_ERR(fd);
    }
    int err = fd->ops->readdir == NULL ? _ENOTDIR : 0;
    struct dir_entry entry;
    while (err == 0 && (err = fd->ops->readdir(fd, &entry)) > 0) {
        err = 0;
        if (strcmp(entry.name, ".") == 0 || strcmp(entry.name, "..") == 0)
            continue;
        struct statbuf st = {0};
        generic_statat(fd, entry.name, &st, false); // mode 0 if it just vanished
        each(ctx, entry.name, st.mode);
    }
    fd_close(fd);
    leave();
    return err;
}

void *padlinux_open(const char *path, int write, int *err) {
    if (!enter()) {
        *err = _ENODEV;
        return NULL;
    }
    struct fd *fd = generic_open(path, write ? O_WRONLY_ | O_CREAT_ | O_TRUNC_ : O_RDONLY_, 0644);
    // Regular files only: reading a fifo or a device could block every file call.
    if (!IS_ERR(fd) && !S_ISREG(fd->type)) {
        int type = fd->type;
        fd_close(fd);
        fd = (struct fd *) (intptr_t) (S_ISDIR(type) ? _EISDIR : _EINVAL);
    }
    leave();
    if (IS_ERR(fd)) {
        *err = PTR_ERR(fd);
        return NULL;
    }
    return fd;
}

long padlinux_read(void *file, void *buf, unsigned long n) {
    if (!enter())
        return _ENODEV;
    struct fd *fd = file;
    long r = fd->ops->read == NULL ? _EINVAL : fd->ops->read(fd, buf, n);
    leave();
    return r;
}

long padlinux_write(void *file, const void *buf, unsigned long n) {
    if (!enter())
        return _ENODEV;
    struct fd *fd = file;
    long r = fd->ops->write == NULL ? _EINVAL : fd->ops->write(fd, buf, n);
    leave();
    return r;
}

void padlinux_close(void *file) {
    if (!enter())
        return;
    fd_close(file);
    leave();
}

void padlinux_suspend(void) {
    if (boot_result == 0 && !atomic_exchange(&suspended, true))
        sockrestart_on_suspend();
}

void padlinux_resume(void) {
    if (boot_result == 0 && atomic_exchange(&suspended, false))
        sockrestart_on_resume();
}
