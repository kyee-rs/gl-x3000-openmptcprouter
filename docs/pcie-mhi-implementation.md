# PCIe MHI implementation notes

This is a design record for the image build. It is not a live-module replacement procedure.

## 1. Reuse the upstream Quectel RM5xx profile

Current Linux source defines `mhi_quectel_rm5xx_info` using the Quectel controller configuration. The relevant topology includes:

```c
MHI_CHANNEL_CONFIG_UL(12, "MBIM", 32, 0),
MHI_CHANNEL_CONFIG_DL(13, "MBIM", 32, 0),
MHI_CHANNEL_CONFIG_HW_UL(100, "IP_HW0_MBIM", 128, 2),
MHI_CHANNEL_CONFIG_HW_DL(101, "IP_HW0_MBIM", 128, 3),
```

The profile is visible in [upstream `drivers/bus/mhi/host/pci_generic.c`](https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux.git/+/master/drivers/bus/mhi/host/pci_generic.c).

The GL-X3000 variant can identify as:

```text
vendor:device       17cb:0308
subvendor:subdevice 17cb:5201
```

Add a specific match that points to the existing Quectel profile:

```c
/* GL-X3000 RM520N-GL: Qualcomm identity, Quectel RM5xx channel layout */
{
        PCI_DEVICE_SUB(PCI_VENDOR_ID_QCOM, 0x0308,
                       PCI_VENDOR_ID_QCOM, 0x5201),
        .driver_data = (kernel_ulong_t)&mhi_quectel_rm5xx_info,
},
```

The entry must precede the catch-all `PCI_DEVICE(PCI_VENDOR_ID_QCOM, 0x0308)` entry. PCI device tables use the first matching entry; placing it later silently keeps the generic SDX65 profile.

A concise public implementation is available in the [vjt GL-X3000 PCI-ID patch](https://raw.githubusercontent.com/vjt/openwrt-glinet-x3000/openwrt-25.12/target/linux/generic/pending-6.12/gl-x3000-quectel-pci-id.patch). Adapt its context to the exact kernel source used by the OpenMPTCProuter build rather than applying it with fuzz.

## 2. Include the complete MBIM kernel stack

The image needs the target kernel's own, ABI-matched packages for:

- MHI core and PCI generic host support;
- WWAN core;
- MHI WWAN control;
- MHI WWAN MBIM data; and
- the selected userspace owner (`umbim`, or ModemManager plus its netifd/LuCI integration).

Do not copy `.ko` binaries from another image merely because the visible kernel version matches. OpenWrt kernel modules are coupled to the exact kernel configuration, symbol versions, package ABI, and signing/trust policy. Build the packages from the same source tree and configuration as the final firmware image.

## 3. Apply the PCIe policy before probe

The proposed platform mitigation is:

```text
pcie_port_pm=off
```

Place it in the chosen boot arguments used by the final device tree or another verified early-boot mechanism. A public GL-X3000 OpenWrt implementation does this in the common DTS: [source](https://raw.githubusercontent.com/vjt/openwrt-glinet-x3000/openwrt-25.12/target/linux/mediatek/dts/mt7981a-glinet-gl-x3000-xe3000-common.dtsi).

Trade-off: this is a global PCIe port power-management policy and may increase power use. It should be measured, documented, and narrowed in the future if a device-specific kernel fix becomes available.

Runtime sysfs writes are not a substitute. They occur after PCI enumeration and may arrive after the MHI startup/reset race.

## 4. Treat alternative low-power flags as experiments

Disabling MHI M3 transitions in a custom profile can be a useful diagnostic, but it changes controller behavior and is not the same as protecting the PCIe link during the earliest probe stage. Do not combine an experimental profile and a global boot mitigation in the first acceptance baseline; otherwise the test cannot identify which change mattered.

Recommended baseline:

1. exact upstream Quectel profile;
2. specific GL-X3000 subsystem match;
3. early `pcie_port_pm=off`;
4. upstream `mhi_wwan_mbim`; and
5. native MBIM for the first data-plane proof.

Only add profile-level low-power changes if the baseline still fails and the new hypothesis has its own test matrix.

## 5. Keep modem policy separate from host-driver enablement

Persistent modem settings such as MBN selection, CLAT, IP passthrough/NAT, default APN, USB mode, and PCIe data-interface mode live inside the modem and survive host reflashes. They can affect bearer behavior, but they do not replace the correct host MHI profile.

Before changing any persistent AT setting:

- record its current value;
- confirm the command against documentation for the exact modem firmware;
- make one change at a time;
- know whether it requires a modem reset or full router power cycle; and
- keep recovery access independent of the cellular link.

The [Arachsys GL-X3000 recipe](https://github.com/arachsys-hosts/gl-x3000) documents one publicly tested modem-policy approach. Treat it as a reference, not a universal carrier configuration. APN and IP-family choices remain deployment-specific.

## 6. ModemManager build requirement

If the production image uses ModemManager, include upstream commit [`c3ef78cc6c7bc8086f3e2594d434228d92c97356`](https://chromium.googlesource.com/external/gitlab.freedesktop.org/mobile-broadband/ModemManager/+/c3ef78cc6c7bc8086f3e2594d434228d92c97356) or a newer release containing it. The commit recognizes `mhi-pci-generic` as an MBIM data-port driver.

For ModemManager 1.24.2 on this RM520N-GL MHI composition, also include the
WWAN/QDU guard documented in
[ModemManager WWAN/QDU false-positive fix](modemmanager-wwan-qdu-fix.md).
Without it, advertised QDU support makes the daemon prefer non-working
AT-over-MBIM over the real MHI AT port and eventually discard the modem.

For OpenWrt builds compiled without udev, also review the hotplug scripts that call `mmcli --report-kernel-event`. Ensure any tty exclusion mechanism is deterministic and documented; do not rely on desktop udev rules that are absent from the image.

## 7. Build-time assertions

The build should fail before producing a release if any assertion is false:

- the patch applies with zero fuzz to the intended kernel file;
- the specific PCI subsystem match appears before the generic `0x0308` match;
- the selected device tree's final bootargs contain `pcie_port_pm=off` exactly once;
- `mhi_wwan_mbim` is enabled and packaged for the same kernel ABI;
- the image may contain both native MBIM and ModemManager tooling, but deployment documentation must select exactly one runtime owner;
- generated package repositories use only the version-matched public HTTPS OMR endpoints;
- the first-boot owner guard is present and executable;
- a ModemManager build contains the upstream MHI data-driver fix and the WWAN/QDU guard; and
- public overlays contain no keys, credentials, SIM settings, hostnames, addresses, or unit calibration data.
