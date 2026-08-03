#!/bin/sh
set -eu

DURATION="${1:-600}"
HTTPS_PRIMARY="${HTTPS_PRIMARY:-https://connectivitycheck.gstatic.com/generate_204}"
HTTPS_SECONDARY="${HTTPS_SECONDARY:-https://www.cloudflare.com/cdn-cgi/trace}"
WORK="/tmp/omr_soak-$$"
PING_PID=
DNS_PID=
HTTPS_PID=

usage() {
	echo "usage: $0 [duration-seconds]" >&2
	exit 2
}

cleanup() {
	for pid in "$PING_PID" "$DNS_PID" "$HTTPS_PID"; do
		[ -n "$pid" ] && kill "$pid" 2>/dev/null || true
	done
}
trap cleanup EXIT HUP INT TERM

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

case "$DURATION" in *[!0-9]*|'') usage ;; esac
[ "$DURATION" -ge 60 ] || usage
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
for command in ip ping nslookup uclient-fetch pgrep logread logger awk timeout; do
	command -v "$command" >/dev/null 2>&1 || {
		echo "missing command: $command" >&2
		exit 1
	}
done
ip link show tun0 >/dev/null 2>&1 || {
	echo "tun0 is not available" >&2
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
MARKER="omr-soak-$$-$(date +%s)"
DNS_CHECKS=$((DURATION / 2))
HTTPS_CHECKS=$((DURATION / 10))
logger -t omr-soak "$MARKER begin pid=$PID_BEFORE"

timeout $((DURATION + 10)) ping -I tun0 -i 1 -W 1 -c "$DURATION" "$TUN_PEER" \
	>"$WORK/ping.log" 2>&1 &
PING_PID=$!
(
	failures=0
	i=0
	while [ "$i" -lt "$DNS_CHECKS" ]; do
		nslookup openmptcprouter.com 127.0.0.1 >/dev/null 2>&1 || failures=$((failures + 1))
		i=$((i + 1))
		sleep 2
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
		sleep 10
	done
	echo "$failures" >"$WORK/https.failures"
) &
HTTPS_PID=$!

wait "$PING_PID" || true
PING_PID=
wait "$DNS_PID"
DNS_PID=
wait "$HTTPS_PID"
HTTPS_PID=

PID_AFTER="$(mqvpn_pid)"
logger -t omr-soak "$MARKER end pid=$PID_AFTER"
logread | awk -v marker="$MARKER begin" '
	index($0, marker) { seen = 1 }
	seen { print }
' >"$WORK/log.slice"
MISSING_SEQUENCES="$(awk -v expected="$DURATION" '
	/(^|[[:space:]])(icmp_)?seq=/ && $0 !~ /\(DUP!\)/ {
		for (i = 1; i <= NF; i++) if ($i ~ /^(icmp_)?seq=/) {
			split($i, part, "=")
			seen[part[2] + 0] = 1
		}
	}
	END {
		received = 0
		for (seq in seen) received++
		print expected - received
	}
' "$WORK/ping.log")"
DNS_FAILURES="$(cat "$WORK/dns.failures")"
HTTPS_FAILURES="$(cat "$WORK/https.failures")"
WARNINGS="$(grep -Fc 'peer validated address while inflight bytes is 0' "$WORK/log.slice" || true)"

[ "$PID_AFTER" = "$PID_BEFORE" ] || { echo "FAIL: MQVPN PID changed" >&2; exit 1; }
grep -Fq "$MARKER begin" "$WORK/log.slice" || {
	echo "FAIL: log evidence was evicted; result is inconclusive" >&2
	exit 1
}
grep -Fq "$MARKER end" "$WORK/log.slice" || {
	echo "FAIL: end marker missing from log evidence" >&2
	exit 1
}
if mqvpn_reconnected; then
	echo "FAIL: MQVPN reconnected or closed during the test" >&2
	exit 1
fi
[ "$MISSING_SEQUENCES" = 0 ] || {
	echo "FAIL: tunnel ping missed $MISSING_SEQUENCES of $DURATION sequences" >&2
	exit 1
}
[ "$DNS_FAILURES" = 0 ] || { echo "FAIL: DNS failures=$DNS_FAILURES" >&2; exit 1; }
[ "$HTTPS_FAILURES" = 0 ] || { echo "FAIL: HTTPS failures=$HTTPS_FAILURES" >&2; exit 1; }

PATHS_AFTER="$(/usr/bin/mqvpn-path list)"
printf '%s\n' "$PATHS_AFTER" | grep -q '"eth0"' || { echo "FAIL: eth0 path missing" >&2; exit 1; }
printf '%s\n' "$PATHS_AFTER" | grep -q '"wwan0"' || { echo "FAIL: wwan0 path missing" >&2; exit 1; }

echo "PASS duration=${DURATION}s missing_ping_sequences=0/$DURATION dns_failures=0 https_failures=0 pid=$PID_AFTER zero_inflight_warnings=$WARNINGS log=$WORK/log.slice"
