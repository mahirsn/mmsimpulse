#!/bin/bash
# Builds the shell from upstream exactly the way install.sh does, into a
# throwaway directory, and fails if any patch rule no longer applies.
#
# Run before every publish. Editing the installed shell by hand and testing that
# proves nothing about what a fresh install gets: twice a rule shipped that did
# not apply to upstream (an indentation mismatch) or produced invalid QML (a
# heredoc ate a $t and turned "\n" into a real line break), and both passed on
# a machine whose files had been fixed by hand.
set -euo pipefail
REPO="$(dirname "$(dirname "$(readlink -f "$0")")")"
BASE="${MMSIMPULSE_BASE:-$HOME/.config/quickshell/end4-pC}"
[[ -d "$BASE" ]] || { echo "upstream yok: $BASE" >&2; exit 2; }
out="${1:-$(mktemp -d)}"
rm -rf "$out"; mkdir -p "$out"
rsync -a --exclude .git "$BASE/" "$out/"
cp "$REPO"/overlay/services/*.qml "$out/services/"
cp "$REPO"/overlay/sidebarLeft/*.qml "$out/modules/ii/sidebarLeft/"
mkdir -p "$out/scripts/kwin"; cp "$REPO"/kwin-script/*.js "$out/scripts/kwin/"
python3 "$REPO/overlay/patch-shell.py" "$out"

# A literal line break inside a double-quoted JS string is a syntax error that
# only shows when that page is opened; catch the pattern that caused it.
bad=$(grep -rnE '"[^"]*\.split\("$' "$out" --include=*.qml || true)
[[ -z "$bad" ]] || { echo "bozuk string:"; echo "$bad"; exit 1; }
echo "ok: $out"
