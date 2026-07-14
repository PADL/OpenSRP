# OpenSRP

OpenSRP is an implementation of the 802.1Q SRP suite of protocols: MMRP, MVRP and MSRP. They are used in AVB/TSN networks to coordinate stream reservations amongst Ethernet bridges.

OpenSRP is supports bridging with the standard Linux kernel interfaces for forwarding entries and traffic control queueing. It also has a builtin REST server for mangement.

## Architecture

* NetLink: Swift structured concurrency wrapper around `libnl-3` (this has now been split into a [separate package](https://github.com/PADL/NetLinkSwift))
* IEEE802: shared types and serialization APIs
* MRP: abstract state machine, platform abstraction layer
* MRPDaemon: MRP daemon
* PMC: PTP management client library
* MSTP: native Swift client for the `mstpd` control socket

The netlink port snapshot gives the per-port Forwarding *state* used to gate declarations (802.1Q 35.1.3.1), but not the spanning-tree *role*. For that `mrpd` polls `mstpd` over its control socket (the MSTP module is a pure-Swift, non-blocking client that links no GPL code), and uses the role to drive MRP topology-change events: Flush! on a Root/Alternate→Designated transition (10.7.5.2) and Re-declare! on Designated→Root/Alternate (10.7.5.3). Bridges without `mstpd` simply never see a role change and skip this path.

MMRP, MVRP, and MSRP are "applications" of the generalized MRP protocol and state machine. Aplications are responsible for responding to MRP registrations (e.g. by adding a FDB entry) and also propagating MRP declarations to other bridge ports.

Note that whilst OpenSRP does have a platform abstraction layer, the initial platform is Linux, and we would prefer to push switch-specific functionality into the kernel rather than separate platform backends.

Note: `mrpd` is the sole MVRP entity on the bridge. Each port's statically configured VLANs — its tagged VLANs and its PVID (802.1Q 11.2.1.3), minus any passed with `--exclude-vlan` — are held as *Registration Fixed* (802.1Q 8.8.2, 10.7.2): the registration ignores peer Leaves, and MAP propagation declares the VLAN out the other bridge ports, so peers learn the bridge's membership without waiting for an inbound declaration (this matters when ingress filtering is enabled, and for interoperability). Configure the desired VLANs with `bridge vlan add` (static VLANs added or removed at runtime are picked up automatically), including the SR class VLAN — the SR_PVID named by the MSRP Domain declarations (both SR classes share the one SR_PVID, 802.1Q 35.2.1.4; override the default VID 2 with `--sr-p-vid`).

To distinguish an administrator's static VLAN from one `mrpd` itself added for a peer's dynamic registration, `mrpd` marks its own entries with the `BRIDGE_VLAN_INFO_DYNAMIC` flag (a small kernel patch; `bridge vlan` shows such entries as `dynamic`). Kernels **without** this flag silently ignore it; `mrpd` still tracks its own additions in-process, so behaviour is identical with one exception: after an `mrpd` restart, dynamic entries left in the kernel by the previous run cannot be told apart from static configuration and will be promoted to Registration Fixed (and thus survive the peer's Leave) until they are removed manually or the bridge is reconfigured. On patched kernels leftover dynamic entries are recognised and remain dynamic across restarts.

Because `mrpd` runs its own MVRP applicant/registrar and performs attribute propagation itself, do **not** also enable the Linux in-kernel MVRP applicant on a bridge port it manages (i.e. do not `ip link set dev <vlan-if> type vlan mvrp on` stacked over a managed port), and do not run a second MVRP daemon (such as [mvrpd](https://github.com/michael-dev/mvrpd)) against the same bridge. The kernel's 8021q MVRP applicant is still the correct way for a Linux *end station* to declare VLAN membership toward the bridge — that is a peer on the far end of a link, not a co-resident applicant. The pre-routing nftables drop rule (see below) is mandatory: it stops the bridge from flooding MVRP frames so that `mrpd` can propagate them itself.

(If you wish to send AVTP packets from a local end station you should create a VLAN interface and read [this](https://tsn.readthedocs.io/vlan.html) document on configuring `egress-qos-map`, but bear in mind that OpenSRP end-station support is incomplete at the time of writing.)

## Configuring

Configuration prior to running the `mrpd` daemon is left to the administrator, and can be performed with standard Linux tools such as `bridge` and `tc`. The `config-srp.sh` script in the top-level directory is a good starting point, but essentially the assumptions are as follows:

* A Linux bridge is configured with at least two network interfaces
* A pre-routing nftables hook is configured, to drop MMRP/MVRP packets so the bridge does not flood them (`mrpd` snoops and propagates them itself; see note below)
* The `mqprio` qdisc is configured for class A and B streams according to the documentation [here](https://tsn.readthedocs.io/qdiscs.html).

Note that `mrpd` will adjust the Credit Based Shaper (CBS) parameters dynamically depending on stream reservations (if there are no reservations, the `cbs` qdisc will be replaced with the default `pfifo_fast` one).

The following command ensures that packets destined for the customer bridge MRP group address are not forwarded:

```bash
nft add rule bridge nat PREROUTING meta ibrname ${BR} ether daddr 01:80:c2:00:00:21 drop
```

The rule only needs to `drop`: `mrpd` snoops MVRP/MMRP itself over an ingress raw `AF_PACKET` socket (before the bridge consumes the frame), so the rule's sole job is to stop the bridge from flooding these frames — it no longer has to `log group N` them to userspace. (The approach of dropping MVRP so a userspace daemon can propagate it is inspired by Michael Braun's [mvrpd](https://github.com/michael-dev/mvrpd).)

If you wish to use a parent qdisc handle other than 0x9000, you will need to pass this as an option to `mrpd` with `--q-disc-handle`.

Accurate reporting of the SRP accumulated latency requires a local PTP instance that can report the mean link delay over the PTP management interface. Currently only [LinuxPTP](https://linuxptp.nwtime.org) is supported, although any PTP server that supports PMC over a domain socket as well as the LinuxPTP `GET_PORT_DATA_SET_NP` and `GET_PORT_PROPERTIES_NP` extensions should work.

There are various parameters to `mrpd` which can be listed with the `--help` option.

## Running

Command-line usage of the `mrpd` daemon is as follows:

```bash
USAGE: mrpd [<options>] --bridge-interface <bridge-interface>

OPTIONS:
  -b, --bridge-interface <bridge-interface>
                          Master bridge interface name
  -q, --q-disc-handle <q-disc-handle>
                          Qdisc handle (default: 36864)
  --force-avb-capable     Force ports to advertise as AVB capable
  --ignore-as-capable/--no-ignore-as-capable
                          Ignore gPTP asCapable, do not query PTP
                          (--no-ignore-as-capable enforces 35.2.1) (default:
                          --ignore-as-capable)
  --enable-talker-pruning Enable MSRP talker pruning
  --leave-immediate/--no-leave-immediate
                          MSRP immediate Registrar leave on received Leave
                          (Avnu §9.2) (default: --leave-immediate)
  --max-fan-in-ports <max-fan-in-ports>
                          Maximum number of MSRP fan-in ports (default: 0)
  --max-talker-attributes <max-talker-attributes>
                          Global MSRP Talker attribute limit (0 disables the
                          limit) (default: 150)
  --class-a-qdisc-handle <class-a-qdisc-handle>
                          MSRP SR class A Qdisc handle (queue) (default: 4)
  --class-b-qdisc-handle <class-b-qdisc-handle>
                          MSRP SR class B Qdsisc handle (queue) (default: 3)
  --class-a-delta-bandwidth <class-a-delta-bandwidth>
                          MSRP SR class A delta bandwidth percentage
  --class-b-delta-bandwidth <class-b-delta-bandwidth>
                          MSRP SR class B delta bandwidth percentage
  --configure-egress-queues
                          Automatically configure MQPRIO egress queues
  --configure-ingress-queues
                          Automatically configure DCBNL ingress queue (PCP) mapping
  --configure-queues      Automatically configure both ingress and egress queues
  --configure-ingress-mdb Install an MDB entry on the Talker's ingress port
                          (secure switch mode)
  --configure-filtering <configure-filtering>
                          Per-port AVB admission-control mechanism (marvell,
                          tcflower) (values: marvell, tcflower)
  --sr-p-vid <sr-p-vid>   MSRP SR PVID (the VLAN both SR classes declare,
                          35.2.1.4) (default: 2)
  --exclude-iface <exclude-iface>
                          Exclude physical interface (may be specified multiple times)
  --exclude-vlan <exclude-vlan>
                          Exclude VLAN From MVRP (may be specified multiple times)
  -l, --log-level <log-level>
                          Log level (values: trace, debug, info, notice, warning, error, critical; default: info)
  --enable-mmrp           Enable MMRP
  --enable-mvrp           Enable MVRP
  --declare-pvid/--no-declare-pvid
                          Declare each port's PVID over MVRP (11.2.1.3)
                          (default: --no-declare-pvid)
  --enable-msrp           Enable MSRP
  --pmc-uds-path <pmc-uds-path>
                          PTP management client domain socket path
  --join-time <join-time> MRP Join time interval (default: 0.2 seconds)
  --leave-time <leave-time>
                          MRP Leave time interval (default: 5.0 seconds)
  --leave-all-time <leave-all-time>
                          MRP LeaveAll time interval (default: 10.0 seconds)
  --periodic-time <periodic-time>
                          MRP Periodic TX time interval (default: 1.0 seconds)
  -h, --help              Show help information.

```

A typical invocation would look like:

```bash
mrpd -b br0 --enable-srp --configure-egress-queues
```

Note that the `trace` log level will log a _lot_ of messages. `--enable-srp` is a (hidden) synonym which will enable MMRP, MVRP and MSRP.

Higher queue numbers have higher scheduling priority, however this is broken with the Intel i210 driver. With the recommended configuration, you will need to pass `--class-a-qdisc-handle 1 --class-b-qdisc-handle 2` when using this NIC.

## Testing

The current test environments consist of:

* An x86\_64 server with two Intel i210 NICs with their SDP pins tied, using `ts2phc` and `ptp4l` in 802.1AS mode (no longer being tested)
* A Global Scale Technologies [MOCHAbin](https://globalscaletechnologies.com/product/MOCHAbin-copy/) with its stock 88E6141 switch chip replaced with a 88E6341, also using `ptp4l`
* A custom board (’XEBRA’) with a Raspberry Pi CM4 and a Marvell 88E6352

Kernel patches for the Marvell to support FQTSS and RMU are in the [rpi-6.18.y-xebros-rmu](https://github.com/PADL/linux/tree/rpi-6.18.y-xebros-rmu) branch. Packaging scripts for Ubuntu 24.04.4 can be found in [Packaging](Packaging/).

Endpoints we are testing include:

* MOTU Ultralite AVB (tested with i210, MOCHAbin)
* MOTU M64 (tested with MOCHAbin)
* MOTU 16A (2025) (tested with XEBRA, ESPRESSObin, MOCHAbin)
* macOS AVB stack (tested with i210)
* XMOS lib\_tsn (tested with XEBRA, ESPRESSObin, MOCHAbin)

Bridges have tested transitively (i.e. as upstream switches):

* Luminex Gigacore 10i
* Extreme x460-48p

Please reach out to myself (lukeh `at` lukktone `dot` com) for further information.
