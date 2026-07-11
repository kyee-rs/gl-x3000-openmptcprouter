# Runtime commissioning lessons

This page records sanitized commissioning findings from a GL-X3000 running the
image produced by this kit. It intentionally contains no router backup, SIM
data, APN, credentials, public endpoints, subscriber identifiers, or private
keys.

## LAN and Wi-Fi must share a bridge

Successful WPA association does not prove that a wireless client has a Layer 2
path to the DHCP server. A configuration in which the `lan` interface points
directly at the physical LAN Ethernet port allows wired clients to work while
wireless clients authenticate and then fail DHCP.

The working topology is:

```text
lan (static management subnet)
└── br-lan
    ├── physical LAN Ethernet port
    ├── 2.4 GHz AP
    └── 5 GHz AP
```

Keep the Starlink/WAN Ethernet port outside this bridge. Configure both APs for
the `lan` network, enable DHCPv4 on `lan`, and make the physical LAN Ethernet
port a member of `br-lan`. Apply bridge changes from a wired session with a
timed rollback because the management connection will briefly reset.

Verification should prove all of the following rather than relying only on the
web interface:

```sh
ubus call network.interface.lan status
brctl show
iw dev
cat /tmp/dhcp.leases
```

The LAN interface should report `br-lan`; both AP devices and the physical LAN
port should appear under that bridge; and an associated wireless station should
receive a lease.

## PCIe cellular ownership

For this target the working ModemManager path uses the native PCIe MHI device,
the MHI MBIM data interface, and the dedicated MHI AT port. A temporary
"No modems were found" result immediately after boot can simply mean discovery
is still in progress. Wait briefly and check again before changing drivers.

Do not configure both native netifd MBIM and ModemManager to own the same modem.
The first-boot ownership guard included in this repository enforces that rule.
The ModemManager QDU guard is also required: the modem advertises QDU on the
WWAN MBIM port but does not provide a usable AT command channel there.

## OMR tunnel device integration

OpenMPTCProuter's existing firewall and status model expects the selected VPN
to use the device configured by the `omrvpn` network. In the tested setup that
device is `tun0`. Leaving a standalone VPN package at its generic tunnel name
causes packets to hit the firewall's final reject rule even when the VPN itself
reports an established session.

For a userspace VPN that assigns its own point-to-point address:

- use the tunnel device expected by `network.omrvpn`;
- leave `omrvpn` as an unmanaged (`none`) interface rather than a DHCP client;
- keep `omrvpn` in the existing VPN firewall zone; and
- restart the VPN after changing the interface mode so it can reinstall its
  split-default routes.

Verify the service, tunnel, OMR interface state, routes, DNS, and public egress
as separate gates. A green VPN process alone is insufficient.

## Performance observations

Weighted multipath scheduling can increase aggregate throughput but may add
small interactive pauses when Starlink and cellular have different latency or
jitter. Minimum-RTT scheduling is a useful alternative for SSH, gaming, and
other latency-sensitive traffic. It preserves path availability while favoring
the currently faster link.

OMR Tracker remains necessary because it drives WAN, proxy, VPN, and routing
state outside the VPN process itself. Very short tracker intervals create brief
CPU bursts on the dual-core router. A modest interval increase can reduce that
work, at the cost of proportionally slower failure detection.
