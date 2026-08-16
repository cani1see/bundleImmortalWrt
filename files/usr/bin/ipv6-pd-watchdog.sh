#!/bin/sh

PATH=/usr/sbin:/usr/bin:/sbin:/bin

INTERFACE="wan_6"
FAIL_THRESHOLD=3
COOLDOWN_SECONDS=600
RENEW_WAIT_SECONDS=15
RESTART_WAIT_SECONDS=15
STATE_DIR="/tmp/ipv6-pd-watchdog"
LOCK_DIR="/tmp/ipv6-pd-watchdog.lock"
TAG="ipv6-pd-watchdog"

get_prefix() {
    ubus call "network.interface.${INTERFACE}" status 2>/dev/null \
        | jsonfilter -e '@["ipv6-prefix"][0].address' 2>/dev/null
}

read_number() {
    value="$(cat "$1" 2>/dev/null)"
    case "$value" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$value" ;;
    esac
}

record_recovery() {
    recovered_prefix="$1"
    printf '%s\n' "$recovered_prefix" > "$STATE_DIR/prefix"
    printf '0\n' > "$STATE_DIR/failures"
}

mkdir "$LOCK_DIR" 2>/dev/null || exit 0
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM
mkdir -p "$STATE_DIR"

prefix="$(get_prefix)"
if [ -n "$prefix" ]; then
    previous="$(cat "$STATE_DIR/prefix" 2>/dev/null)"
    if [ "$prefix" != "$previous" ]; then
        logger -t "$TAG" "PD available: ${prefix} (previous: ${previous:-none})"
    fi
    record_recovery "$prefix"
    exit 0
fi

failures="$(read_number "$STATE_DIR/failures")"
failures=$((failures + 1))
printf '%s\n' "$failures" > "$STATE_DIR/failures"

if [ "$failures" -lt "$FAIL_THRESHOLD" ]; then
    if [ "$failures" -eq 1 ]; then
        logger -t "$TAG" "PD missing; waiting for ${FAIL_THRESHOLD} consecutive checks"
    fi
    exit 0
fi

now="$(date +%s)"
last_action="$(read_number "$STATE_DIR/last-action")"
elapsed=$((now - last_action))
if [ "$last_action" -gt 0 ] && [ "$elapsed" -lt "$COOLDOWN_SECONDS" ]; then
    exit 0
fi

printf '%s\n' "$now" > "$STATE_DIR/last-action"
logger -t "$TAG" "PD missing for ${failures} checks; renewing ${INTERFACE}"

if ubus call "network.interface.${INTERFACE}" renew '{}' >/dev/null 2>&1; then
    sleep "$RENEW_WAIT_SECONDS"
    prefix="$(get_prefix)"
    if [ -n "$prefix" ]; then
        record_recovery "$prefix"
        logger -t "$TAG" "PD recovered after renew: ${prefix}"
        exit 0
    fi
fi

# Only restart the dynamic DHCPv6 child. Never touch the parent PPPoE WAN.
logger -t "$TAG" "PD still missing; restarting dynamic interface ${INTERFACE}"
if ubus call "network.interface.${INTERFACE}" down '{}' >/dev/null 2>&1; then
    sleep 3
    ubus call "network.interface.${INTERFACE}" up '{}' >/dev/null 2>&1
    sleep "$RESTART_WAIT_SECONDS"
fi

prefix="$(get_prefix)"
if [ -n "$prefix" ]; then
    record_recovery "$prefix"
    logger -t "$TAG" "PD recovered after interface restart: ${prefix}"
else
    logger -t "$TAG" "PD still missing after recovery attempt; PPPoE WAN was not restarted"
fi
