#!/bin/sh
set -e

# Fix ownership of bind-mounted directories that may be root:root from the host.
# This runs as root; actual commands run as haf_admin via su-exec.
if [ "$(id -u)" = "0" ]; then
  if [ -d /hivesense/config ]; then
    chown -R haf_admin:users /hivesense/config
  fi
  exec su-exec haf_admin "$0" "$@"
fi

cd /app/scripts

if [ "$1" = "install_app" ]; then
  shift
  exec /app/scripts/install_app.sh --host="${POSTGRES_HOST:-haf}" "$@"
elif [ "$1" = "process_blocks" ]; then
  shift
  exec /app/scripts/process_blocks.sh --host="${POSTGRES_HOST:-haf}" "$@"
elif [ "$1" = "uninstall_app" ]; then
  shift
  exec /app/scripts/uninstall_app.sh --host="${POSTGRES_HOST:-haf}" --user="${POSTGRES_USER:-haf_admin}" "$@"
else
  echo "usage: $0 install_app|process_blocks|uninstall_app"
  exit 1
fi
