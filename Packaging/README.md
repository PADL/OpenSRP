# Switch-stack Debian packaging

Build scripts that produce Ubuntu **arm64** `.deb` packages for the AVB/TSN
switch stack, cross-compiled on this x86_64 Ubuntu host:

| Package      | Source                                          | Build system        |
|--------------|-------------------------------------------------|---------------------|
| `mrpd`       | this repo (`PADL/OpenSRP`), built in place      | SwiftPM             |
| `mstpd`      | `github.com/mstpd/mstpd` (HEAD)                 | autotools (C)       |
| `linuxptp`   | `github.com/PADL/linuxptp` @ `inferno`          | make (C)            |
| `iproute2`   | `github.com/PADL/iproute2` @ `brport-filter-stream-reserved` | make (C) |
| `linux-image`/`linux-headers` | `github.com/PADL/linux` @ `rpi-6.18.y-xebros-rmu` | kernel `bindeb-pkg` |

Apart from `mrpd` (built from this repository), every component is **cloned
from git** (shallow) into `Packaging/.work/`; nothing is read from local
working trees. The daemon packages install the systemd units from `../Configs/`
and enable them on install. The kernel package is a native replacement for the
stock Ubuntu kernel (installs to `/boot`, runs `depmod` / initramfs
regeneration) and is configured with the Armada switch config kept in
`Packaging/armada.config`.

## Prerequisites

- `aarch64-linux-gnu-` GCC cross toolchain (`gcc-aarch64-linux-gnu`).
- `dpkg-deb` (from `dpkg`, default on Ubuntu).
- For the kernel: kbuild deps `bc flex bison libssl-dev libelf-dev rsync kmod`
  plus the `.deb` packaging tools `debhelper libdw-dev` (the build passes
  `DPKG_FLAGS=-d` so noble's debhelper 13 satisfies the source's
  `debhelper-compat (= 12)`).
