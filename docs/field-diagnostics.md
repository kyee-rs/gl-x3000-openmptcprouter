# Sanitized field diagnostics

This record covers a live diagnostic session on a commissioned deployment
running the release image against a rebuilt exit node. It documents observed
regressions, their measurements, and the remedies applied. Addresses,
identifiers, operator data, and credentials are omitted.

Symbolic names follow [MQVPN VPS integration](mqvpn-vps-integration.md):

```text
WIRED_WAN     lower-latency wired uplink, MPTCP master
CELL_WAN      cellular uplink on the PCIe MHI data path
TUNNEL_IF     MQVPN tunnel device
LIBVIRT_BRIDGE bridge of the isolated exit-node network
```

The presenting complaint was intermittent slowness rather than a hard outage.
Both trackers reported `up` throughout, and no WAN transition was logged in the
preceding nineteen hours, so tracker state was not a useful starting signal.

## 1. Tracker post-tracking fork amplification

The main loop calls every hook in the post-tracking directory on each
iteration. Each hook runs in a subshell and again inside a command
substitution, and the hooks themselves invoke configuration and status
utilities repeatedly.

Measured on the two-core target at idle, carrying about 33 kbps:

| Quantity | Value |
|---|---|
| Process creations | 225 per second |
| Cumulative creations | 10.7 million over 19.5 hours |
| Child CPU, wired tracker | 17.4% of one core |
| Child CPU, cellular tracker | 19.1% of one core |
| Child CPU, tunnel tracker | 14.2% of one core |
| Combined, including service manager | about 34% of the machine |

The cost is invisible to per-process sampling because it lands in short-lived
children; it is only attributable through the parent's accumulated child times.

Under load the effect compounds. During a tunnel transfer the machine held
98-100% busy while tunnel throughput oscillated between 8 and 61 Mbps.

Remedy: raise the healthy-poll interval. Detection latency is governed by the
retry count and retry interval, not by the healthy-poll interval, so failover
responsiveness is materially unchanged. Interval 5 to 15 seconds on the WAN
trackers and 5 to 10 on the tunnel tracker gave:

| Quantity | Before | After |
|---|---|---|
| Process creations | 225/s | 62/s |
| Idle busy time | about 34% | about 19% |
| One-minute load average | 2.79 | 0.62 |

No hook was disabled and no vendor script was modified. Disabling individual
hooks was measured first and rejected: single-hook deltas were not reproducible
across 15-second windows because each tracker completes only about nine
iterations in that period.

## 2. Radio access technology correlates with the MHI zero-RX condition

[The experiment log](experiment-log.md) records zero-RX observations on the
PCIe data path and attributes them to profile, driver, and power-management
causes. This session adds a further correlation on an image where the data
path is otherwise healthy.

Observed topology: one physical module presenting two connection-manager
objects that share a single equipment identity.

| Object | Bus | Driver | Ports | Advertised modes |
|---|---|---|---|---|
| PCIe object | PCIe | `mhi-pci-generic` | MHI net, MBIM, MHI AT | includes 5GNR |
| USB object | USB | serial | AT and GPS only, no net port | LTE only |

The logical cellular WAN binds to the PCIe device path, so the data interface
belongs to the PCIe object and is the only object that advertises 5GNR.

Result:

- restricted to LTE, the link ran continuously for over nineteen hours;
- with 5GNR permitted and preferred, registration succeeded, signal quality
  improved, and the bearer reported connected with a valid address, gateway,
  and resolvers;
- the interface then transmitted without receiving, and the tunnel path built
  on it showed a transmit counter advancing against a zero receive counter with
  a smoothed round-trip time of zero; and
- the condition recurred three times within minutes of each attempt.

Interpretation:

- an address, a route, and a connected bearer are not proof of a working
  receive path, consistent with the earlier log entries;
- on this image the zero-RX condition tracks the selected radio access
  technology rather than the firewall or the logical interface mapping; and
- LTE-only remains the supported configuration for the PCIe data path.

