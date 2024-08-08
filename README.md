# SwiftMRP

A Swift implementation of MMRP, MVRP and MSRP. It is a work in progress, which is to say, it does not work yet. The current platform abstraction supports the Linux software bridge, but the plan is to also support hardware switches operating in DSA mode.

## Architecture

* CNetLink: wrapper around libnl and friends
* NetLink: Swift structured concurrency wrapper around CNetLink
* MRP: abstract state machine, platform abstraction layer
* MRPDaemon: MRP daemon

The use of `nflog` to capture and drop MVRP packets is inspired by Michael Braun's [mvrpd](https://github.com/michael-dev/mvrpd).
