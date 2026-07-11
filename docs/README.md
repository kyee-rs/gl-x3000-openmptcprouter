# Documentation map

These notes describe a sanitized research path for PCIe cellular support on the GL.iNet GL-X3000 with a Quectel RM520N-GL modem. They are engineering documentation, not a claim that an unvalidated image is production-ready.

- [Research findings](research-findings.md): confirmed facts, lab observations, proposed fixes, and remaining release blockers.
- [Sanitized experiment log](experiment-log.md): what each profile/userspace experiment established and what remains unproven.
- [Architecture](architecture.md): PCIe, MHI, MBIM, netifd, firewall, and multi-WAN layer boundaries.
- [Native MBIM vs ModemManager](native-mbim-vs-modemmanager.md): ownership models, the upstream ModemManager fix, and dynamic `_4` interfaces.
- [ModemManager WWAN/QDU fix](modemmanager-wwan-qdu-fix.md): root cause, package-only validation, and rollback implications.
- [PCIe/MHI implementation](pcie-mhi-implementation.md): exact Quectel profile mapping, early power-management policy, packages, and build assertions.
- [Validation and rollback](validation-and-rollback.md): staged acceptance gates, bidirectional data proof, soak tests, and recovery criteria.
- [Runtime commissioning](runtime-commissioning.md): sanitized LAN bridging, Wi-Fi DHCP, ModemManager, and OMR tunnel integration lessons.
- [MQVPN VPS integration](mqvpn-vps-integration.md): host forwarding, guest firewall/NAT, tunnel naming, verification, and persistence requirements.
- [References](references.md): primary sources and attribution policy.

## Publication boundary

Public commits must not contain router backups, configuration exports, factory/calibration data, subscriber identifiers, modem dumps, credentials, private keys, access tokens, private endpoints, or full logs that may embed those values. Use placeholders in examples and run both automated secret scanning and manual review before publishing.