This matches the upstream report for the same module and driver in
[OpenMPTCProuter issue 4030](https://github.com/Ysurac/openmptcprouter/issues/4030),
where the maintainer confirms running the module over USB with MBIM and LTE.

### Mode changes can wedge the module

Because two objects wrap one radio, a connection-manager invocation that
selects "any" modem is ambiguous, and a mode change may reach a different
control channel than the one owning the data path.

After repeated mode changes the module returned a generic equipment failure on
connect, reported itself disabled and detached, and remained SIM-locked after a
successful enable. The module does not support the manager's reset operation,
so recovery required a full power cycle. A related upstream defect is that
automatic re-registration can silently discard a previously applied mode
selection, which encourages exactly this retry loop.

Guidance:

- address the intended object explicitly; never use the "any" selector on this
  composition;
- change radio access technology from a clean boot, not on a live bearer; and
- keep recovery access independent of the cellular link, because the only
  reliable recovery is a power cycle.

## 3. Host guest-input rule ordering regresses after a libvirt reconnect

[MQVPN VPS integration](mqvpn-vps-integration.md) requires narrow accept rules
in the virtualization host's guest-input chain, ahead of the hypervisor's
rejection rule. The forwarding helper inserts them at the head of the chain,
which is correct at the time it runs.

Observed: the hypervisor had since recreated its own established-state accept
and blanket rejection for the guest bridge. Those recreated rules were placed
above the helper's rules, leaving the narrow accepts below the rejection.

Consequence, and why it is easy to miss:

- the established-state accept still matched the long-lived tunnel session, so
  an existing tunnel kept working indefinitely, with millions of packets
  counted; while
- every new handshake matched the rejection first, with thousands of packets
  counted on the reject rule.

The deployment therefore could not re-establish its tunnel after any restart,
reboot, or link event, and the only thing masking it was an old connection
tracking entry. The failure surfaced the moment the tunnel client was
restarted, presenting as a stalled handshake on every path.

Remedy: re-run the forwarding helper, which removes its previous rules and
reinserts them at the head of the chain. Verify ordering explicitly rather than
verifying presence.

Add to routine verification: confirm the narrow accepts appear **above** the
rejection, not merely that they exist. Presence alone is not sufficient, and a
tunnel that is currently up is not evidence that the ordering is correct.

## 4. Tunnel interface protocol drift

The tunnel logical interface must use the unmanaged protocol because the tunnel
client assigns the point-to-point address itself. The deployment had drifted to
a managed protocol that runs a client requesting a lease.

Result: the address was present and correct on the device and traffic flowed,
but the logical interface stayed pending and never came up, because no server
answers that request. This is the documented device or protocol mismatch
signature, where the internet works while the tunnel is reported down.

Remedy: set the unmanaged protocol, reload, and restart the tunnel client. The
lease client then exits and the logical interface reports up.

## 5. Active queue management evaluated and rejected

Worst-case latency under load was investigated after the tracker remedy. Note
that the tunnel scheduler delivers several copies of each probe, so raw
round-trip statistics count late duplicates; judge latency by the first copy
per sequence.

An alternating A/B of egress shaping on the wired uplink, two rounds each:

| Configuration | Throughput | Worst-case latency |
|---|---|---|
| Shaping enabled | 30 and 38 Mbps | 150 and 162 ms |
| Shaping disabled | 27 and 28 Mbps | 162 and 152 ms |

Packet loss was identical with shaping enabled and disabled, so the shaper was
not responsible for it.

Ingress shaping with an adaptive rate estimator was actively harmful: the
estimator hunted across a wide range and cut throughput to about 21 Mbps
without a corresponding latency benefit.

Interpretation: a wired uplink whose capacity varies by a factor of four cannot
be shaped usefully at a fixed rate, and the adaptive estimator did not converge
on this link. Shaping was left disabled. Most of the original latency was
contention for a saturated processor, not queue depth, and it resolved with the
tracker remedy.

## 6. Revalidation after the changes

Continuity was re-proven with a temporary packet black hole on the tunnel port,
applied in a separate table that removes itself, so that no interface or modem
state was disturbed. Judge these by unique sequence numbers.

| Test | Unique sequences | Loss |
|---|---|---|
| Cellular path black-holed, 20 s | 70 of 70 | 0% |
| Wired path black-holed, 20 s | 69 of 70 | one packet at transition |

Session totals, wired uplink capacity varying throughout:

| Quantity | Before | After |
|---|---|---|
| Tunnel throughput | 13.9 Mbps | 58.6 Mbps |
| Latency under load, first copy per sequence | 926 ms | 30.7 ms mean, 44.9 ms peak |
| Idle busy time | about 34% | about 19% |

## What to carry into the next commissioning

1. Tracker state reporting `up` does not exclude a processor-contention fault;
   measure process-creation rate before trusting the tracker layer.
2. Verify host guest-input rule ordering, not just rule presence, and re-verify
   after any hypervisor or host network restart.
3. Confirm the tunnel logical interface reports up, not merely that traffic
   flows, so protocol drift is caught.
4. Restrict the PCIe data path to LTE, and treat any radio access technology
   change as a clean-boot operation on an explicitly addressed object.
5. Prove a receive counter, never an assigned address, when judging a cellular
   data path.
