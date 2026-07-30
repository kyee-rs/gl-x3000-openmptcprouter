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

## Why the behavior is reproducible

The pinned MQVPN source treats an administrative removal of QUIC path 0 as a
connection-wide operation. Its client explicitly closes the HTTP/3 connection
instead of waiting through a black-hole interval. The current upstream source
retains that policy.

Linux link and address events take a different path through MQVPN. Its platform
monitor handles real netlink disappearance as a platform-owned path drop, so
the surviving path can continue carrying the existing connection. OMR
Tracker's control command bypassed that lower-level failure handling.

The latest OMR feed still calls `mqvpn-path remove` on a tracker error. Updating
only MQVPN or only OMR Tracker therefore does not remove this integration
hazard.

Primary source:

- [pinned MQVPN client path lifecycle](https://github.com/Ysurac/mqvpn/blob/3a07dc7e359629ed6fa246139a534924b6af7975/src/mqvpn_client.c)
- [current MQVPN client path lifecycle](https://github.com/Ysurac/mqvpn/blob/93b0ed9324867473839c87d54afac92749ace73a/src/mqvpn_client.c)
- [current OMR MQVPN tracker hook](https://github.com/ysurac/openmptcprouter-feeds/blob/d935eff2aacf7f2907ac3039abadf0b57688afc9/omr-tracker/files/usr/share/omr/post-tracking.d/005-mqvpn-path)
- [IETF Multipath QUIC path-management draft](https://datatracker.ietf.org/doc/html/draft-ietf-quic-multipath-19)

## Implemented ownership rule

When `mqvpn.multipath.auto_wan=0`, the configured path list is authoritative.
On a tracker `ERROR`, the patched `005-mqvpn-path` exits before deleting routes
or calling the MQVPN control API. MQVPN owns liveness, degradation, retry, and
revalidation for those paths.

Dynamic discovery keeps the upstream behavior. Healthy polls also retain the
existing reconciliation behavior so a missing live path can be added back.

This is intentionally a one-condition integration fix. It does not change
MQVPN, xquic, netifd, firewall routing, or the modem connection manager.

The build validator executes the hook with stubbed commands and proves that an
explicit-path `ERROR` does not invoke `mqvpn-path`.

## WAN health policy

Tracker still provides OMR status and routing automation, but rotating ICMP
targets are a poor authority for cellular reachability. Some public resolvers
rate-limit or ignore echo requests, and three consecutive ICMP failures can
occur while application traffic is healthy.

The commissioned policy uses source-bound DNS queries against three independent
providers:

```sh
uci set omr-tracker.stable_dns='hosts_defaults'
uci add_list omr-tracker.stable_dns.hosts='<cloudflare-dns-ipv4>'
uci add_list omr-tracker.stable_dns.hosts='<google-public-dns-ipv4>'
uci add_list omr-tracker.stable_dns.hosts='<quad9-dns-ipv4>'

for interface in wan1 wan2; do
	uci set "omr-tracker.${interface}=interface"
	uci set "omr-tracker.${interface}.type=dns"
	uci set "omr-tracker.${interface}.country=stable_dns"
	uci set "omr-tracker.${interface}.timeout=2"
	uci set "omr-tracker.${interface}.count=2"
	uci set "omr-tracker.${interface}.tries=3"
	uci set "omr-tracker.${interface}.tries_up=3"
	uci set "omr-tracker.${interface}.interval=3"
	uci set "omr-tracker.${interface}.interval_tries=1"
	uci set "omr-tracker.${interface}.failure_interval=5"
	uci set "omr-tracker.${interface}.restart_down=0"
	uci set "omr-tracker.${interface}.family=ipv4"
done

uci commit omr-tracker
/etc/init.d/omr-tracker restart
```

The DNS checks judge general WAN egress. MQVPN independently judges whether its
UDP path to the VPS is usable. This avoids making an application-agnostic
tracker the destructive owner of an established multipath connection.

## Controlled validation

The live router was tested with an ephemeral nftables table that blocked MQVPN
UDP in both directions on one physical interface at a time. It did not take
interfaces down, alter netifd state, or persist rules.

| Simulated failure | Duration | Tunnel probes | MQVPN PID | Configured paths |
| --- | ---: | ---: | --- | --- |
| Ethernet path black hole | 15 seconds | 300/300 | unchanged | unchanged |
| Cellular path black hole | 15 seconds | 299/300 | unchanged | unchanged |
| Synthetic cellular tracker `ERROR` | immediate | no tunnel change | unchanged | unchanged |

During both black-hole tests MQVPN degraded the failed path, kept the connection
established on the survivor, and revalidated the path after traffic was
restored. There was no reconnect cycle or tunnel reset. The single lost
datagram in the cellular test is below the level that resets a TCP session;
TCP retransmission preserves SSH and web connections.

The deployed MQVPN binary reports that FEC was not compiled in. Enabling
`backup_fec` would require compatible client and server rebuilds and adds
roughly one repair packet per three source packets with the pinned defaults.
That overhead is not justified to hide one transition datagram for a primarily
TCP workload. `minrtt` remains the appropriate scheduler for asymmetric
Starlink and cellular latency.

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
established.
