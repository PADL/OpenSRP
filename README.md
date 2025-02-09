# SwiftMRP

SwiftMRP is an implementation of the 802.1Q SRP suite of protocols: MMRP, MVRP and MSRP. They are used in AVB/TSN networks to coordinate stream reservations amongst Ethernet bridges.

SwiftMRP's distinguishing features have less to do with being written in Swift (although that did facilitate its rapid development), but rather in being designed to support bridging, and doing so with the standard Linux kernel interfaces. The other open source SRP implementations (that the author has been able to find) typically support end-stations only, or use proprietary kernel interfaces.

## Architecture

* NetLink: Swift structured concurrency wrapper around `libnl-3` (this has now been split into a [separate package](https://github.com/PADL/NetLinkSwift))
* IEEE802: shared types and serialization APIs
* MRP: abstract state machine, platform abstraction layer
* MRPDaemon: MRP daemon
* PMC: PTP management client library

MMRP, MVRP, and MSRP are "applications" of the generalized MRP protocol and state machine. Aplications are responsible for responding to MRP registrations (e.g. by adding a FDB entry) and also propagating MRP declarations to other bridge ports.

Note that whilst SwiftMRP does have a platform abstraction layer, the initial platform is Linux, and we would prefer to push switch-specific functionality into the kernel rather than separate platform backends.

Note: as Linux has an in-kernel MVRP applicant, `mrpd` does not automatically advertise statically configured VLANs. If you wish to do so, you should create a VLAN interface and set the `mvrp` flag to `on` using `ip link set dev` . (If you wish to send AVTP packets you should also read [this](https://tsn.readthedocs.io/vlan.html) document on configuring `egress-qos-map`. But bear in mind that SwiftMRP end-station support is incomplete at the time of writing.)

## Configuring

Configuration prior to running the `mrpd` daemon is left to the administrator, and can be performed with standard Linux tools such as `bridge` and `tc`. The `config-srp.sh` script in the top-level directory is a good starting point, but essentially the assumptions are as follows:

* A Linux bridge is configured with at least two network interfaces
* A pre-routing nftables hook is configured, to allow `mrpd` to intercept MMRP/MVRP packets before they are bridged (see note below)
* The `mqprio` qdisc is configured for class A and B streams according to the documentation [here](https://tsn.readthedocs.io/qdiscs.html).

Note that `mrpd` will adjust the Credit Based Shaper (CBS) parameters dynamically depending on stream reservations (if there are no reservations, the `cbs` qdisc will be replaced with the default `pfifo_fast` one).

The following command ensures that packets destined for the customer bridge MRP group address are not forwarded:

```bash
nft add rule bridge nat PREROUTING meta ibrname ${BR} ether daddr 01:80:c2:00:00:21 log group 10 drop
```

(The use of `nflog` to capture and drop MVRP packets is inspired by Michael Braun's [mvrpd](https://github.com/michael-dev/mvrpd).)

Note that if you use a group number different to the default (10) you will need to pass that as an option to `mrpd` with `--nf-group`. Similarly, if you wish to use a parent qdisc handle other than 0x9000, you will also need to pass this as an option to `mrpd` with `--q-disc-handle`.

Accurate reporting of the SRP accumulated latency requires a local PTP instance that can report the mean link delay over the PTP management interface. Currently only [LinuxPTP](https://linuxptp.nwtime.org) is supported, although any PTP server that supports PMC over a domain socket as well as the LinuxPTP `GET_PORT_DATA_SET_NP` and `GET_PORT_PROPERTIES_NP` extensions should work.

There are various parameters to `mrpd` which can be listed with the `--help` option.

## Running

Command-line usage of the `mrpd` daemon is as follows:

```bash
USAGE: mrpd [<options>] --bridge-interface <bridge-interface>

OPTIONS:
  -b, --bridge-interface <bridge-interface>
                          Master bridge interface name
  -n, --nf-group <nf-group>
                          NetFilter group (default: 10)
  -q, --q-disc-handle <q-disc-handle>
                          QDisc handle (default: 36864)
  --force-avb-capable     Force ports to advertise as AVB capable
  --enable-talker-pruning Enable MSRP talker pruning
  --max-fan-in-ports <max-fan-in-ports>
                          Maximum number of MSRP fan-in ports (default: 0)
  --class-a-qdisc-handle <class-a-qdisc-handle>
                          MSRP SR class A Qdisc handle (queue) (default: 4)
  --class-b-qdisc-handle <class-b-qdisc-handle>
                          MSRP SR class B Qdsisc handle (queue) (default: 3)
  --class-a-delta-bandwidth <class-a-delta-bandwidth>
                          MSRP SR class A delta bandwidth percentage
  --class-b-delta-bandwidth <class-b-delta-bandwidth>
                          MSRP SR class B delta bandwidth percentage
  --sr-p-vid <sr-p-vid>   Default MSRP SR PVID (default: 2)
  --exclude-iface <exclude-iface>
                          Exclude physical interface (may be specified multiple times)
  --exclude-vlan <exclude-vlan>
                          Exclude VLAN From MVRP (may be specified multiple times)
  -l, --log-level <log-level>
                          Log level (values: trace, debug, info, notice, warning, error, critical; default: info)
  --enable-mmrp           Enable MMRP
  --enable-mvrp           Enable MVRP
  --enable-msrp           Enable MSRP
  --pmc-uds-path <pmc-uds-path>
                          PTP management client domain socket path
  -h, --help              Show help information.
```

A typical invocation would look like:

```bash
mrpd -b br0 --enable-mmrp --enable-mvrp --enable-msrp -l debug
```

Note that the `trace` log level will log a _lot_ of messages. `--enable-srp` is a (hidden) synonym which will enable MMRP, MVRP and MSRP.

Higher queue numbers have higher scheduling priority, however this is broken with the Intel i210 driver. With the recommended configuration, you will need to pass `--class-a-qdisc-handle 1 --class-b-qdisc-handle 2` when using this NIC.

## Testing

The current test environments consist of:

* An x86\_64 server with two Intel i210 NICs with their SDP pins tied, using `ts2phc` and `ptp4l` in 802.1AS mode (no longer being tested)
* A Global Scale Technologies [MochaBIN](https://globalscaletechnologies.com/product/mochabin-copy/) with its stock 88E6141 switch chip replaced with a 88E6341, also using `ptp4l`
* A custom board (’XEBRA’) with a Raspberry Pi CM4 and a Marvell 88E6352

Endpoints we are testing include:

* MOTU Ultralite AVB (tested with i210 and MochaBIN)
* MOTU M64 (tested with MochaBIN)
* macOS AVB stack (tested with i210)
* XMOS lib\_tsn (TBA)
* JOYNED lib\_joyned (TBA)

Bridges we are testing transitively:

* Luminex Gigacore 10i (tested)
* Extreme x460-48p (TBA)

Please reach out to myself (lukeh `at` lukktone `dot` com) for further information.
