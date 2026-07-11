# Sanitized experiment log

This log preserves the useful sequence of experiments while omitting dates, addresses, subscriber data, credentials, firmware identifiers, private artifact names, and infrastructure details. It documents observations, not a production procedure.

## Baseline: generic Qualcomm SDX65 profile

Observed topology:

- PCIe enumeration was stable.
- `mhi_pci_generic` selected the generic `qcom-sdx65m` profile.
- MHI children included control surfaces such as `MBIM` and `QMI`, plus generic data channels such as `IP_HW0`/`IP_SW0` handled by `mhi_net`.
- ModemManager formed an object around a USB AT port and attempted an AT/PPP-style connection rather than using the intended PCIe MBIM data path.

Result:

- connection negotiation failed;
- the failure did not establish whether the radio, MBIM control plane, or PCIe data plane was at fault; and
- the generic profile was not an acceptable final topology because its data channels differed from the Quectel MBIM layout.

## Port-isolation experiment

The competing QMI surface was temporarily removed from consideration so that ModemManager could form a PCIe MBIM-oriented modem object.

Result:

- ModemManager registered and activated a packet bearer;
- an IP configuration was returned; but
- the generic `mhi_net` data interface transmitted without receiving.

Interpretation:

- the original negotiation error included a ModemManager port-selection/grouping problem;
- successful bearer activation did not make the generic data profile correct; and
- an assigned address was not proof of bidirectional data transport.

## MBIM-channel profile experiment

A development profile exposed:

- `MBIM` control channels;
- `IP_HW0_MBIM` data channels; and
- a WWAN netdev driven by `mhi_wwan_mbim`.

Native MBIM userspace successfully registered, attached, activated, and received an IP configuration.

Before the later reboot, an initially stale firewall device mapping prevented
intended egress. After the logical WAN and firewall mapping followed the new
WWAN netdev, transmit counters increased, while receive counters remained at
zero in that pre-reboot observation.

Interpretation:

- firewall/device mapping was one real, independent error;
- it did not explain the remaining zero-RX condition; and
- the exact MBIM topology made control/data ownership clearer, but that test did
  not isolate why receive traffic was still absent.

## Exact Quectel profile with runtime PM pinning

The upstream-style Quectel RM5xx profile was tested while attempting to keep the PCI function and root port in the active power state through sysfs.

Result:

- the modem could enumerate and remain stable temporarily;
- native MBIM could activate and receive an IP configuration;
- data still showed transmit without receive; and
- a modem reset triggered a severe PCIe AER/recovery loop despite the runtime power-control writes.

Interpretation:

- runtime sysfs policy was applied too late to protect all initialization/reset paths;
- a reset exercises a different and more demanding lifecycle path than a warm, already-enumerated connection; and
- the selected next-image hypothesis was to apply PCIe port policy before the
  MHI driver probes and validate it from a clean boot.

## Modem-policy simplification

Persistent modem policy was simplified to remove carrier-specific profile automation and modem-side translation/passthrough behavior while retaining a conventional packet-data configuration.

Result:

- radio registration and packet-service attachment remained available; and
- the pre-reboot host-side zero-RX/PCIe-reset observations were not resolved in
  that test.

Interpretation:

- modem policy can affect APN and address-family behavior and should be documented separately;
- the later successful test included both a reboot and modem-policy changes, so
  their individual causal effects remain unresolved; and
- persistent AT settings must not be bundled into an otherwise unrelated driver experiment.

## Post-reboot development-profile data proof

Following a clean reboot, with the development profile and modem-policy changes
both in place, PCIe MHI enumerated and native MBIM eventually completed
registration, attachment, activation, and IPv4 setup.

Result:

- traffic explicitly bound to the WWAN interface received replies from an external target;
- one bounded test returned all five of five probe packets, and later short
  checks also returned replies;
- both RX and TX packet/byte counters increased; and
- no PCIe AER or MHI recovery error appeared in the bounded log window checked
  around that test.

Interpretation:

- the built-in modem and PCIe MBIM data path are capable of bidirectional traffic;
- the earlier zero-RX observations were not proof of a hardware limitation;
- the development profile remains a local workaround with custom ring and power behavior; and
- this result does not validate the preferred release design, which uses the unmodified upstream Quectel profile plus the early boot argument.

## What was learned from the sequence

Before the final summary, the preferred exact-profile image was booted and its
kernel/MHI topology remained stable. ModemManager r5 initially created the
PCIe object, misclassified its MHI MBIM port as AT-capable because QDU was
advertised, accumulated ten command timeouts, and removed the object. A signed
r6 package with the WWAN/QDU guard was installed without changing the kernel.
The PCIe object then used `wwan0at0`, remained present beyond the prior timeout
window, and produced no new MHI/PCIe recovery event. A separate USB serial
object was visible and was not treated as the PCIe data WAN.

1. The GL-X3000-specific subsystem match must select the existing Quectel RM5xx MHI profile before the generic Qualcomm catch-all.
2. The expected data driver is `mhi_wwan_mbim`; a visible `mhi_net` interface is not an equivalent result.
3. ModemManager needs the upstream `mhi-pci-generic` MBIM data-port fix and must not prefer non-working AT-over-QDU on the MHI MBIM port over `wwan0at0`.
4. Native MBIM is the smaller diagnostic baseline, but it must be stopped before ModemManager is tested.
5. Firewall mappings must follow the new netdev, yet RX must also be proven at the netdev itself before blaming higher layers.
6. The preferred image selects early `pcie_port_pm=off` as its PCIe mitigation;
   post-probe sysfs writes were not a reliable substitute in the observed reset
   path, but the preferred image still requires clean-boot validation.
7. Repeated live driver replacement is a poor experimental method for a controller whose channel layout and event rings are fixed at probe time.
8. A bounded development-profile test proved bidirectional PCIe data; the preferred profile and r6 discovery fix now enumerate correctly, but the rebuilt image remains unqualified until it passes the complete validation matrix.

## Evidence to retain for future tests

For each build, save a sanitized bundle containing:

- source revisions, build configuration, package manifest, and image checksum;
- final device-tree boot arguments;
- PCI identity and selected MHI profile name;
- enumerated MHI channels, WWAN control ports, and netdev driver links;
- connection-manager version and port inventory;
- netifd/ubus interface state and policy routes;
- firewall rules/counters relevant to the cellular logical interface;
- before/after RX and TX counters for each data test; and
- bounded boot/kernel logs covering enumeration, connect, disconnect, and recovery.

Redact subscriber identifiers, phone numbers, SIM data, device serials, MAC addresses, public/private endpoint addresses, tokens, credentials, and carrier-account metadata before committing evidence.
