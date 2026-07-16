#!/usr/bin/python3

"""Port drift report (IMPLEMENTATION_PLAN.md Phase 4.4, Consolidation gate
item e). For every `port.source = { name = { file, func, upstream_commit },
... }` entry across lua/ai/*.lua, extracts that C++ function's body both at
the pinned `upstream_commit` and at the current tip of `upstream/master`
(falling back to `master` with a warning if the `upstream` remote isn't
fetched locally -- see CLAUDE.md's remote layout), normalizes whitespace
and comments, hashes both, and reports which ported functions have
drifted: their upstream C++ body changed since the port was written, so
the Lua port may now be stale and needs review.

This is lightweight text-based extraction (regex + brace/paren balancing
over `git show <ref>:<path>` output), not a real C++ parser -- matches
this project's existing tooling style (tools/gen_ffi.cpp is the closest
precedent: pattern-based struct-layout extraction, not a full parser).
Known limitation: a function body containing a stray unbalanced brace or
paren inside a string/comment could confuse extraction; none of the
currently ported functions do this.

Usage: tools/port_drift.py [--base-ref REF]
Exit code: 0 if every ported function is clean, 1 if anything drifted or
couldn't be extracted/compared (an extraction failure is itself worth a
look, not silently ignored -- CI-usable).
"""

import argparse
import hashlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AI_DIR = ROOT / "lua" / "ai"

# Matches this project's port.source entry shape exactly (see any
# lua/ai/*.lua file, or IMPLEMENTATION_PLAN.md 4.4's own example):
#   name = { file = "src/x.cpp", func = "y",
#       upstream_commit = "abc123..." },
# Field order (file, func, upstream_commit) is a convention, not enforced
# by Lua itself -- if it's ever written differently this regex needs
# updating too.
SOURCE_ENTRY_RE = re.compile(
    r'file\s*=\s*"([^"]+)"\s*,\s*func\s*=\s*"([^"]+)"\s*,\s*\n?\s*'
    r'upstream_commit\s*=\s*"([^"]+)"'
)

# Matches either a comment (removed) or a string/char literal (kept
# verbatim, so a "//" or "/*" inside a string literal doesn't get
# misread as a comment start).
COMMENT_OR_STRING_RE = re.compile(
    r"//.*?$|/\*.*?\*/|'(?:\\.|[^\\'])*'|\"(?:\\.|[^\\\"])*\"",
    re.DOTALL | re.MULTILINE,
)


def find_source_entries():
    """Yields (lua_file, func_name, cpp_file, upstream_commit)."""
    for lua_file in sorted(AI_DIR.glob("*.lua")):
        text = lua_file.read_text()
        for m in SOURCE_ENTRY_RE.finditer(text):
            cpp_file, func_name, commit = m.group(1), m.group(2), m.group(3)
            yield lua_file.relative_to(ROOT), func_name, cpp_file, commit


def git_show(ref, path):
    result = subprocess.run(
        ["git", "show", f"{ref}:{path}"],
        cwd=ROOT, capture_output=True, text=True)
    if result.returncode != 0:
        return None
    return result.stdout


def find_function_body(content, func_name):
    """Locates func_name's *definition* (not a prototype or call site) by
    requiring the balanced parameter-list parens to be followed by '{',
    then returns the brace-balanced body including the outer braces."""
    pattern = re.compile(r"\b" + re.escape(func_name) + r"\s*\(")
    pos = 0
    while True:
        m = pattern.search(content, pos)
        if not m:
            return None
        depth = 0
        i = m.end() - 1
        while i < len(content):
            if content[i] == "(":
                depth += 1
            elif content[i] == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        else:
            pos = m.end()
            continue
        j = i + 1
        while j < len(content) and content[j] in " \t\r\n":
            j += 1
        if j < len(content) and content[j] == "{":
            depth = 0
            k = j
            while k < len(content):
                if content[k] == "{":
                    depth += 1
                elif content[k] == "}":
                    depth -= 1
                    if depth == 0:
                        return content[j:k + 1]
                k += 1
            return None
        pos = m.end()


def normalize(code):
    def replacer(m):
        s = m.group(0)
        return " " if s.startswith("/") else s
    code = COMMENT_OR_STRING_RE.sub(replacer, code)
    return re.sub(r"\s+", " ", code).strip()


def body_hash(content, func_name):
    body = find_function_body(content, func_name)
    if body is None:
        return None
    return hashlib.sha256(normalize(body).encode()).hexdigest()


def resolve_base_ref(requested):
    if requested:
        return requested
    check = subprocess.run(
        ["git", "rev-parse", "--verify", "upstream/master"],
        cwd=ROOT, capture_output=True, text=True)
    if check.returncode == 0:
        return "upstream/master"
    sys.stderr.write(
        "warning: upstream/master not found (git fetch upstream?), "
        "falling back to master -- only correct if master is a clean "
        "upstream mirror per CLAUDE.md\n")
    return "master"


def main():
    parser = argparse.ArgumentParser(description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-ref", default=None,
        help="ref to treat as 'current upstream' (default: "
             "upstream/master, falling back to master)")
    args = parser.parse_args()
    base_ref = resolve_base_ref(args.base_ref)

    entries = list(find_source_entries())
    if not entries:
        print("no port.source entries found under lua/ai/*.lua")
        return 0

    drifted, errors, clean = [], [], []
    file_cache = {}

    def cached_show(ref, path):
        key = (ref, path)
        if key not in file_cache:
            file_cache[key] = git_show(ref, path)
        return file_cache[key]

    for lua_file, func_name, cpp_file, commit in entries:
        pinned_content = cached_show(commit, cpp_file)
        current_content = cached_show(base_ref, cpp_file)
        if pinned_content is None:
            errors.append((lua_file, func_name, cpp_file,
                f"cannot read {cpp_file} at pinned commit {commit[:12]}"))
            continue
        if current_content is None:
            errors.append((lua_file, func_name, cpp_file,
                f"cannot read {cpp_file} at {base_ref}"))
            continue
        pinned_hash = body_hash(pinned_content, func_name)
        current_hash = body_hash(current_content, func_name)
        if pinned_hash is None:
            errors.append((lua_file, func_name, cpp_file,
                f"could not extract {func_name}() at pinned commit {commit[:12]}"))
            continue
        if current_hash is None:
            errors.append((lua_file, func_name, cpp_file,
                f"could not extract {func_name}() at {base_ref} "
                "(renamed/removed upstream?)"))
            continue
        if pinned_hash != current_hash:
            drifted.append((lua_file, func_name, cpp_file, commit))
        else:
            clean.append((lua_file, func_name, cpp_file))

    print(f"port drift report (base ref: {base_ref})")
    print(f"  {len(clean)} clean, {len(drifted)} drifted, {len(errors)} errors\n")

    if drifted:
        print("DRIFTED (upstream C++ body changed since the port was written):")
        for lua_file, func_name, cpp_file, commit in drifted:
            print(f"  {func_name} ({cpp_file}, ported in {lua_file}, "
                  f"pinned at {commit[:12]}) -- review needed")
        print()

    if errors:
        print("ERRORS (could not compare):")
        for lua_file, func_name, cpp_file, msg in errors:
            print(f"  {func_name} ({cpp_file}, {lua_file}): {msg}")
        print()

    return 1 if (drifted or errors) else 0


if __name__ == "__main__":
    sys.exit(main())
