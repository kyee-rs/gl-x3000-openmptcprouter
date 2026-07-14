# GL-X3000 OpenMPTCProuter PCIe/MBIM build kit

This directory builds a pinned OpenMPTCProuter snapshot for the GL.iNet
GL-X3000 with the built-in Quectel RM520N-GL on its native PCIe MHI/MBIM
path. It is a source-only build kit: it does not contain modem firmware,
vendor binaries, router configuration, credentials, carrier settings, or
backup data, and it never connects to or flashes a router.

## Project status

This is an R&D build kit, not a production firmware release. The pinned image
recipe has passed offline checks for target metadata, device-tree arguments,
kernel topology, package contents, and the ModemManager patches. The preferred
kernel combination—upstream Quectel RM5xx profile plus early PCIe port-PM
disable—has booted on real hardware with stable MHI/MBIM enumeration. The
ModemManager r6 package has also passed live discovery and persistence testing.
Reset, repeated cold boot, sustained RX/TX, reconnect, and multi-WAN validation
are still required before this should be called stable.

A separate development profile proved that the built-in modem can carry
bidirectional PCIe/MBIM traffic. That experimental channel table is documented
for research context but intentionally excluded from this build kit.

The build carries nine narrowly scoped integration fixes:

1. Match PCI ID `17cb:0308`, subsystem `17cb:5201`, to the existing upstream
   `mhi_quectel_rm5xx_info` profile. This exposes `MBIM` control and
   `IP_HW0_MBIM` data channels through the in-tree drivers.
2. Append `pcie_port_pm=off` in the GL-X3000 device tree so PCIe port power
   management is disabled from early boot, before the modem initializes.
3. Backport upstream ModemManager commit
   `c3ef78cc6c7bc8086f3e2594d434228d92c97356`, which recognizes
   `mhi-pci-generic` as the data-port driver used by `mhi_wwan_mbim`.
4. Disable Quectel AT-over-QDU selection on Linux `wwan` MBIM ports. The
   RM520N-GL advertises QDU on PCIe MHI but does not answer AT commands through
   it; the guard makes ModemManager use the real MHI AT port instead.
5. Correct the pinned OMR BBRv3 patch for Linux 6.18's two-argument
   `div_u64()` API so clean target builds compile successfully.
6. Generate version-matched HTTPS package feeds instead of embedding a build
   host or an outdated plaintext feed path.
7. Include a first-boot ownership guard: if any preserved interface uses native
   MBIM, it disables ModemManager before the daemon can compete for a control
   port. Otherwise an explicit ModemManager interface does not disable it.
8. Keep ModemManager-backed MPTCP endpoints synchronized after cellular address
   renewals, including netifd dynamic interfaces such as `wan2_4`.
9. Migrate OMR's video-chat firewall sets to fw4 address-and-port tuples and
   update their DSCP rules to reference the resulting nft sets.

No experimental hybrid channel table or `no_m3` profile is included.

## Build

Install Docker, allocate at least 40 GiB of free disk space, then run:

```sh
make build JOBS=8
```

The first build downloads pinned source trees and can take a long time.
Downloaded sources and intermediate objects stay in `.build/`; the verified
sysupgrade image, SHA-256 file, validation report, and build manifest are
written to `dist/`.

`.build/` is disposable. Each new `make build` or `make prepare` resets and
cleans the dedicated source clones before applying this kit, which prevents a
stale experimental patch from leaking into a later image. Use a separate
worktree for any source changes you want to keep.

The firmware source revisions are pinned, but this is not yet a claim of
byte-for-byte reproducibility: the Debian base tag, Debian package repository,
and parts of the upstream build banner can change over time. Treat every output
as a new candidate, record its checksum, and rerun the complete validation
matrix.

For a quick source/patch preparation without compiling:

```sh
make prepare
```

After a build, validation can be repeated with:

```sh
make validate
```

## Scope and runtime choice

The ModemManager patches fix MBIM data-port association and the RM520N's false
AT-over-QDU selection. They do not turn
an unrelated USB AT-only/PPP modem object into the PCIe modem. A runtime WAN
must select the PCIe MHI/MBIM device. Native netifd `proto=mbim` remains a
valid alternative and does not require ModemManager to own the control port.
If neither protocol is configured yet, the ownership guard remains pending so
it can decide after a later configuration restore.

The guard is deliberately global for this single-built-in-modem target: native
MBIM wins if both protocol types appear anywhere in the restored network
configuration. It does not enable a previously disabled ModemManager service
and it is not a per-port policy for multi-modem installations. Confirm the
effective service state and package repositories after every config-preserving
upgrade.

This project intentionally stops at image construction and offline
validation. Flashing, modem provisioning, APN selection, SIM unlocking, and
WAN configuration are separate deployment steps.

## Research notes

- [Findings and confidence labels](docs/research-findings.md)
- [Sanitized experiment sequence](docs/experiment-log.md)
- [Cellular architecture](docs/architecture.md)
- [Native MBIM versus ModemManager](docs/native-mbim-vs-modemmanager.md)
- [ModemManager WWAN/QDU false-positive fix](docs/modemmanager-wwan-qdu-fix.md)
- [PCIe/MHI implementation notes](docs/pcie-mhi-implementation.md)
- [Validation and rollback gates](docs/validation-and-rollback.md)
- [Runtime commissioning lessons](docs/runtime-commissioning.md)
- [MQVPN VPS integration](docs/mqvpn-vps-integration.md)
- [Primary references](docs/references.md)

## Pinned inputs

All audited revisions are recorded in `manifest.lock`. The validation script
checks the OpenMPTCProuter, feed, and OpenWrt revisions; compiled device-tree
boot arguments; kernel module PCI alias and channel profile; absence of the
experimental hybrid profile and installed `mhi_net`; the ModemManager
backport; and the final sysupgrade archive.

## License

Original repository material is provided under GPL-3.0. Included patches retain
their upstream provenance and applicable upstream licensing. See `LICENSE` and
the patch headers.
