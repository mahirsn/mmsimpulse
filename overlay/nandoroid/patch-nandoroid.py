#!/usr/bin/env python3
"""Point a NAnDoroid checkout at the KWin compat module instead of Hyprland.

NAnDoroid (github.com/na-ive/nandoroid-shell) is written for Hyprland: fifty of
its QML files import Quickshell.Hyprland and read workspaces, monitors and the
window list straight off that singleton, none of which answers under KWin.

The obvious fix — a replacement module on QML_IMPORT_PATH under the same URI —
does not work: Quickshell serves Quickshell.Hyprland from its own qrc
(`prefer :/qt/qml/Quickshell/Hyprland/`), and the resource wins. So the compat
module lives under its own name and this script rewrites the import line to
reach it. Everything else about those files is left alone, which is what lets a
newer NAnDoroid be re-copied and re-patched.

The compat singleton forwards to the real Quickshell.Hyprland when the session
is Hyprland, so one patched copy runs on both compositors.

Usage: patch-nandoroid.py <staged-shell-dir>
"""

import pathlib
import re
import sys

# Written against a specific compositor on purpose, or already ours.
EXCLUDE = {
    "compat/Hyprland.qml",
    "compat/GlobalShortcut.qml",
    "compat/HyprlandFocusGrab.qml",
    "compat/KwinBackend.qml",
}

# (name, pattern, replacement) applied to every .qml outside EXCLUDE.
# A rule that matches nothing anywhere is a rename upstream and fails the run,
# so the shell is never installed silently half-patched.
RULES = [
    # Typed declarations naming Hyprland's own C++ types. The compat singleton
    # hands back plain JS objects, which such a property refuses and leaves
    # null, so the type has to go. `var` is what the shell reads them as
    # anyway — every use is a property read, never a type check.
    ("monitor type",
     re.compile(r"\bproperty\s+HyprlandMonitor\b"),
     "property var"),
    ("workspace list type",
     re.compile(r"\bproperty\s+list<HyprlandWorkspace>"),
     "property var"),

    # HyprlandToplevel is an attached property Quickshell puts on Wayland
    # toplevel handles. There is no attaching object under KWin, so reading
    # through it throws and takes the whole binding with it. Optional chaining
    # turns that into an undefined, which the call sites already tolerate —
    # the overview then matches no windows rather than dying.
    ("toplevel attached read",
     re.compile(r"(?<!\?)\.HyprlandToplevel\."),
     "?.HyprlandToplevel?."),
]


def import_rewrite(rel_path: pathlib.Path) -> str:
    """The compat module is a directory import, so its path is relative."""
    depth = len(rel_path.parts) - 1
    return "../" * depth + "compat" if depth else "compat"


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    root = pathlib.Path(sys.argv[1])
    if not (root / "shell.qml").is_file():
        print(f"{root} has no shell.qml", file=sys.stderr)
        return 1

    hypr_import = re.compile(r"^([ \t]*)import\s+Quickshell\.Hyprland\s*$", re.M)

    hits = {name: 0 for name, _, _ in RULES}
    imports_rewritten = 0
    files_changed = 0

    for path in sorted(root.rglob("*.qml")):
        rel = path.relative_to(root)
        if str(rel) in EXCLUDE:
            continue
        original = text = path.read_text()

        text, n = hypr_import.subn(
            lambda m: f'{m.group(1)}import "{import_rewrite(rel)}"', text)
        imports_rewritten += n

        for name, pattern, replacement in RULES:
            text, n = pattern.subn(replacement, text)
            hits[name] += n

        if text != original:
            path.write_text(text)
            files_changed += 1

    missed = [name for name, count in hits.items() if count == 0]
    if imports_rewritten == 0:
        missed.append("Quickshell.Hyprland import")
    if missed:
        print("patch-nandoroid: nothing matched: " + ", ".join(missed), file=sys.stderr)
        return 1

    print(f"patch-nandoroid: {files_changed} files, "
          f"{imports_rewritten} imports, "
          + ", ".join(f"{n} {name}" for name, n in hits.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
