# MQVPN VPS integration

MQVPN support spans more than installing a client package on the router. The
server process, public UDP forwarding, guest firewall, source NAT, client
firewall device, OMR status interface, and persistence hooks must all agree.

This document uses symbolic names instead of deployment-specific addresses:

```text
PUBLIC_IF       public interface on the virtualization host
LIBVIRT_BRIDGE  bridge of the isolated OMR network
OMR_VM          private address of the OMR guest
MQVPN_SUBNET    address pool configured in the MQVPN server template
MQVPN_PORT      UDP service port (normally 65443)
```

## Required packet path

```text
internet
  → host firewalld UDP forward/DNAT
  → Docker-compatible forwarding exception
  → libvirt guest-input DNAT exception
  → MQVPN listener in the OMR VM
  → MQVPN tunnel interface
  → Shorewall vpn-to-net forwarding
  → Shorewall source masquerade
  → VM default route
  → libvirt host NAT
  → internet
```

An established QUIC handshake proves only the inbound half of this path. If the
guest firewall was compiled before MQVPN was installed, the persistent
configuration may already mention the MQVPN interface and subnet while the
active rules do not. Validate the firewall configuration and reload it after
installing the server.

## Virtualization-host publication

Publish only UDP `MQVPN_PORT` to `OMR_VM`. Apply the same narrow tuple at every
host filtering layer:

- public zone forward/DNAT, runtime and permanent;
- `DOCKER-USER`, restricted by input interface, output bridge, destination,
  protocol, connection state, and port;
- libvirt's guest-input chain, restricted by the same tuple plus DNAT status;
  and
- the boot-time forwarding service and delayed libvirt reconnect hook.

Do not replace these rules with a blanket accept between the public interface
and the libvirt bridge. Libvirt's default rejection for unrelated guest traffic
should remain in place.

After updating an allow-list rule, remove the obsolete narrower rule before
installing the replacement. Otherwise both remain active until the next clean
firewall recreation.

## OMR VM configuration

The server requires:

- the version-matched MQVPN package and library;
- a root-owned server configuration;
- a root-owned authentication value shared with the router;
- a private TLS key and public certificate;
- a systemd service enabled at boot; and
- a UDP listener on `MQVPN_PORT`.

Shorewall must classify the MQVPN tunnel wildcard as `vpn`, allow `vpn` to
`net`, and masquerade `MQVPN_SUBNET` through the VM's external interface. IPv4
forwarding must be enabled. Run `shorewall check` before a reload and retain a
root-only copy of the previous configuration.

## Router integration

The tested OMR integration requires MQVPN to create `tun0`, because that is the
device already referenced by `network.omrvpn` and the VPN firewall zone. The
`omrvpn` interface must use unmanaged protocol mode because MQVPN assigns the
point-to-point address itself.

After changing either setting, restart MQVPN so it recreates the tunnel and
installs its routes. Confirm that:

```sh
/etc/init.d/mqvpn status
ifstatus omrvpn
ip -br addr show tun0
ip route show
```

The service should be running, `omrvpn` should be up on `tun0`, the tunnel
should have a point-to-point address, and the split-default routes should point
to `tun0`. Then test DNS and public egress from an actual LAN client.

## Failure signatures

| Symptom | Likely boundary |
|---|---|
| Tunnel never authenticates | UDP publication, listener, or shared authentication value |
| Tunnel establishes but sends immediately fail with a policy error | Router tunnel device absent from the OMR VPN firewall zone |
| Packets enter the VPS tunnel but never leave its public interface | Guest forwarding or Shorewall policy |
| Packets leave the VPS but replies never return | Source masquerade or upstream/libvirt NAT |
| Internet works but OMR still reports the VPN down | `omrvpn` device/protocol mismatch |
| VPN status is up but traffic bypasses the VPS | VPN routes were removed during an interface reload; restart the VPN |

Use simultaneous, narrowly filtered captures on the tunnel and public
interfaces when counters are inconclusive. Avoid publishing packet captures or
complete configurations because they may contain private endpoints and keys.

## Credential handling

Generate authentication material on a trusted endpoint, store it with
root-only permissions, and transfer it without printing it to terminal logs.
Compare normalized hashes rather than displaying the value. Rotate immediately
if a diagnostic page, command trace, or publication process renders any part of
it. Never commit generated configuration, certificates, private keys, router
backups, or shell history to this repository.
