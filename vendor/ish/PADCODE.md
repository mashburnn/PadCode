# iSH (arm64 guest) in PadCode

The kernel behind PadCode's "This iPad" machine: an Alpine Linux guest running
inside the app. PadCode talks to it in-process (`core/src/local.rs`): files
through the kernel's file calls, processes on host pipes, no SSH or network.
Built by `../../build-linux.sh`, with the entry points in `../ish-shim/`
(`padlinux.h`).

- Source: https://github.com/OpenMinis/ish-arm64 (a fork of ish-app/ish with
  an aarch64 guest), commit `c5c264d` (2026-10-15).
- License: GPLv3 (and GPLv2 for later contributions, see LICENSE.md). PadCode
  linked with it may only be distributed as GPL. The repo is private.

## Removed from the fork

`app/` (the iSH app: terminal UI, File Provider, roots, settings),
`iSH.xcodeproj`, `fastlane/`, `benchmark/`, `bench-legacy/`, `docs/`,
`kernel/offload_tests/` (17 MB of dev-only test handlers; their meson options
stay off), `linux/` (the `-Dkernel=linux` mode), the `deps/` submodules
(libapps, libarchive, linux, aports), `tests/` except `tests/e2e/e2e.bash`
(meson looks it up), the translated READMEs, `.github`, `.gitmodules`.

PadCode's boot code is modeled on the removed `app/AppDelegate.m` (`-boot`,
`configureDns`, the memory governor) and `app/ISHShellExecutor.m` (headless
processes); see the fork at the commit above.

## Patches (each marked `PadCode` in the source)

1. `meson_options.txt`, `vdso/arm64/meson.build`: option `vdso_cc`, a compiler
   for the vdso (an aarch64 Linux ELF). build-linux.sh passes a `zig cc`
   wrapper (zig bundles clang + lld), so no Homebrew LLVM is needed.
2. `meson_options.txt`, `tools/meson.build`: option `libarchive_include`, so
   `fakefsify` builds against macOS's own libarchive with headers fetched by
   build-linux.sh (the SDK ships the library without headers).
3. `fs/sock.h`, `fs/sock.c`: **SCM_RIGHTS for the arm64 guest.** The guest
   `struct cmsghdr_` had the i386 layout (12 bytes). aarch64 musl's is 16
   (`len`, padding, `level`, `type`) and 8-aligned, so sendmsg read the padding
   as the level, skipped every SCM_RIGHTS message, and no fd was ever passed.
   sshd's privilege-separated pty handoff (`mm_pty_allocate: receive fds
   failed`) killed every connection that asked for a tty. recvmsg also now
   installs only as many fds as fit the guest's control buffer (the rest are
   closed, `MSG_CTRUNC`) and reports the guest-layout length.
4. `fs/sockrestart.c`: on resume, a restored listening socket is `listen()`ed
   again (it was only re-bound, so a server that polls before `accept`, like
   sshd, never saw another connection), keeps its file flags, and doesn't leak
   the new fd.
5. `kernel/mmap.c`: a stale memory feed waits up to 1 s for the host's 250 ms
   timer before failing closed. After iOS resumes a suspended app the feed is
   only stale because nothing ran, and the first guest allocations failed.

## Building and linking

`build-linux.sh` makes `ios/Generated/LinuxKernel.xcframework` (module
`PadLinux`; libish + libish_emu + libfakefs + the shim, for iphoneos and
iphonesimulator, arm64, iOS 17) with `-Dguest_arch=arm64 -Djit=false
-Dbuildtype=release -Dlog_handler=nslog`, and `ios/Generated/linux-root`
(Alpine 3.21.8 minirootfs + `python3 ripgrep`, provisioned by
`../ish-shim/provision.sh`).

The app links it with `-lsqlite3 -lresolv` and Foundation (kernel messages go to
NSLog).

## Process-wide side effects of `padlinux_boot`

- SIGUSR1 gets a handler (the kernel interrupts guest threads with it) and
  SIGPIPE is ignored.
- SIGSEGV/SIGBUS get a handler that turns a host fault inside guest code into a
  guest fault (as the fork's CLI does); any other fault goes to the handler
  installed before, or crashes normally.
- A 250 ms timer and a memory-pressure source feed the kernel the app's
  footprint and jetsam allowance (`ish_set_memory_status`), so the guest is
  braked before iOS kills the app.
- Guest Unix sockets are host sockets under `$TMPDIR/ishsock*` on the iPad
  (`/tmp/ishsock*` in the Simulator).
- The kernel's `exit_hook` is set (`padlinux_spawn` reports exit codes with it).
- One kernel per process: it can't be shut down or booted twice.
