# ModemManager WWAN/QDU false-positive fix

This note documents a ModemManager 1.24.2 failure reproduced with the
GL-X3000's PCIe Quectel RM520N-GL. All unit-specific identifiers, subscriber
data, carrier settings, credentials, and private infrastructure details have
been omitted.

## Symptom

The kernel side was healthy: the PCI function remained bound to
`mhi-pci-generic`, the Quectel RM5xx profile exposed `MBIM` and
`IP_HW0_MBIM`, and `/dev/wwan0mbim0`, `/dev/wwan0at0`, and `wwan0` remained
present. ModemManager briefly created a PCIe modem object and detected the SIM,
but `mmcli -L` became empty after initialization.

Debug logging showed that the Quectel MBIM port advertised
`MBIM_SERVICE_QDU` / `MBIM_CID_QDU_COMMAND`. ModemManager therefore classified
the MBIM port as AT-capable and preferred AT-over-MBIM over the real
`wwan0at0` port. The modem did not answer Quectel AT commands transported over
QDU on this MHI composition. After ten consecutive MBIM command timeouts,
ModemManager marked the modem invalid and removed the object.

This is independent of the `mhi-pci-generic` data-port association fixed by
upstream commit `c3ef78cc6c7bc8086f3e2594d434228d92c97356`. Both fixes are
required by the pinned ModemManager 1.24.2 build.

## Source path

The false-positive originates in
`src/plugins/quectel/mm-port-mbim-quectel.c`: advertised QDU command support is
treated as proof that AT-over-QDU works. Core modem selection then prefers an
AT-capable MBIM port over a serial AT port.

The build-kit patch makes Quectel MBIM ports in the Linux `wwan` subsystem
report AT-over-MBIM as unsupported. ModemManager then uses the real MHI AT
port. USB `usbmisc` behavior is unchanged, so Quectel devices that genuinely
support AT-over-QDU on USB retain it.

See
[`011-quectel-disable-at-over-mbim-on-wwan.patch`](../patches/modemmanager/011-quectel-disable-at-over-mbim-on-wwan.patch).

## Live validation

The patch was first built as a signed `modemmanager-1.24.2-r6` package and
installed over the image's r5 package without replacing the kernel or
reflashing. The tested package had SHA-256:

```text
7597609e2cf7a3849e9ddb6e4a2ecd12b4eb5bf89b1b4348eb801c0937e0e14a
```

Observed after the upgrade:

- the compiled binary contained both `mhi-pci-generic` and
  `AT over MBIM disabled on WWAN port`;
- the PCIe object used `mhi-pci-generic` and the Quectel plugin;
- its ports included `wwan0mbim0 (mbim)`, `wwan0at0 (at)`, and `wwan0 (net)`;
- the object remained present beyond the previous timeout window;
- the previous ten-timeout invalidation did not recur; and
- MHI probe/attach counts were unchanged, with no detach, AER, `SYS_ERR`,
  `RDDM`, slot-reset, or link-down event.

A second ModemManager object for the module's USB serial surface may also be
visible. It is not the PCIe data WAN. Runtime configuration should select the
object whose physical parent is the PCI function and whose ports include the
MHI MBIM and WWAN network devices.

This test validates discovery, port selection, and object persistence. It does
not replace the separate requirements for APN/SIM provisioning, bidirectional
traffic, reconnect, cold-boot, and multi-WAN failover testing.

## Build and rollback implications

The feed package release is bumped from r4 to r6 because r5 carried the
`mhi-pci-generic` association backport and r6 adds the WWAN/QDU guard. The full
image validator requires both marker strings in the installed ModemManager
binary and requires the r6 APK to exist in build output.

For package-only testing, retain the exact signed r5 APK before upgrading so
the package database and overlay files can be rolled back together. Removing
individual overlay binaries is not a coherent rollback.
