#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 mac-i3 contributors

# Runs the unit tests with the Command Line Tools' Swift Testing (no full Xcode needed).
set -e
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools/Library/Developer
if [ -d "$CLT/Frameworks/Testing.framework" ] && ! xcode-select -p | grep -q Xcode.app; then
  exec swift test \
    -Xswiftc -F$CLT/Frameworks -Xlinker -F$CLT/Frameworks \
    -Xlinker -rpath -Xlinker $CLT/Frameworks -Xlinker -rpath -Xlinker $CLT/usr/lib "$@"
fi
exec swift test "$@"
