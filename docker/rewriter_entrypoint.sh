#!/bin/sh

# Default value for REWRITE_LOG is off, unless explicitly set to 'on'
if [ "$REWRITE_LOG" = "on" ]; then
    REWRITE_LOG="rewrite_log on;"
else
    REWRITE_LOG="# rewrite_log off;"
fi

# DNS server nginx resolves the upstream with at request time; defaults to the
# container's own nameserver (Docker's embedded DNS on compose networks)
if [ -z "$RESOLVER" ]; then
    RESOLVER=$(awk '$1 == "nameserver" { print $2; exit }' /etc/resolv.conf)
    case "$RESOLVER" in
        *:*) RESOLVER="[$RESOLVER]" ;;
    esac
fi
RESOLVER="${RESOLVER:-127.0.0.11}"

# Use sed to replace the placeholders in the nginx template file
sed -e "s|\${REWRITE_LOG}|$REWRITE_LOG|g" -e "s|\${RESOLVER}|$RESOLVER|g" /usr/local/openresty/nginx/conf/nginx.conf.template > /usr/local/openresty/nginx/conf/nginx.conf

# Start nginx
exec /usr/local/openresty/bin/openresty -g 'daemon off;'
