# SwiftMRP

A Swift implementation of MMRP, MVRP and MSRP. It is a work in progress.

## Architecture

* CNetLink: wrapper around libnl and friends
* NetLink: Swift structured concurrency wrapper around CNetLink
* MRP: abstract state machine, platform abstraction layer
* MRPDaemon: MRP daemon