- For **mrpd** (Swift):
  - The cross SDK `6.3-RELEASE_ubuntu_noble_aarch64` (`swift sdk list`).
    Regenerate with
    [swift-sdk-generator](https://github.com/swiftlang/swift-sdk-generator) if needed.
  - A Swift **toolchain whose version matches the SDK** (the SDK is
    `6.3-RELEASE`, so toolchain `6.3.0`). Swift refuses to import a stdlib built
    by a different compiler version. `build-mrpd.sh` selects the swiftly
    toolchain in `$SWIFT_TOOLCHAIN` (default `6.3.0`); install it with
    `swiftly install 6.3.0`.
  - The SDK sysroot must be **augmented** once with arm64 `liburing` and
    `libsystemd` (not shipped in the stock SDK) — run `./augment-sysroot.sh`.

### One-time setup for mrpd

```sh
swiftly install 6.3.0      # toolchain matching the SDK
./augment-sysroot.sh       # adds arm64 liburing + libsystemd to the SDK sysroot
```

### Building for armhf (32-bit ARM)

`DEB_ARCH=armhf` targets the 32-bit silicon. Swift ships no official 32-bit ARM
Linux SDK, so mrpd builds against a **self-built Ubuntu-noble armv7 SDK** from
[swift-embedded-linux/armhf-debian](https://github.com/swift-embedded-linux/armhf-debian),
installed at `/opt/swift-6.3.2-RELEASE-ubuntu-noble-armv7/` and selected
automatically (legacy `--destination`, via `SWIFT_DESTINATION_JSON`). Building
against a *native noble* SDK — rather than an older Debian-bookworm one bridged by
glibc forward-compat — means the binary links noble glibc 2.39 directly, with no
lib overlay and no kernel-uapi graft. Build the SDK once (needs Docker
multi-platform + host Swift 6.3.2):

```sh
git clone https://github.com/swift-embedded-linux/armhf-debian && cd armhf-debian
./build-sysroot.sh ubuntu noble
STAGING_DIR=/src/sysroot-ubuntu-noble SWIFT_VERSION=6.3.2 SWIFT_TARGET_ARCH=armv7 \
  STATIC_SWIFT_STDLIB=1 ./build-in-container.sh
SWIFT_TARGET_ARCH=armv7 ./build-linux-cross-sdk.sh swift-6.3.2-RELEASE ubuntu-noble
sudo tar -xzf artifacts/swift-6.3.2-RELEASE-ubuntu-noble-armv7.tar.gz -C /opt
```

Two gotchas if you reproduce this: the host `qemu-arm` binfmt must carry the `F`
flag or armhf containers fail with `exec /bin/bash: no such file` — fix with
`docker run --privileged --rm tonistiigi/binfmt --uninstall qemu-arm,qemu-armeb`
then `… --install arm` (no host sudo; `flags` should read `POCF`). And
`STAGING_DIR` must be the **absolute** in-container path (`/src/...`): clang
validates `--gcc-install-dir` against the current dir, which breaks on a relative
sysroot. Then build as usual:

```sh
DEB_ARCH=armhf ./augment-sysroot.sh   # noble armhf liburing + libnl (no overlays)
DEB_ARCH=armhf ./build-mrpd.sh
```

The resulting binary requires glibc ≥ 2.38 on the target (i.e. it is noble-specific
by design — it no longer pretends to be bookworm).

No `rpmbuild` / `mock` is involved — these are `.deb`s built by repackaging the
cross-compiled binaries (the cross toolchains do the compiling, `dpkg-deb`
just assembles the archive).

## Usage

```sh
cd Packaging
./build-all.sh                 # mrpd, mstpd, linuxptp, iproute2  (fast)
./build-all.sh all             # + the kernel                    (slow)
./build-mrpd.sh                # one component at a time
./build-iproute2.sh
./build-kernel.sh
```

Finished packages land in `Packaging/out/`. iproute2 fetches the arm64
`libmnl`/`libelf`/`libselinux` it links against automatically (from
ports.ubuntu.com, like `augment-sysroot.sh`); only mrpd needs the one-time
setup above.

## Versioning

Each package version is a snapshot of a **base version** plus the component's
short git hash, e.g. `4.4+gitc2cd7cc`, which sorts just after the base release.

| Component | Base    | Override env             |
|-----------|---------|--------------------------|
| mrpd      | `0.1.0` | `MRPD_BASE_VERSION`      |
| mstpd     | `0.2.0` | `MSTPD_BASE_VERSION`     |
| linuxptp  | `4.4`   | `LINUXPTP_BASE_VERSION`  |
| iproute2  | `7.0.0` | `IPROUTE2_BASE_VERSION`  |

Override the whole version per build:

```sh
PKG_VERSION=1.4.0 ./build-mrpd.sh   # explicit version, used verbatim
PKG_USE_TAG=1     ./build-mrpd.sh   # from `git describe --tags`
```

## Overridable settings

Set as environment variables (see `common.sh` for the full list):

| Var               | Default                              | Meaning                       |
|-------------------|--------------------------------------|-------------------------------|
| `DEB_ARCH`        | `arm64`                              | target Debian architecture    |
| `CROSS_COMPILE`   | `aarch64-linux-gnu-`                 | cross toolchain prefix        |
| `SWIFT_SDK`       | `6.3-RELEASE_ubuntu_noble_aarch64`   | Swift cross SDK id (arm64)    |
| `SWIFT_DESTINATION_JSON` | `/opt/swift-6.3.2-RELEASE-ubuntu-noble-armv7/ubuntu-noble-static.json` | armhf `--destination` SDK |
| `SWIFT_TOOLCHAIN` | `6.3.0`                              | swiftly toolchain for mrpd    |
| `MSTPD_GIT`       | `github.com/mstpd/mstpd.git`         | mstpd upstream                |
| `LINUXPTP_GIT` / `LINUXPTP_REF` | `PADL/linuxptp` / `inferno` | linuxptp repo + branch    |
| `IPROUTE2_GIT` / `IPROUTE2_REF` | `PADL/iproute2` / `brport-filter-stream-reserved` | iproute2 repo + branch |
| `LINUX_GIT` / `LINUX_REF` | `PADL/linux` / `rpi-6.18.y-xebros-rmu` | kernel repo + branch |
| `ARMADA_CONFIG`   | `Packaging/armada.config`            | kernel config to build with   |
| `OUT_DIR`         | `Packaging/out`                      | where `.deb`s are written     |

## Runtime configuration

The stack is parameterised by a single environment file, **`/etc/default/avb`**
(shipped by the `mrpd` package as a conffile):

```sh
BR=br0                                  # bridge mrpd operates on
INTERFACES="lan0 lan1 lan2 lan3"        # bridge member ports
GROUPS="91:e0:f0:01:00:00 ..."          # static SRP MDB groups
```

- `mrpd.service` sources it for `$BR`, `$INTERFACES`, `$GROUPS`.
- `ptp4l.service` sources it (optionally) and passes `$INTERFACES` to `ptp4l`
  via `-i`; `gPTP.cfg` (installed by `linuxptp`) carries only the `[global]`
  section. Add per-port `[ifname]` sections there only for overrides.
- **Creating the bridge and enslaving ports is left to the end-user** — the
  `.network`/`.netdev`/`.link` files in `../Configs/` are intentionally *not*
  packaged.
- `avb.target` (shipped by `mrpd`) groups the daemons (`PartOf=`).

## Notes

- `mrpd` is built in release mode with `--static-swift-stdlib`, so the Swift
  runtime is linked statically; glibc and a few system libraries remain
  dynamic. Each build prints the binary's `NEEDED` shared libraries — confirm
  the target image provides them (and adjust `Depends:` in `build-mrpd.sh` if
  the set changes).
- `/etc/gPTP.cfg` is shipped as a conffile so local edits survive upgrades.
