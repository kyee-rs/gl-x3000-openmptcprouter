# Native MBIM and ModemManager

Both designs can be valid. They must not control the same MBIM port simultaneously.

## Comparison

| Property | Native OpenWrt MBIM | ModemManager |
| --- | --- | --- |
| netifd protocol | `mbim` | `modemmanager` |
| Main userspace component | `umbim` protocol helper | ModemManager over D-Bus |
| Best use during bring-up | Yes: fewer moving parts and explicit control port | After kernel topology is known-good |
| Reconnect/state handling | Protocol-script dependent | Rich modem/bearer state machine |
| SIM PIN and radio controls | Basic protocol options/tools | Integrated API and state reporting |
| MHI-specific version concern | Mostly kernel and `umbim` compatibility | Requires correct `mhi-pci-generic` data-port handling and an RM520N WWAN/QDU guard |
| Port grouping concern | Explicit control device configured | Must group PCIe MHI and any USB-side ports correctly |
| Failure isolation | Easier to distinguish kernel/MBIM from daemon behavior | Better long-term management when correctly integrated |

## Recommended engineering sequence

1. Prove PCIe enumeration and the exact Quectel MHI topology.
2. Stop ModemManager and prove a native MBIM bearer with bidirectional traffic.
3. Record the working kernel devices, MTU, address, routes, DNS, and counters.
4. Stop the native MBIM owner.
5. Start the patched/current ModemManager and reproduce the same tests.
6. Select one production owner based on reconnect and soak-test results.

This sequence is diagnostic, not a recommendation to switch owners on a production router remotely.

The build kit includes a `uci-defaults` ownership guard for the GL-X3000's
single built-in modem. On first boot, any preserved `proto=mbim` section
disables ModemManager before its init service starts. If no native-MBIM section
exists, `proto=modemmanager` leaves the service state unchanged; it does not
re-enable a service that was already disabled. If neither owner is configured,
the script exits nonzero so OpenWrt retains it for a later boot after
configuration restore. Native MBIM therefore wins globally if both protocol
types are present. This guard prevents the common first-boot race, but it is not
a per-port multi-modem policy and does not make concurrent manual use of
`mmcli` and `umbim` safe.

## Why older ModemManager builds can fail

There are two separate problems that can look like one generic negotiation error.

### Wrong modem surface selected

The RM520N-GL can expose USB serial/AT ports alongside its PCIe MHI ports. In OpenWrt builds without udev, hotplug scripts report ports to ModemManager. If those ports are grouped or prioritized incorrectly, ModemManager can create an AT-oriented modem object and attempt a PPP-style connection while the intended data path is PCIe MBIM.

The production policy should make the ownership explicit:

- report the PCI physical parent and MHI MBIM ports to ModemManager;
- ignore USB tty ports that are reserved for independent AT telemetry; and
- confirm with `mmcli -m <index>` that the primary/control and data ports belong to the PCIe modem before connecting.

### Missing `mhi-pci-generic` data-driver handling

The `mhi_wwan_mbim` data port may be reported to ModemManager with driver name `mhi-pci-generic`. Upstream commit [`c3ef78cc6c7bc8086f3e2594d434228d92c97356`](https://chromium.googlesource.com/external/gitlab.freedesktop.org/mobile-broadband/ModemManager/+/c3ef78cc6c7bc8086f3e2594d434228d92c97356) adds that driver to ModemManager's MBIM data-port handling.

Without it, affected releases may fail to map the data port back to the MBIM control port, clean up stale data links, or handle bearer multiplexing correctly. Backport the commit or use a release that contains it.

This fix is necessary for robust MHI MBIM management, but it does **not** fix:

- a wrong kernel MHI channel profile;
- an early PCIe/AER failure;
- two processes competing for the MBIM control port;
- an invalid APN, authentication mode, or IP family; or
- a data channel that transmits but never receives.

### False AT-over-QDU detection on the MHI MBIM port

ModemManager 1.24.2's Quectel plugin treats an advertised QDU command CID as
proof that the MBIM port can transport AT commands. On the tested RM520N-GL
PCIe composition, QDU is advertised but Quectel AT commands sent through it do
not receive responses. ModemManager prefers that presumed AT-capable MBIM port
over `wwan0at0`; after ten timeouts it invalidates and removes the modem.

The included r6 patch disables AT-over-MBIM only for Quectel MBIM ports in the
Linux `wwan` subsystem. It preserves USB/usbmisc QDU behavior and allows the
real MHI AT port to be selected. See the
[detailed diagnosis and validation record](modemmanager-wwan-qdu-fix.md).

## Sanitized configuration shapes

These examples show ownership and field shape only. They intentionally contain placeholders and should not be applied blindly.

Native MBIM:

```uci
config interface 'cellular'
        option proto 'mbim'
        option device '/dev/wwan0mbim0'
        option apn '<carrier-apn>'
        option auth '<carrier-auth>'
        # Add username/password only when the carrier requires them.
        option pdptype 'ipv4'
```

ModemManager:

```uci
config interface 'cellular'
        option proto 'modemmanager'
        option device '<physical-pci-sysfs-path>'
        option apn '<carrier-apn>'
        option auth '<carrier-auth>'
        # Add username/password only when the carrier requires them.
        option iptype 'ipv4'
```

For ModemManager, the `device` is the physical modem parent, not `/dev/wwan0mbim0` and not the network-device child. Discover it from sysfs on the target build instead of hard-coding a PCI bus address.

## What is `<wan>_4`?

OpenWrt mobile protocol handlers can create a dynamic child named `<base-interface>_4` for the bearer-provided IPv4 configuration. For example, a base interface named `cellular` may produce `cellular_4`.

It is expected to show a protocol such as static address or DHCP even though the parent is MBIM/ModemManager. It is not a second physical WAN. LuCI may show **Carrier: absent** because the object is virtual and has no Ethernet carrier bit; that status alone does not indicate failure.

Practical rules:

- Do not manually edit or delete the dynamic child while its parent protocol is up.
- Keep the generated `_4` child while the parent uses the mobile protocol; it
  carries the active IPv4 parameters and is needed for that session.
- Do not add a permanent UCI section with the same generated name.
- Point multi-WAN health tracking at the logical interface expected by that package; some OpenWrt tools resolve the base name to its `_4`/`_6` child.
- Judge health using route installation, bound traffic tests, and RX/TX counters, not the virtual carrier label.
- If the parent is intentionally changed to another protocol, bring it down cleanly and let netifd remove/recreate its child.

OpenWrt's own mwan3 discussion documents the `<iface>_4` and `<iface>_6` convention for mobile interfaces: [openwrt/packages issue #16817](https://github.com/openwrt/packages/issues/16817).
