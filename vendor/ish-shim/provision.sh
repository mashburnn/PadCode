# Run inside the Alpine guest by build-linux.sh (as root) after the apk add.
set -e

# No services or gettys: busybox init only reaps orphaned processes.
cat > /etc/inittab <<'X'
# PadCode: no services or gettys; init just reaps orphaned processes.
::sysinit:/bin/mkdir -p /run /tmp
X
: > /etc/motd
