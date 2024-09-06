# SwiftMRP

SwiftMRP is a Swift implementation of MMRP, MVRP and MSRP from 802.1Q (commonly referred to by the aggregate term SRP). It is a work in progress (pre-alpha) so, caveat emptor.

Its distinguishing features have less to do with being written in Swift (although that did facilitate its rapid development), but rather in being designed to support bridging, and doing so with the standard Linux kernel interfaces. In my research, the other open source SRP implementations support end stations only, or they use proprietary kernel interfaces (necessary before Linux provided standardized interfaces over NetLink).

The eventual goal it so support switch chips running in DSA mode.

## Architecture

* NetLink: Swift structured concurrency wrapper around `libnl-3` (this has now been factored out into a [separate package](https://github.com/PADL/NetLinkSwift))
* IEEE802: shared types and serialization APIs
* MarvellRMU: future framework for integrating with Marvell switches using RMU (TBC)
* MRP: abstract state machine, platform abstraction layer
* MRPDaemon: MRP daemon
* PMC: PTP management client library

MMRP, MVRP, and MSRP are "applications" of the generalized MRP protocol and state machine. The applications are responsible for responding to the MRP registrations (e.g. by adding a FDB entry) and also propagating the declarations to other ports.

Note that whilst SwiftMRP does have a platform abstraction layer, the initial platform is Linux, and we would prefer to push switch-specific functionality into the kernel rather than separate platform backends.

Because Linux has an in-kernel MVRP applicant, `mrpd` does not automatically advertise statically configured VLANs. If you wish to do so, you should create a VLAN interface and set the `mvrp` flag to `on` using `ip link set dev` . (If you wish to send AVTP packets you should also read [this](https://tsn.readthedocs.io/vlan.html) document on configuring `egress-qos-map`. But bear in mind that SwiftMRP end-station support is incomplete at the time of writing.)

## Configuring

Static configuration is left to the administrator as there is no point re-implementing standard tools such as `bridge` and `tc`. The `config-vlan.sh` script in the top-level directory is a good starting point, but essentially the assumptions are as follows:

* A bridge is configured with at least one network interface (two or more to do anything useful as end-station support is not yet implemented)
* A pre-routing nftables hook is required to allow `mrpd` to intercept MMRP/MVRP packets before they are bridged (see note below)
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

Usage of the `mrpd` daemon is as follows:

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

## Testing

The current test environment consists of an x86\_64 server with two Intel i210 NICs with their SDP pins tied, using `ts2phc` and `ptp4l` in 802.1AS mode.

Endpoints we are testing include:

* MOTU Ultralite AVB (tested)
* macOS AVB stack (tested)
* XMOS lib\_tsn (TBA)
* JOYNED MILAN stack (TBA)

Bridges we are testing transitively:

* Luminex Gigacore 10i (tested)
* Extreme x460-48p (TBA)

Please reach out to myself (lukeh `at` lukktone `dot` com) for further information.
