# Validation and rollback

The objective is not merely to boot. The objective is to prove a recoverable, bidirectional cellular link that survives normal lifecycle events and cooperates with multi-WAN routing.

## Safety prerequisites

Before flashing any development image:

1. Export a full configuration backup and verify that the archive can be listed and decompressed.
2. Store at least two copies outside the router, in independent locations.
3. Keep the last known-good firmware image and its manifest.
4. Record the model, storage layout, current bootloader version, and supported recovery path.
5. Confirm local wired access and recovery access without relying on cellular or the primary WAN.
6. Preserve device-specific factory/calibration partitions using the platform's documented method. Never publish those dumps.
7. Validate image compatibility with the firmware's supported image-test mechanism before upgrade.

A configuration-preserving sysupgrade is not the same as a factory reset. Even so, a new kernel/network stack can make a preserved configuration incompatible, so both preserved-config and clean-config recovery plans are required.

## Artifact validation before flash

Capture these in the release metadata:

```sh
sha256sum <sysupgrade-image>
```

Also verify:

- the image manifest identifies the intended GL-X3000 target;
- the build source revision and every feed revision are pinned;
- the final kernel and all MHI/WWAN packages share the same ABI;
- the final device tree, not only the source fragment, contains the boot argument;
- the kernel PCI table contains the specific subsystem match before the generic match;
- package signatures are valid under the image's trust policy; and
- a secret scan finds no credentials, private keys, tokens, private endpoints, subscriber identifiers, or factory data.

## Post-boot acceptance gates

Run the gates in order. Stop at the first failure rather than changing several variables at once.

### Gate 0: effective restored state

A config-preserving sysupgrade can overlay files from the previous installation
on top of the new SquashFS. Before testing the modem, inspect the running files,
not only the image:

- every effective APK repository is the intended version-matched HTTPS OMR
  endpoint; a locally changed `customfeeds.list` may be preserved as a
  configuration file;
- native MBIM means ModemManager is disabled and not running before the MBIM
  control port is opened;
- ModemManager mode means its init service is enabled and no native MBIM helper
  owns the control port; and
- restored network, firewall, and multi-WAN sections refer to devices that
  actually exist in the new image.

The included first-boot guard disables ModemManager when any restored interface
uses `proto=mbim`. It intentionally does not rewrite package feeds or enable a
previously disabled service, so those effective-state checks remain explicit.

### Gate 1: early boot and PCIe

Pass conditions:

- `/proc/cmdline` contains `pcie_port_pm=off`;
- the modem PCI function is present with the expected public hardware identity;
- it binds to `mhi_pci_generic` using the Quectel RM5xx profile;
- no repeating AER Completion Timeout, link-retrain, firmware-crash, or MHI recovery loop appears.

Failure action: collect sanitized boot logs, power down, and return to the last known-good image. Do not repeatedly unbind/rebind a failing PCI function over a remote management link.

### Gate 2: MHI/WWAN topology

Pass conditions:

- `MBIM` control channels enumerate;
- `IP_HW0_MBIM` channels enumerate;
- `/dev/wwanNmbim0` exists;
- a WWAN network device exists and its driver resolves to `mhi_wwan_mbim`; and
- the control and data devices share the same PCI ancestor.

Failure action: inspect build configuration and the selected profile. Do not debug APN or firewall rules before this gate passes.

### Gate 3: single-owner control plane

For native MBIM, stop ModemManager. For ModemManager, ensure no `umbim`/MBIM protocol process owns the port.

Pass conditions:

- SIM state and registration can be read without repeated port-open errors;
- packet service attaches;
- one bearer activates;
- the modem returns an address, prefix, gateway, and DNS appropriate to the requested IP family; and
- no competing process resets or closes the session.

An address assignment is only a control-plane pass. Continue to Gate 4.

### Gate 4: bidirectional data plane

Record counters before and after each test:

```sh
ip -s link show dev <wwan-device>
```

Then perform all of the following while explicitly binding traffic to the cellular interface or its policy-routing table:

- reach the bearer gateway when the carrier exposes one;
- reach at least two independent external IP targets;
- resolve DNS through the installed cellular DNS path;
- make an HTTPS request with certificate validation; and
- transfer enough data to make RX and TX counter changes unambiguous.

Pass requires both RX and TX packet/byte counters to increase. A successful MBIM connect plus TX-only counters is a hard failure below the multi-WAN layer.

Use packet capture on the WWAN device and firewall trace/counters to localize loss:

| Observation | Likely layer |
| --- | --- |
| No egress packet on WWAN netdev | routing/firewall before device |
| Egress visible, no RX descriptor/counter increase | MHI/MBIM/PCIe/modem data path |
| RX reaches WWAN netdev but is dropped later | firewall, conntrack, NAT, or policy routing |
| Direct bound traffic works, LAN traffic fails | forwarding/NAT/firewall |
| Native MBIM works, ModemManager does not | daemon version, port grouping, or bearer configuration |

### Gate 5: lifecycle and soak

Minimum release test set:

- repeated cold boots;
- clean connect/disconnect cycles;
- carrier loss and recovery;
- modem reset initiated through the supported control path;
- sustained bidirectional traffic;
- idle period followed by traffic;
- transition between available radio access technologies; and
- multi-WAN fail-away and fail-back while a separate management path remains active.

Record time to recover and check that AER/MHI error counts do not grow. A single successful boot is insufficient.

### Gate 6: ModemManager-specific checks

When ModemManager is selected:

- confirm the modem object uses the PCIe MHI physical parent;
- confirm the control port is MBIM and the data port is the `mhi_wwan_mbim` netdev;
- confirm reserved USB tty ports are either deliberately grouped or deliberately ignored;
- connect, disconnect, and reconnect without stale multiplexed links; and
- repeat Gate 4 after every reconnect.

## Dynamic IPv4 child checks

If netifd creates `<cellular>_4`, verify it contains the modem-provided IPv4 address and routes. A virtual **carrier absent** label is not by itself a failure. The important questions are:

- is the parent cellular protocol up;
- is the `_4` child present in ubus;
- are its routes in the expected table;
- do firewall and multi-WAN rules refer to the active logical interface; and
- does bound bidirectional traffic pass?

Do not create a second persistent UCI interface with the generated name.

## Rollback decision tree

1. **Image rejected before flash:** stop; fix target metadata or image format. Do not force-write it.
2. **Router boots, cellular fails, management works:** capture sanitized evidence, perform one controlled rollback to the last known-good image, and restore the matching configuration if required.
3. **AER storm or repeated modem recovery:** stop experimentation, fully power down if the recovery procedure calls for it, then roll back. Runtime module swapping is not a recovery plan.
4. **Router does not complete normal boot:** use the previously verified local bootloader/recovery path and known-good image.
5. **Preserved configuration prevents networking:** boot the known-good image with a clean configuration, then restore only reviewed sections from the backup.

Never publish backups, factory partitions, modem dumps, full logs containing subscriber identifiers, or raw configuration archives. Redact at collection time and review again before committing.
