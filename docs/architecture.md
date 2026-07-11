# Cellular architecture

The cellular path crosses several independent layers. A green status at one layer does not prove that the next one works.

```text
RM520N-GL modem
  │ PCIe function + subsystem identity
  ▼
MediaTek PCIe root port
  │ early boot PM policy (`pcie_port_pm=off` candidate)
  ▼
`mhi_pci_generic`
  │ exact Quectel RM5xx channel/event profile
  ├── `MBIM` channels 12/13 ───────► MHI WWAN control ─► /dev/wwanNmbim0
  └── `IP_HW0_MBIM` 100/101 ──────► `mhi_wwan_mbim` ──► wwanN
                                                │
                     exactly one owner          │
                 ┌──────────────────────────────┘
                 ▼
        native MBIM or ModemManager
                 │ address, routes, DNS
                 ▼
       netifd logical WAN + `<wan>_4`
                 │ firewall/NAT/policy routing
                 ▼
          OpenMPTCProuter multi-WAN
```

Names such as `wwan0` are examples. Scripts should discover the actual devices through sysfs and netifd rather than assume enumeration order.

## Layer 1: PCIe identity and platform startup

The modem can use Qualcomm's vendor/device identity while retaining a Quectel-specific subsystem identity. Linux walks `mhi_pci_generic`'s PCI ID table in order, so a specific subsystem match must precede the generic Qualcomm SDX65 entry.

The root port's power policy is also part of device enablement. A userspace write after the driver has probed cannot repair a race that occurred during early MHI initialization. The proposed image therefore sets the policy in boot arguments and verifies it through `/proc/cmdline` immediately after boot.

## Layer 2: MHI controller profile

The controller profile is not just a device label. It defines logical channels, event rings, directions, queue sizes, and low-power behavior. For the intended MBIM path, the important channels are:

| Channel pair | Purpose | Expected consumer |
| --- | --- | --- |
| 12/13, `MBIM` | MBIM control messages | MHI WWAN control driver |
| 100/101, `IP_HW0_MBIM` | MBIM packet data | `mhi_wwan_mbim` |
| 4/5, `DIAG` | Diagnostics | Optional diagnostic tooling |
| 32/33, `DUN` | Serial/data utility channel | Optional; not the MBIM packet path |

The existing upstream `mhi_quectel_rm5xx_info` uses the Quectel channel/event configuration. Reusing that implementation is preferable to maintaining a second, nearly identical profile.

## Layer 3: kernel WWAN devices

A correct probe should expose both sides of MBIM:

- a character device such as `/dev/wwan0mbim0` for control messages; and
- a network device such as `wwan0` for packet data.

Seeing only the control device means the data driver or data channel is absent. Seeing a generic `mhi_net` interface is not equivalent to seeing `mhi_wwan_mbim`; the framing and userspace expectations differ.

## Layer 4: one userspace owner

Choose one of these connection managers for a given MBIM control port:

- OpenWrt's native `proto=mbim` path, backed by `umbim`; or
- ModemManager, exposed to netifd through `proto=modemmanager`.

Do not run both on `/dev/wwanNmbim0`. Concurrent open/reset/connect operations create misleading negotiation failures and can tear down a bearer that the other process created. Separate AT monitoring can coexist only when it uses a deliberately excluded, independent port.

## Layer 5: netifd, firewall, and policy routing

The base logical interface owns modem lifecycle. Its generated `<name>_4` child owns the IPv4 address and routes for protocol handlers that split address families. Firewall and multi-WAN logic must follow the effective logical interface/device rather than a stale former netdev name.

An assigned address proves the control plane reached IP configuration. It does not prove:

- receive descriptors complete;
- packets traverse the firewall;
- source NAT is correct;
- policy routing selects the intended table; or
- health tracking follows the generated IPv4 child.

Validation therefore checks counters and packets at every boundary.

## Expected device invariants

The exact paths vary, but a healthy system should satisfy these relationships:

```sh
# The PCI function is bound to mhi-pci-generic.
readlink -f /sys/bus/pci/devices/*/driver

# The MBIM control port and WWAN netdev share the same physical PCI ancestor.
readlink -f /sys/class/wwan/wwan*/device
readlink -f /sys/class/net/wwan*/device

# The data netdev is driven by mhi_wwan_mbim.
readlink -f /sys/class/net/wwan*/device/driver
```

These are inspection examples, not a script: wildcards can match unrelated devices and should be narrowed before automation.
