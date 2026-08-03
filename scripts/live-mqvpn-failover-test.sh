#!/bin/sh
set -eu

SERVER="${1:-}"
IFACE="${2:-}"
DURATION="${3:-20}"
PORT="${MQVPN_PORT:-65443}"
MAX_MISSING_SEQUENCES="${MAX_MISSING_SEQUENCES:-0}"
HTTPS_PRIMARY="${HTTPS_PRIMARY:-https://connectivitycheck.gstatic.com/generate_204}"
HTTPS_SECONDARY="${HTTPS_SECONDARY:-https://www.cloudflare.com/cdn-cgi/trace}"
WORK="/tmp/omr_failtest-${IFACE}-$$"
PREF_OUT=49152
PREF_IN=49153
CLSACT_CREATED=0
PING_PID=
DNS_PID=
HTTPS_PID=

usage() {
	echo "usage: $0 <mqvpn-server-ipv4> <wan-device> [blackhole-seconds]" >&2
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

cleanup() {
	for pid in "$PING_PID" "$DNS_PID" "$HTTPS_PID"; do
		[ -n "$pid" ] && kill "$pid" 2>/dev/null || true
	done
	if [ -n "$IFACE" ]; then
		tc filter del dev "$IFACE" egress pref "$PREF_OUT" 2>/dev/null || true
		tc filter del dev "$IFACE" ingress pref "$PREF_IN" 2>/dev/null || true
	fi
	if [ "$CLSACT_CREATED" = 1 ]; then
		tc qdisc del dev "$IFACE" clsact 2>/dev/null || true
	fi
}
trap cleanup EXIT HUP INT TERM

[ -n "$SERVER" ] && [ -n "$IFACE" ] || usage
case "$DURATION" in *[!0-9]*|'') usage ;; esac
[ "$DURATION" -ge 5 ] || usage
[ "$(id -u)" = 0 ] || { echo "must run as root" >&2; exit 1; }
for command in tc ping nslookup uclient-fetch pgrep logread logger awk timeout; do
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
if tc filter show dev "$IFACE" egress pref "$PREF_OUT" 2>/dev/null | grep -q . ||
	tc filter show dev "$IFACE" ingress pref "$PREF_IN" 2>/dev/null | grep -q .; then
	echo "refusing to reuse existing tc filter preference" >&2
	exit 1
fi

mkdir -p "$WORK"
PID_BEFORE="$(mqvpn_pid)"
MARKER="omr-failtest-${IFACE}-$$-$(date +%s)"
CHECKS=$((DURATION + 12))
HTTPS_CHECKS=$((DURATION / 2 + 6))

logger -t omr-failtest "$MARKER begin pid=$PID_BEFORE"
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
timeout $((CHECKS + 5)) ping -I tun0 -i 1 -W 1 -c "$CHECKS" "$TUN_PEER" \
	>"$WORK/ping.log" 2>&1 &
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
if ! tc qdisc show dev "$IFACE" | grep -q 'qdisc clsact '; then
	tc qdisc add dev "$IFACE" clsact
	CLSACT_CREATED=1
fi
tc filter add dev "$IFACE" egress protocol ip pref "$PREF_OUT" flower \
	dst_ip "$SERVER" ip_proto udp dst_port "$PORT" action drop
tc filter add dev "$IFACE" ingress protocol ip pref "$PREF_IN" flower \
	src_ip "$SERVER" ip_proto udp src_port "$PORT" action drop
logger -t omr-failtest "$MARKER fault-begin"

sleep "$DURATION"
tc -s filter show dev "$IFACE" egress pref "$PREF_OUT" >"$WORK/tc-egress.txt"
tc -s filter show dev "$IFACE" ingress pref "$PREF_IN" >"$WORK/tc-ingress.txt"
tc filter del dev "$IFACE" egress pref "$PREF_OUT"
tc filter del dev "$IFACE" ingress pref "$PREF_IN"
logger -t omr-failtest "$MARKER fault-end"
if [ "$CLSACT_CREATED" = 1 ]; then
	tc qdisc del dev "$IFACE" clsact
	CLSACT_CREATED=0
fi

wait "$PING_PID" || true
PING_PID=
wait "$DNS_PID"
DNS_PID=
wait "$HTTPS_PID"
HTTPS_PID=

sleep 3
PID_AFTER="$(mqvpn_pid)"
logger -t omr-failtest "$MARKER end pid=$PID_AFTER"
logread | awk -v marker="$MARKER begin" '
	index($0, marker) { seen = 1 }
	seen { print }
' >"$WORK/log.slice"
DROPS="$(awk '
	/dropped [0-9]+/ {
		for (i = 1; i <= NF; i++) if ($i == "dropped" || $i == "(dropped") {
			gsub(/,/, "", $(i + 1)); total += $(i + 1)
		}
	}
	END { print total + 0 }
' "$WORK/tc-egress.txt" "$WORK/tc-ingress.txt")"
MISSING_SEQUENCES="$(awk -v expected="$CHECKS" '
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

[ "$DROPS" -gt 0 ] || { echo "FAIL: test rule dropped no MQVPN packets" >&2; exit 1; }
[ "$PID_AFTER" = "$PID_BEFORE" ] || { echo "FAIL: MQVPN PID changed" >&2; exit 1; }
grep -Fq "$MARKER begin" "$WORK/log.slice" || {
	echo "FAIL: log evidence was evicted; reconnect result is inconclusive" >&2
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
[ "$MISSING_SEQUENCES" -le "$MAX_MISSING_SEQUENCES" ] || {
	echo "FAIL: tunnel ping missed $MISSING_SEQUENCES of $CHECKS sequences" >&2
	exit 1
}
[ "$DNS_FAILURES" = 0 ] || { echo "FAIL: DNS failures=$DNS_FAILURES" >&2; exit 1; }
[ "$HTTPS_FAILURES" = 0 ] || { echo "FAIL: HTTPS failures=$HTTPS_FAILURES" >&2; exit 1; }
ping -I tun0 -c 3 -W 1 "$TUN_PEER" >/dev/null || {
	echo "FAIL: tunnel peer did not recover after the test" >&2
	exit 1
}

PATH_RESTORED=0
i=0
while [ "$i" -lt 20 ]; do
	if /usr/bin/mqvpn-path list 2>/dev/null | grep -q "\"$IFACE\""; then
		PATH_RESTORED=1
		break
	fi
	i=$((i + 1))
	sleep 1
done
[ "$PATH_RESTORED" = 1 ] || { echo "FAIL: $IFACE was not restored to MQVPN" >&2; exit 1; }

echo "PASS iface=$IFACE drops=$DROPS missing_ping_sequences=$MISSING_SEQUENCES/$CHECKS dns_failures=$DNS_FAILURES https_failures=$HTTPS_FAILURES pid=$PID_AFTER log=$WORK/log.slice"
