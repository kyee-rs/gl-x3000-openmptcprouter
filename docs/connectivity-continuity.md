# Connectivity continuity research

This document records the failure analysis and the resulting continuity policy
for a GL-X3000 using Ethernet and PCIe cellular as explicit MQVPN paths. All
addresses, credentials, carrier identifiers, and subscriber data are omitted.

## What "uninterrupted" can mean

With two independent WANs, a single-WAN failure should not reset the tunnel or
existing TCP sessions. No software configuration can guarantee connectivity
when both WANs fail together, the router loses power, or the only VPS becomes
unreachable from both providers. Those cases require another independent fault
domain, not another tracker setting.

The practical target for this build is:

- either WAN may become a black hole without restarting MQVPN;
- the surviving WAN keeps the same tunnel and client sessions alive;
- an OMR Tracker false positive cannot remove an explicitly configured path;
- an intentional administrative removal cannot close the connection while
  another validated path remains;
- a recovered WAN rejoins without restarting the tunnel; and
- status automation never owns a lower-level path that MQVPN already monitors.

## Captured failure

A complete outage was captured while both physical interfaces remained up and
the MQVPN process remained alive:

1. Cellular was actively receiving tunnel traffic.
2. OMR Tracker's rotating ICMP probes selected three hosts which all failed to
   answer from that source address.
3. Tracker changed the cellular WAN to `ERROR`.
4. `005-mqvpn-path` sent `mqvpn-path remove` for the cellular device.
5. Cellular happened to be the current QUIC path 0. MQVPN deliberately closed
   the whole HTTP/3 connection when asked to remove that path.
6. Reconnection retries selected the now-removed path twice before another path
   succeeded. The tunnel was unavailable for roughly 35 seconds.

The WAN verdict was a false positive: MQVPN counters proved that cellular
carried traffic immediately before and after the failed ICMP probes. Neither
the modem, Ethernet carrier, MQVPN process, nor VPS service failed.

Carrier-side public-address churn occurred shortly before the event, but the
local MBIM session and data counters stayed live. A changed carrier NAT address
is therefore not, by itself, evidence that the cellular data link is down.

## Why the behavior was reproducible

The previously pinned MQVPN source treated an administrative removal of QUIC
path 0 as a connection-wide operation. Its client explicitly closes the HTTP/3
connection.

Linux link and address events take a different path through MQVPN. Its platform
monitor handles real netlink disappearance as a platform-owned path drop, so
the surviving path can continue carrying the existing connection. OMR
Tracker's control command bypassed that lower-level failure handling.

The OMR feed still calls `mqvpn-path remove` on a tracker error. Updating only
MQVPN therefore does not remove the ownership conflict between an
application-agnostic tracker and an explicitly configured transport path.

Primary source:

