#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 mac-i3 contributors

# Fails if a source file (Swift, Python, shell, the Info.plist template) has no SPDX license header.
# Run before committing: scripts/check-license.sh
cd "$(dirname "$0")/.."
missing=0
while IFS= read -r f; do
    case "$f" in
        *.swift|*.py|*.sh|*Info.plist.in)
            if ! head -8 "$f" | grep -q "SPDX-License-Identifier: GPL-3.0-or-later"; then
                echo "missing license header: $f"; missing=1
            fi ;;
    esac
done < <(git ls-files --cached --others --exclude-standard)
[ "$missing" -eq 0 ] && echo "all source files carry the GPL-3.0-or-later header"
exit "$missing"
