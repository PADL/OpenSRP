#!/bin/bash
set -e
swift build --build-tests -Xcc -I/usr/include/libnl3
swift test --skip-build
