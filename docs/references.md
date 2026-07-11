# References and attribution

Primary and closely related public sources used for this research:

- Linux kernel documentation: [MHI overview, states, channels, and data transfer](https://www.kernel.org/doc/html/latest/mhi/mhi.html)
- Linux kernel source: [`drivers/bus/mhi/host/pci_generic.c`](https://kernel.googlesource.com/pub/scm/linux/kernel/git/torvalds/linux.git/+/master/drivers/bus/mhi/host/pci_generic.c)
- ModemManager upstream fix: [`broadband-modem-mbim: handle mhi-pci-generic as a valid data port driver`](https://chromium.googlesource.com/external/gitlab.freedesktop.org/mobile-broadband/ModemManager/+/c3ef78cc6c7bc8086f3e2594d434228d92c97356)
- ModemManager developer discussion: [`mhi-pci-generic` and multiplexing](https://www.mail-archive.com/modemmanager-devel%40lists.freedesktop.org/msg08010.html)
- Public GL-X3000 OpenWrt fork: [vjt/openwrt-glinet-x3000](https://github.com/vjt/openwrt-glinet-x3000)
- Public GL-X3000 build guide: [vjt `x3000/README.md`](https://github.com/vjt/openwrt-glinet-x3000/blob/openwrt-25.12/x3000/README.md)
- Public GL-X3000 exact PCI-ID patch: [`gl-x3000-quectel-pci-id.patch`](https://raw.githubusercontent.com/vjt/openwrt-glinet-x3000/openwrt-25.12/target/linux/generic/pending-6.12/gl-x3000-quectel-pci-id.patch)
- Public GL-X3000 early PCIe PM bootarg: [common DTS](https://raw.githubusercontent.com/vjt/openwrt-glinet-x3000/openwrt-25.12/target/linux/mediatek/dts/mt7981a-glinet-gl-x3000-xe3000-common.dtsi)
- Independent GL-X3000 build and modem recipe: [arachsys-hosts/gl-x3000](https://github.com/arachsys-hosts/gl-x3000)
- OpenWrt mobile dynamic child behavior: [openwrt/packages issue #16817](https://github.com/openwrt/packages/issues/16817)

## Attribution policy

Do not copy substantial source files into this repository without preserving their original license and attribution. Prefer a small, reviewable patch against pinned upstream source. Any included patch should identify its upstream source or inspiration and retain applicable `Signed-off-by`, copyright, and SPDX information.

Public source links describe other projects' designs; they do not imply endorsement of this image or guarantee compatibility with an OpenMPTCProuter snapshot. Revalidate every patch against the exact pinned kernel and userspace versions.
