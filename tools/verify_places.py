"""Static boot check for project-hades, run per place (Lobby, Dungeons).

Two rules:

  1. OPTIONAL LOOKUPS. Every Blitz.OptionalService("X") /
     Blitz.OptionalController("X") target must name a module SOME place mounts. A lookup is
     allowed to be nil in one place (that is what it is for: a core module
     reaching a Dungeons-only service), but a name no place mounts is a
     typo or a module that was renamed or deleted -- HARD.
  2. CORE REQUIRES. Every path require into Submodules.Core.Source must
     still resolve inside bfg-core -- HARD.

Also prints how many Blitz modules each place mounts, and exits 1 on any
HARD failure.

Run from anywhere:  python tools/verify_places.py
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CORE = os.path.join(ROOT, "bfg-core", "Source")
LIBS = os.path.join(ROOT, "bfg-core", "Libraries")
LUA = (".lua", ".luau")

# `local X = {` followed by `Name = "..."` on the next line: the head of a
# Blitz module.
MODULE_HEAD = re.compile(r'^local [A-Za-z_]+ = \{\s*\n\s*Name\s*=\s*"([A-Za-z]+)"', re.M)
LOOKUP = re.compile(r'Blitz\.Optional(Service|Controller)\("([A-Za-z]+)"\)')


def registered_name(path, fallback):
    """The name a lookup resolves: the `Name` at the head of a Blitz module.
    NOT the first `Name = "..."` anywhere in the file (a module may rename an
    Instance before its own table). Falls back to the file name."""
    text = open(path, encoding="utf-8", errors="replace").read()
    m = MODULE_HEAD.search(text)
    return m.group(1) if m else fallback


def module_files(d):
    """(registeredName, entryFile) for each module directly under d."""
    out = []
    if not os.path.isdir(d):
        return out
    for e in sorted(os.listdir(d)):
        p = os.path.join(d, e)
        if os.path.isdir(p):
            init = next(
                (os.path.join(p, i) for i in ("init.lua", "init.luau") if os.path.exists(os.path.join(p, i))),
                None,
            )
            if init:
                out.append((registered_name(init, e), init))
        elif e.endswith(LUA) and e not in ("init.lua", "init.luau"):
            out.append((registered_name(p, e.rsplit(".", 1)[0]), p))
    return out


def nested_modules(d):
    """Modules the boot scripts load from a sub-tier folder (SubServices,
    SubControllers): one level below a module folder."""
    out = []
    if not os.path.isdir(d):
        return out
    for e in sorted(os.listdir(d)):
        p = os.path.join(d, e)
        if not os.path.isdir(p):
            continue
        for tier in ("SubServices", "SubControllers"):
            out += module_files(os.path.join(p, tier))
    return out


def all_lua(root):
    for dp, dns, fns in os.walk(root):
        dns[:] = [x for x in dns if x not in ("Packages", "_Index")]
        for f in fns:
            if f.endswith(LUA):
                yield os.path.join(dp, f)


def rel(path):
    return os.path.relpath(path, ROOT).replace("\\", "/")


def code_lines(path):
    """(lineNo, line) for every line that is not a comment: `--` lines and
    every line inside a `--[[ ... ]]` block. Only code counts."""
    in_block = False
    for ln, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
        stripped = line.strip()
        if in_block:
            if "]]" in stripped:
                in_block = False
            continue
        if stripped.startswith("--[[") or stripped.startswith("--[="):
            if "]]" not in stripped[4:] and "]=]" not in stripped:
                in_block = True
            continue
        if stripped.startswith("--"):
            continue
        yield ln, line


def mounted(place):
    """(services, controllers) the place's boot scripts load."""
    P = os.path.join(ROOT, "Places", place)
    services, controllers = set(), set()
    for d in (os.path.join(CORE, "Server", "Services"), os.path.join(P, "ServerScriptService", "Services")):
        services |= {n for n, _ in module_files(d)} | {n for n, _ in nested_modules(d)}
    for d in (
        os.path.join(CORE, "Client", "Controllers"),
        os.path.join(CORE, "Client", "Interfaces"),
        os.path.join(P, "ReplicatedStorage", "Controllers"),
        os.path.join(P, "ReplicatedStorage", "Interfaces"),
    ):
        controllers |= {n for n, _ in module_files(d)} | {n for n, _ in nested_modules(d)}
    return services, controllers


PLACES = ("Lobby", "Dungeons")
per_place = {place: mounted(place) for place in PLACES}
any_service = set().union(*(s for s, _ in per_place.values()))
any_controller = set().union(*(c for _, c in per_place.values()))

failed = False
for place in PLACES:
    P = os.path.join(ROOT, "Places", place)
    services, controllers = per_place[place]
    hard = []
    scope = list(all_lua(CORE)) + list(all_lua(P)) + list(all_lua(LIBS))
    blitz_modules = 0
    for f in scope:
        text = open(f, encoding="utf-8", errors="replace").read()
        if MODULE_HEAD.search(text):
            blitz_modules += 1
        for ln, line in code_lines(f):
            for kind, target in LOOKUP.findall(line):
                pool = any_service if kind == "Service" else any_controller
                if target not in pool:
                    hard.append("%s:%d  Blitz.Optional%s(%s) names a module no place mounts" % (rel(f), ln, kind, target))
            for kind, name in re.findall(
                r"Submodules\.Core\.Source\.(Services|Controllers|Interfaces|Components|Mobs|ComponentExtensions)\.([A-Za-z]+)",
                line,
            ):
                side = "Server" if kind in ("Services", "Mobs") else "Client"
                if kind == "Components":
                    exists = any(
                        os.path.exists(os.path.join(CORE, s, "Components", name + ext))
                        or os.path.isdir(os.path.join(CORE, s, "Components", name))
                        for s in ("Server", "Client")
                        for ext in LUA
                    )
                else:
                    base = os.path.join(CORE, side, kind, name)
                    exists = any(os.path.exists(base + ext) for ext in LUA) or os.path.isdir(base)
                if not exists:
                    hard.append("%s:%d  path require Source.%s.%s no longer in core" % (rel(f), ln, kind, name))

    # Zombie component's relative Mobs require
    z = os.path.join(P, "ServerScriptService", "Components", "Zombie.lua")
    if os.path.exists(z) and not os.path.isdir(os.path.join(P, "ServerScriptService", "Mobs")):
        hard.append("Places/%s: Zombie component present but Mobs folder is not beside Components" % place)

    print("=" * 70)
    print(
        "%s: %d services, %d controllers/interfaces mounted; %d Blitz modules in %d files scanned"
        % (place, len(services), len(controllers), blitz_modules, len(scope))
    )
    print("  HARD failures: %d" % len(hard))
    for h in hard:
        print("    ", h)
    failed = failed or bool(hard)

print("=" * 70)
sys.exit(1 if failed else 0)
