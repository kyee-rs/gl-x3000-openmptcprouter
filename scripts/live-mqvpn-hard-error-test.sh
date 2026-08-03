#!/bin/sh
set -eu

SERVER="${1:-}"
IFACE="${2:-}"
DURATION="${3:-6}"
PORT="${MQVPN_PORT:-65443}"
MAX_GAP_SECONDS="${MAX_GAP_SECONDS:-1.5}"
MAX_HARD_ERRORS="${MAX_HARD_ERRORS:-10}"
HTTPS_PRIMARY="${HTTPS_PRIMARY:-https://connectivitycheck.gstatic.com/generate_204}"
HTTPS_SECONDARY="${HTTPS_SECONDARY:-https://www.cloudflare.com/cdn-cgi/trace}"
TABLE="omr_hardtest_$$"
WORK="/tmp/omr_hardtest-${IFACE}-$$"
PING_PID=
DNS_PID=
HTTPS_PID=
PATH_WAS_PRESENT=0

usage() {
	echo "usage: $0 <mqvpn-server-ipv4> <wan-device> [failure-seconds]" >&2
	exit 2
}

mqvpn_pid() {
	pid="$(pgrep -x mqvpn 2>/dev/null || true)"
	case "$pid" in
		''|*[!0-9]*)
			echo "expected exactly one mqvpn daemon, found: ${pid:-none}" >&2
			return 1
			;;
	esac
	printf '%s\n' "$pid"
}

mqvpn_reconnected() {
	awk -v needle="mqvpn[$PID_BEFORE]" '
		index($0, needle) &&
			$0 ~ /(connecting to|state=(connecting|reconnecting)|connection closed|tunnel closed)/ {
			found = 1
		}
		END { exit !found }
	' "$WORK/log.slice"
}

https_probe() {
	uclient-fetch -T 5 -q -O /dev/null "$HTTPS_PRIMARY" >/dev/null 2>&1 ||
		uclient-fetch -T 5 -q -O /dev/null "$HTTPS_SECONDARY" >/dev/null 2>&1
}

path_present() {
	/usr/bin/mqvpn-path list 2>/dev/null | grep -q "\"$IFACE\""
}

restore_path() {
	path_present && return 0
	/usr/bin/mqvpn-path add "$IFACE" >/dev/null 2>&1 || true
	i=0
	while [ "$i" -lt 20 ]; do
		path_present && return 0
		i=$((i + 1))
		sleep 1
	done
	return 1
}

cleanup() {
	for pid in "$PING_PID" "$DNS_PID" "$HTTPS_PID"; do
		[ -n "$pid" ] && kill "$pid" 2>/dev/null || true
	done
	nft delete table inet "$TABLE" 2>/dev/null || true
	if [ "$PATH_WAS_PRESENT" = 1 ]; then
		restore_path || true
	fi
}
trap cleanup EXIT HUP INT TERM

[ -n "$SERVER" ] && [ -n "$IFACE" ] || usage
case "$DURATION" in *[!0-9]*|'') usage ;; esac
[ "$DURATION" -ge 3 ] || usage
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
for command in nft ip ping nslookup uclient-fetch pgrep logread logger awk timeout; do
	command -v "$command" >/dev/null 2>&1 || {
		echo "missing command: $command" >&2
		exit 1
	}
done
ip link show "$IFACE" >/dev/null 2>&1 || {
	echo "interface not found: $IFACE" >&2
	exit 1
}
ip link show tun0 >/dev/null 2>&1 || {
	echo "tun0 is not available" >&2
	exit 1
}
nft list table inet "$TABLE" >/dev/null 2>&1 && {
	echo "refusing to reuse existing nftables table" >&2
	exit 1
}
PATHS_BEFORE="$(/usr/bin/mqvpn-path list)"
printf '%s\n' "$PATHS_BEFORE" | grep -q '"eth0"' || {
	echo "eth0 is not active before the test" >&2
	exit 1
}
printf '%s\n' "$PATHS_BEFORE" | grep -q '"wwan0"' || {
	echo "wwan0 is not active before the test" >&2
	exit 1
}
path_present || {
	echo "$IFACE is not active before the test" >&2
	exit 1
}
PATH_WAS_PRESENT=1

TUN_PEER="$(ip -4 addr show dev tun0 | awk '
	/inet / {
		for (i = 1; i <= NF; i++) if ($i == "peer") {
			split($(i + 1), part, "/")
			print part[1]
			exit
		}
	}
')"
[ -n "$TUN_PEER" ] || { echo "unable to determine tunnel peer" >&2; exit 1; }

mkdir -p "$WORK"
PID_BEFORE="$(mqvpn_pid)"
MARKER="omr-hardtest-${IFACE}-$$-$(date +%s)"
CHECKS=$((DURATION + 12))
HTTPS_CHECKS=$((DURATION / 2 + 6))

