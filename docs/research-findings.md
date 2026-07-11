# GL-X3000 cellular research findings

This document records sanitized engineering findings for the GL.iNet GL-X3000 (Spitz AX) and its Quectel RM520N-GL modem. It contains no unit-specific identifiers, credentials, carrier account data, addresses, or private infrastructure details.

## Result in one paragraph

PCIe cellular support is feasible with the upstream Linux MHI/WWAN stack; a proprietary driver is not inherently required. The important pieces are: map the GL-X3000 modem's Qualcomm PCI subsystem identity to Linux's existing Quectel RM5xx profile, expose the `MBIM` control channels and `IP_HW0_MBIM` data channels, load `mhi_wwan_mbim`, prevent the PCIe root port from entering a problematic low-power transition during early MHI startup, and give exactly one userspace connection manager ownership of the MBIM control port. ModemManager also needs its upstream `mhi-pci-generic` data-port fix when using a release that predates it. A build is not considered working until bidirectional traffic, reconnect, and repeated cold boot tests pass.

## Confidence labels

- **Upstream fact**: directly supported by upstream code or project documentation.
- **Lab observation**: reproduced on a GL-X3000-class test unit, with identifying details removed.
- **Proposed fix**: supported by public working implementations but still needs validation in the target OpenMPTCProuter image.
- **Open question**: not yet proven end to end.

## Findings

| Area | Finding | Confidence |
| --- | --- | --- |
| PCI identity | Some GL-X3000 RM520N-GL units present as Qualcomm `17cb:0308` with subsystem `17cb:5201`, so the broad SDX65 match selects the generic Qualcomm profile unless a more-specific entry appears first. | Upstream/public implementation |
| Correct MHI topology | Linux's Quectel RM5xx profile exposes `MBIM` control channels 12/13 and `IP_HW0_MBIM` hardware data channels 100/101. | Upstream fact |
| Control and data drivers | The `MBIM` 12/13 channels are consumed by `mhi_wwan_ctrl`, which exposes the MBIM character device. `IP_HW0_MBIM` 100/101 is consumed by `mhi_wwan_mbim`, which exposes the WWAN network device. This is not the same data path as generic raw-IP `mhi_net`. | Upstream fact |
| Generic profile behavior | A generic SDX65-style profile can enumerate control ports while exposing a data topology that does not match the modem's intended MBIM data path. Successful registration alone therefore does not prove a usable link. | Lab observation |
| PCIe power management | Runtime PCIe power management can race MHI startup/reset on this platform. Applying `power/control=on` after boot is too late to protect early enumeration. | Lab observation plus public working implementation |
| Early boot mitigation | A public GL-X3000 OpenWrt implementation places `pcie_port_pm=off` in the kernel boot arguments so the root port cannot enter the problematic transition during startup. | Proposed fix |
| Native MBIM | A native MBIM manager can register, attach, activate, and receive an IPv4 configuration when the correct MHI profile is present. | Lab observation |
| ModemManager selection | When USB AT ports and PCIe MHI ports are visible at the same time, an older or incorrectly integrated ModemManager can group/select the wrong surface and attempt an AT/PPP-style connection instead of PCIe MBIM. | Lab observation |
| ModemManager MHI handling | Upstream ModemManager commit `c3ef78cc6c7bc8086f3e2594d434228d92c97356` recognizes `mhi-pci-generic` as a valid MBIM data-port driver. Older builds may mishandle data-port lookup, stale links, or multiplexing. | Upstream fact |
| Dynamic IPv4 interface | OpenWrt mobile protocol handlers may create `<logical-name>_4` as the IPv4 child interface. It is a netifd object, not another modem or physical port. | Upstream/OpenWrt behavior |
| Development-profile data proof | After a clean reboot with the simplified modem policy, a development MBIM profile completed a native MBIM session and passed bound external traffic with both RX and TX counters increasing. This proves that PCIe cellular data is feasible on the hardware, but it does not validate the final exact-profile image. | Lab observation |
| Target-image status | The final design uses the upstream Quectel profile plus the early boot argument, a combination not yet boot-tested in this research sequence. It must independently prove RX, resets, reconnects, and cold boots before release. | Open question |

## What the failure was not

- It was not evidence that the SIM could not register. Radio registration and packet-service attachment are distinct from host-side MHI and MBIM data transport.
- It was not solved by receiving an IP address. MBIM control success can coexist with a broken data channel.
- It was not safe to diagnose by repeatedly swapping live kernel modules. MHI profiles define controller channels and event rings at probe time, and PCIe error recovery may require a full cold restart.
- It was not proof that a proprietary binary driver is required. Mainline Linux contains the needed Quectel MBIM channel model; the device-specific PCI match and platform startup behavior are the missing integration pieces.

## Release blockers

Do not describe an image as working until all of these are true:

1. The kernel command line contains the intended early PCIe power-management policy.
2. The PCI function binds to the Quectel RM5xx profile, not the generic SDX65 profile.
3. Both an MBIM control port and an `mhi_wwan_mbim` network device appear.
4. One, and only one, connection manager owns the MBIM control port.
5. The link receives as well as transmits traffic.
6. Carrier reconnect, modem reset, repeated cold boot, and sustained traffic tests pass without AER storms or MHI recovery loops.
7. Multi-WAN health checks use the real cellular child interface and can fail away and return without interrupting management access.

## Public references

- [Linux MHI documentation](https://www.kernel.org/doc/html/latest/mhi/mhi.html)
- [Linux `mhi_pci_generic` source: Quectel MBIM channels and RM5xx profile](https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux.git/+/master/drivers/bus/mhi/host/pci_generic.c)
- [Public GL-X3000 OpenWrt implementation](https://github.com/vjt/openwrt-glinet-x3000/tree/openwrt-25.12/x3000)
- [Specific GL-X3000 PCI-ID mapping patch](https://raw.githubusercontent.com/vjt/openwrt-glinet-x3000/openwrt-25.12/target/linux/generic/pending-6.12/gl-x3000-quectel-pci-id.patch)
- [Independent GL-X3000 build recipe and modem notes](https://github.com/arachsys-hosts/gl-x3000)
- [ModemManager `mhi-pci-generic` MBIM data-port fix](https://chromium.googlesource.com/external/gitlab.freedesktop.org/mobile-broadband/ModemManager/+/c3ef78cc6c7bc8086f3e2594d434228d92c97356)