- [pinned MQVPN client path lifecycle](https://github.com/Ysurac/mqvpn/blob/3a07dc7e359629ed6fa246139a534924b6af7975/src/mqvpn_client.c)
- [selected MQVPN 0.14.1 client path lifecycle](https://github.com/Ysurac/mqvpn/blob/e6fcf7e6943d98d465155e27eb5279ac082051de/src/mqvpn_client.c)
- [current OMR MQVPN tracker hook](https://github.com/ysurac/openmptcprouter-feeds/blob/d935eff2aacf7f2907ac3039abadf0b57688afc9/omr-tracker/files/usr/share/omr/post-tracking.d/005-mqvpn-path)
- [IETF Multipath QUIC path-management draft](https://datatracker.ietf.org/doc/html/draft-ietf-quic-multipath-21)

## Implemented ownership rule

When `mqvpn.multipath.auto_wan=0`, the configured path list is authoritative.
On a tracker `ERROR`, the patched `005-mqvpn-path` exits before deleting routes
or calling the MQVPN control API. MQVPN owns liveness, degradation, retry, and
revalidation for those paths.

Dynamic discovery keeps the upstream behavior. Healthy polls also retain the
existing reconciliation behavior so a missing live path can be added back.

The build validator executes the hook with stubbed commands and proves that an
explicit-path `ERROR` does not invoke `mqvpn-path`.

## Transport-level correction

The tracker ownership rule prevents the captured false-positive path deletion,
but the old transport also had path-removal and address-change races. This build
now selects upstream MQVPN 0.14.1 on both router and VPS. Its path state machine,
netlink recovery, backup-path handling, and removal error policy supersede the
three local patches previously carried against the 0.8.0 client.

The selected source, xquic, and BoringSSL revisions are pinned. BoringSSL is a
`Release` build and the package declares `libstdcpp`, both of which are checked
by the build validator. The old patches remain as historical R&D artifacts;
they are no longer applied to firmware.

The tracker guard remains useful defense in depth and preserves clear ownership:
status probes still should not mutate an explicitly configured MQVPN path list.

### Dead-backup route guard

The tracker integration also used administrative `ifstatus up=true` as proof
that the sibling WAN could carry the VPS route. A modem can remain
administratively connected while its data plane is a black hole. Moving the
only VPS host route to that path interrupts the otherwise healthy MQVPN
connection on the surviving WAN.

The patched `002-error` infers transport ownership from the explicit MQVPN path
list. It moves the VPS host route only when a source-bound probe to the VPS
succeeds through the sibling device. Whether that proof succeeds or fails, the
handler exits before endpoint removal, disconnect hotplug, DNS flushing, or
other destructive generic tracker recovery.

### Bounded CID-exhaustion recovery

Repeated path loss can temporarily exhaust xquic's peer connection-ID pool.
The first `XQC_EMP_NO_AVAIL_PATH_ID` is still treated as transient because the
peer may replenish IDs. Previously, however, an attached path in
`CLOSED_RECOVERABLE` retried forever every three seconds without incrementing
any recovery budget.

MQVPN now enforces a stronger invariant: recovery of one failed path cannot
close the shared connection while another validated path remains. CID/path
budget exhaustion quarantines the failed path, administrative removal uses
path-scoped PATH_ABANDON for every path ID, and removal of the final validated
path is refused. The periodic reactivation loop is also bounded: five failed
attempts quarantine only that path until a genuine link/address event starts a
new recovery episode. A connection refresh remains available only when no
validated sibling can carry the existing tunnel.

### Empty redundant-replica root cause

The remaining intermittent reconnect was not a tracker decision or a WAN
failure. The redundant scheduler copied an ACK/ACK_MP-only packet and then
removed the path-specific acknowledgement frame from the copy. That left a
valid header with no QUIC frames. RFC 9000 requires every packet other than a
Version Negotiation or Stateless Reset packet to contain at least one frame,
so the receiver correctly closed the entire connection with
`PROTOCOL_VIOLATION`.

The correction rejects ACK-only packets before allocating a redundant copy.
It is deliberately scheduler-local: acknowledgement processing is unchanged,
data packets are still replicated, and neither path nor connection lifecycle
logic is invoked. On the pinned revisions, the unpatched path-removal test was
nondeterministic (6 passes and 4 protocol-close failures in 10 runs). The
patched test passed 10 of 10 runs, the focused xquic suite passed 8 tests with
64 assertions, and the complete MQVPN suite passed all 41 tests.

### Silent-loss validation and the redundancy tradeoff

A controlled test blocked only one path's MQVPN UDP traffic for 20 seconds
while leaving the physical WAN and tracker healthy. WLB preserved the session
but produced a 6.09-second tunnel-probe gap because it kept assigning packets to
the silent path. Datagram reinjection reduced that gap but still lost two probe
sequences. Neither result meets the commissioning requirement.

The pinned xquic revision includes its newer `redundant` scheduler and the
follow-up origin/replica cleanup fix. With that scheduler, the same 20-second
silent loss on Starlink and cellular delivered every one of 32 unique tunnel
probe sequences, with zero DNS or HTTPS failures and no MQVPN restart. Hard
local socket errors on either WAN also remained path-scoped; the measured
maximum probe gaps were 0.06 seconds on Starlink and 1.04 seconds on cellular.

Redundant mode sends every tunnel packet on every usable path. It therefore
uses roughly twice the WAN traffic, does not aggregate capacity, and can make
diagnostic ICMP appear duplicated. TCP and QUIC consumers discard duplicates,
but metered cellular usage must be considered. This build chooses continuity
over aggregation because WLB did not satisfy the tested silent-loss gate.

The upgrade must also migrate the old local scheduler policy. `backup` is not a
supported MQVPN 0.14.1 scheduler; upstream supports `wlb`, `wlb_udp_pin`,
`minrtt`, `redundant`, and experimental `backup_fec`. Preserving
`scheduler=backup` plus
separate `primary_path` and `backup_path` lists registered cellular but failed
to schedule tunnel datagrams onto it during a Starlink black hole. The build
now migrates that legacy shape to `redundant` with both explicit paths active.
A clean install uses the same scheduler and disables separate reinjection,
which would otherwise duplicate already duplicated traffic.

## WAN health policy

Tracker still provides OMR status and routing automation, but rotating ICMP
targets are a poor authority for cellular reachability. Some public resolvers
rate-limit or ignore echo requests, and three consecutive ICMP failures can
occur while application traffic is healthy.

Tracker remains useful for status and eventual administrative cleanup, but it
is not the fast failover authority. The live Starlink policy probes the VPS
conservatively:

```sh
uci set omr-tracker.wan1.timeout='2'
uci set omr-tracker.wan1.count='2'
uci set omr-tracker.wan1.tries='3'
uci set omr-tracker.wan1.interval='5'
uci set omr-tracker.wan1.interval_tries='2'
uci set omr-tracker.wan1.failure_interval='10'
uci set omr-tracker.wan1.tries_up='2'

uci commit omr-tracker
/etc/init.d/omr-tracker restart
```

The cellular tracker already uses the same five-second cadence with five failed
cycles before removal. In a 20-sample before/after measurement, the Starlink
change reduced aggregate tracker CPU from 11.3% to 4.7% while MQVPN remained
established with both paths. MQVPN redundancy covers traffic during that slower,
deliberate administrative decision.

## Controlled validation

The live router was tested with an ephemeral nftables table that blocked MQVPN
UDP in both directions on one physical interface at a time. It did not take
interfaces down, alter netifd state, or persist rules.

| Simulated failure | Duration | ICMP tunnel probes | DNS/HTTPS | MQVPN PID |
| --- | ---: | ---: | --- | --- |
| Starlink black hole, legacy unsupported `backup` policy | 15 seconds | 0/15 | passed at end | unchanged |
| Starlink MQVPN silent loss, redundant scheduler | 20 seconds | 32/32 unique | zero failures | unchanged |
| Cellular MQVPN silent loss, redundant scheduler | 20 seconds | 32/32 unique | zero failures | unchanged |
| Starlink hard local send error | 6 seconds | max gap 0.06 s | zero failures | unchanged |
| Cellular hard local send error | 6 seconds | max gap 1.04 s | zero failures | unchanged |
| Synthetic cellular tracker `ERROR` | immediate | no tunnel change | unchanged | unchanged |
| Steady-state soak | 1,800 seconds | 1,800/1,800 unique | zero failures | unchanged |

Both redundant-mode black-hole tests kept the connection established on the
survivor and revalidated the path after traffic was restored. There was no
MQVPN restart, reconnect cycle, tunnel reset, DNS failure, HTTPS failure, or
missing unique probe sequence.

After the fault-injection matrix, independent ten- and thirty-minute live soaks
completed with both paths present. The longer run delivered 1,800/1,800 unique
tunnel probes with zero DNS failures, zero HTTPS failures, no reconnect log,
and the same MQVPN process. The cumulative `tun0` transmit-drop counter rose by
eight during that longer run, while its fq qdisc reported zero drops and no
probe, DNS, or HTTPS request was lost; an earlier fixed 60-second sample had no
counter increase.

The selected router MQVPN build does not enable FEC. Enabling
`backup_fec` would require compatible client and server rebuilds and adds
roughly one repair packet per three source packets with the pinned defaults.
It remains experimental upstream and is not enabled silently. WLB remains the
better aggregation profile when capacity matters more than zero-gap failover;
this continuity profile intentionally accepts redundant-mode bandwidth cost.

## Interpreting health diagnostics

- Duplicate tunnel ping replies are expected in `redundant` mode. Judge the
  test by missing unique sequence numbers, not raw received-packet count.
- xquic BBR2 may log `cwnd compensation: weird things happened` when its
  smoothed RTT is no greater than its stored minimum RTT. That branch returns
  zero optional RTT-variance compensation; it does not close a path, reconnect,
  or reduce the already computed window.
- OpenWrt's firewall is a ruleset loader rather than a resident daemon, so
  `/etc/init.d/firewall running` is not a reliable health test. Use `fw4 check`
  and verify that the `inet fw4` nftables table exists.
- A cumulative TUN drop counter is not evidence of an ongoing fault. Sample it
  over a fixed steady-state interval and corroborate it with qdisc drops,
  missing unique probes, DNS/HTTPS failures, and reconnect logs.

## PCIe power-management finding

The PCIe root port is kept active by the image's `pcie_port_pm=off` boot
argument. The MHI endpoint itself uses the upstream driver's intentional
runtime M3/D3hot autosuspend, so debug logs can show PCI configuration save,
PME enable, resume, and bus mastering.

At the captured outage there was no MHI fatal error, device recovery, AER
event, MBIM disconnect, or lost network carrier. Cellular traffic was active.
Endpoint runtime PM was therefore not the cause of this outage. Forcing the
endpoint to `power/control=on` would trade more modem power and heat for fewer
state transitions, but it is not included without evidence of a resume
failure.

The upstream driver allows runtime suspend only when both PCI PME from D3hot
and MHI M3 are supported:

- [Linux 6.18 `mhi-pci-generic` runtime-PM implementation](https://github.com/torvalds/linux/blob/v6.18/drivers/bus/mhi/host/pci_generic.c)
- [Linux runtime power-management control](https://kernel.org/doc/html/latest/driver-api/pm/devices.html)

The modem may also expose a disabled USB AT-only ModemManager object in addition
to the connected PCIe MHI/MBIM object. That is not a second data link and did
not participate in the outage.

## Remaining failure domains

This correction removes the observed software-created tunnel outage. It cannot
make these cases disappear:

- simultaneous Starlink and cellular failure;
- loss of the only VPS, its provider network, or its UDP forwarding;
- router power loss, kernel crash, reboot, or flash;
- a carrier outage that leaves the interface present but blocks all traffic;
- application-level DNS or destination outages; or
- packet loss during the sub-second transition of latency-sensitive UDP.

True end-to-end high availability would add router power backup, a third WAN or
other independent access path, and a second exit node with tested automatic
failover. Those are separate fault domains and cannot be synthesized from the
current two links.

## Operational checks

Use these together; a green interface alone is not enough:

```sh
pgrep -af '^/usr/sbin/mqvpn --config'
mqvpn-path list
ubus call network.interface.omrvpn status
ubus call service list '{"name":"omr-tracker"}'
ip route get <external-ipv4>
curl -4 --max-time 10 https://example.com/ -o /dev/null
logread | grep -E 'mqvpn|omr-tracker|post-tracking'
```

Do not add `curl --interface tun0` to that test. `SO_BINDTODEVICE` is not
equivalent to following the installed default route through the TUN device and
can time out even while ordinary routed HTTPS succeeds. Confirm that
`ip route get` selects `tun0`, then use an unbound client request.

For explicit paths, an OMR Tracker error must never be followed by
`mqvpn: remove path`. A real WAN failure should instead produce an MQVPN path
transition from active to degraded or pending while the connection remains
established. A deliberate control-API removal is separately required to keep
the same HTTP/3 connection whenever a validated sibling remains.