logger -t omr-hardtest "$MARKER begin pid=$PID_BEFORE"
(
	i=0
	while [ "$i" -lt "$CHECKS" ]; do
		read -r timestamp _ </proc/uptime
		if ping -I tun0 -c 1 -W 1 "$TUN_PEER" >/dev/null 2>&1; then
			echo "$timestamp ok"
		else
			echo "$timestamp fail"
		fi
		i=$((i + 1))
		[ "$i" -ge "$CHECKS" ] || sleep 1
	done
) >"$WORK/ping.log" 2>&1 &
PING_PID=$!
(
	failures=0
	i=0
	while [ "$i" -lt "$CHECKS" ]; do
		nslookup openmptcprouter.com 127.0.0.1 >/dev/null 2>&1 || failures=$((failures + 1))
		i=$((i + 1))
		sleep 1
	done
	echo "$failures" >"$WORK/dns.failures"
) &
DNS_PID=$!
(
	failures=0
	i=0
	while [ "$i" -lt "$HTTPS_CHECKS" ]; do
		https_probe || failures=$((failures + 1))
		i=$((i + 1))
		sleep 2
	done
	echo "$failures" >"$WORK/https.failures"
) &
HTTPS_PID=$!

sleep 3
nft add table inet "$TABLE"
nft "add chain inet $TABLE output { type filter hook output priority -300; policy accept; }"
nft add rule inet "$TABLE" output oifname "$IFACE" ip daddr "$SERVER" \
	udp dport "$PORT" counter drop
sleep "$DURATION"
nft list table inet "$TABLE" >"$WORK/nft.txt"
nft delete table inet "$TABLE"

restore_path || { echo "FAIL: $IFACE was not restored to MQVPN" >&2; exit 1; }
wait "$PING_PID" || true
PING_PID=
wait "$DNS_PID"
DNS_PID=
wait "$HTTPS_PID"
HTTPS_PID=

sleep 3
PID_AFTER="$(mqvpn_pid)"
logger -t omr-hardtest "$MARKER end pid=$PID_AFTER"
logread | awk -v marker="$MARKER begin" '
	index($0, marker) { seen = 1 }
	seen { print }
' >"$WORK/log.slice"
PACKETS="$(awk '
	/counter packets/ {
		for (i = 1; i <= NF; i++) if ($i == "packets") {
			print $(i + 1) + 0
			exit
		}
	}
' "$WORK/nft.txt")"
MAX_GAP="$(awk '
	$2 == "ok" {
		if (seen && $1 - previous > max_gap) max_gap = $1 - previous
		previous = $1
		seen = 1
	}
	END { if (!seen) print 999999; else printf "%.2f\n", max_gap + 0 }
' "$WORK/ping.log")"
PING_FAILURES="$(grep -c ' fail$' "$WORK/ping.log" || true)"
DNS_FAILURES="$(cat "$WORK/dns.failures")"
HTTPS_FAILURES="$(cat "$WORK/https.failures")"
HARD_ERRORS="$(grep "mqvpn\[$PID_BEFORE\]" "$WORK/log.slice" |
	grep -Fc "hard socket send error on path $IFACE" || true)"

[ "${PACKETS:-0}" -gt 0 ] || { echo "FAIL: nftables dropped no MQVPN packets" >&2; exit 1; }
[ "$PID_AFTER" = "$PID_BEFORE" ] || { echo "FAIL: MQVPN PID changed" >&2; exit 1; }
grep -Fq "$MARKER begin" "$WORK/log.slice" || {
	echo "FAIL: log evidence was evicted; result is inconclusive" >&2
	exit 1
}
grep -Fq "$MARKER end" "$WORK/log.slice" || {
	echo "FAIL: end marker missing from log evidence" >&2
	exit 1
}
[ "$HARD_ERRORS" -gt 0 ] || { echo "FAIL: hard-error path was not exercised" >&2; exit 1; }
[ "$HARD_ERRORS" -le "$MAX_HARD_ERRORS" ] || {
	echo "FAIL: hard-error retry storm ($HARD_ERRORS messages)" >&2
	exit 1
}
[ "$PING_FAILURES" = 0 ] || {
	echo "FAIL: tunnel ping failures=$PING_FAILURES" >&2
	exit 1
}
if mqvpn_reconnected; then
	echo "FAIL: MQVPN reconnected or closed during the test" >&2
	exit 1
fi
awk -v gap="$MAX_GAP" -v limit="$MAX_GAP_SECONDS" 'BEGIN { exit !(gap <= limit) }' || {
	echo "FAIL: tunnel probe gap ${MAX_GAP}s exceeded ${MAX_GAP_SECONDS}s" >&2
	exit 1
}
[ "$DNS_FAILURES" = 0 ] || { echo "FAIL: DNS failures=$DNS_FAILURES" >&2; exit 1; }
[ "$HTTPS_FAILURES" = 0 ] || { echo "FAIL: HTTPS failures=$HTTPS_FAILURES" >&2; exit 1; }
ping -I tun0 -c 3 -W 1 "$TUN_PEER" >/dev/null || {
	echo "FAIL: tunnel peer did not recover after the test" >&2
	exit 1
}

echo "PASS iface=$IFACE packets=$PACKETS hard_errors=$HARD_ERRORS ping_failures=0/$CHECKS max_ping_gap=$MAX_GAP dns_failures=$DNS_FAILURES https_failures=$HTTPS_FAILURES pid=$PID_AFTER log=$WORK/log.slice"
