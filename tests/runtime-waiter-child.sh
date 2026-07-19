#!/usr/bin/env bash
# Deterministic child process for the manual collaboration-mailbox wake probe.

set -euo pipefail
delay="${1:-1}"
case "$delay" in ''|*[!0-9]*) echo "usage: runtime-waiter-child.sh [delay-seconds]" >&2; exit 2 ;; esac
[ "$delay" -le 5 ] || { echo "delay must be <= 5 seconds" >&2; exit 2; }
sleep "$delay"
printf 'WAITER_COMPLETION_OK\n'
