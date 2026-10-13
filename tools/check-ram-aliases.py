#!/usr/bin/env python3
"""Checks that ram/<system>/alias.json never routes a ROM set to a profile made for another game.

Two rules, per system folder:

1. every alias targets an existing <slug>.MEM;
2. in arcade, when a .MEM declares its ROM sets (rom.hashes labels such as "ddragon.7z <...>"), every
   set aliased to that slug (lowercase "<set>.7z" or "<set>.zip" keys) is one of the declared sets.

Rule 2 is what keeps two different games that share a title from landing on one profile.
Known, reviewed exceptions live in tools/ram-alias-exceptions.json ({"<system>/<slug>": ["set", ...]}).

usage: check-ram-aliases.py [ram directory]      exit code 1 when a rule is broken
"""
import json
import os
import re
import sys

# A set name, as MAME and FBNeo write it ("ddragon.7z"). Titles followed by an extension are not sets.
ARCHIVE = re.compile(r"([a-z0-9_]+)\.(?:7z|zip)")
# Folders whose ROMs are named sets. Elsewhere a ROM is a title and rule 2 has nothing to compare.
SET_FOLDERS = {"arcade"}
LABEL = re.compile(r'label\s*=\s*"([^"]*)"')
LABEL_SET = re.compile(r"(.+?)\.(?:7z|zip)(?:\s|$)", re.IGNORECASE)


def declared_sets(mem_path):
    with open(mem_path, encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    found = set()
    for label in LABEL.findall(text):
        match = LABEL_SET.match(label)
        if match:
            found.add(match.group(1).lower())
    return found


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ram = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "ram")
    exceptions_path = os.path.join(here, "ram-alias-exceptions.json")
    exceptions = {}
    if os.path.exists(exceptions_path):
        with open(exceptions_path, encoding="utf-8") as handle:
            exceptions = {k: {s.lower() for s in v} for k, v in json.load(handle).items() if not k.startswith("_")}

    errors, checked, undeclared_profiles = [], 0, 0
    for system in sorted(os.listdir(ram)):
        folder = os.path.join(ram, system)
        alias_path = os.path.join(folder, "alias.json")
        if not os.path.isfile(alias_path):
            continue
        with open(alias_path, encoding="utf-8") as handle:
            alias = json.load(handle)

        sets_by_slug = {}
        for key, slug in alias.items():
            match = ARCHIVE.fullmatch(key)
            if match:
                sets_by_slug.setdefault(slug, set()).add(match.group(1).lower())
            else:
                sets_by_slug.setdefault(slug, set())

        for slug, sets in sorted(sets_by_slug.items()):
            mem_path = os.path.join(folder, slug + ".MEM")
            if not os.path.isfile(mem_path):
                errors.append(f"{system}/alias.json: '{slug}' has no {slug}.MEM")
                continue
            if not sets or system not in SET_FOLDERS:
                continue
            checked += 1
            declared = declared_sets(mem_path)
            if not declared:
                undeclared_profiles += 1
                continue
            allowed = exceptions.get(f"{system}/{slug}", set())
            foreign = sorted(s for s in sets if s not in declared and s not in allowed)
            if foreign:
                errors.append(
                    f"{system}/{slug}.MEM declares {sorted(declared)} but alias.json also routes {foreign} to it"
                )

    print(f"{checked} arcade profiles with aliased sets checked, {undeclared_profiles} declare no ROM set (skipped)")
    for error in errors:
        print("ERROR " + error)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
