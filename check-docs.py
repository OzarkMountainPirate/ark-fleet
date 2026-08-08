#!/usr/bin/env python3
"""
check-docs.py — documentation drift checks for a repo.

Run from the repo root (or pass a path). Exits non-zero if anything is found,
so it works as a CI gate.

    ./check-docs.py                 # check .
    ./check-docs.py ../other-repo   # check somewhere else
    ./check-docs.py --warn-only     # always exit 0

Checks:
  LINK   relative markdown link whose target does not exist in the tree
  FENCE  unbalanced ``` fences, or a markdown heading swallowed by a fence
  PAREN  a link URL followed by a stray ')' that breaks the URL
  REF    `some/file.ext` in backticks that matches nothing in the tree
"""
import os
import re
import sys

link_re = re.compile(r'\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)')
fence_re = re.compile(r'^\s*```')
url_link_re = re.compile(r'\]\((https?://[^)\s]+)\)')
ref_re = re.compile(
    r'`([A-Za-z0-9_./-]+\.'
    r'(?:sh|bash|yml|yaml|conf|json|nft|py|md|ndjson|service|timer|cfg|ini|toml|example))`'
)

# absolute paths in docs are almost always target-system files, not repo files
SKIP_PREFIX = ("/etc", "/var", "/usr", "/opt", "/srv", "/home", "/root", "/mnt",
               "/tmp", "/proc", "/sys", "/dev", "/boot", "~")

# files that live on the deployed host, not in the repo. Extend as needed.
SKIP_NAMES = {
    "GameUserSettings.ini", "Game.ini", "eve.json", "dnsmasq.conf",
    "openvpn.conf", "docker-compose.override.yml", "authorized_keys",
}

SKIP_DIRS = {".git", "node_modules", ".venv", "venv", "__pycache__"}

def walk(root):
    for dp, dn, fn in os.walk(root):
        dn[:] = [d for d in dn if d not in SKIP_DIRS]
        yield dp, dn, fn


def index_tree(root):
    """Every path in the repo, as relative paths and as bare basenames."""
    rel, base = set(), set()
    for dp, dn, fn in walk(root):
        r = os.path.relpath(dp, root)
        if r != ".":
            rel.add(r)
        for f in fn:
            rel.add(f if r == "." else os.path.normpath(os.path.join(r, f)))
            base.add(f)
    return rel, base


def gitignored(root, rel_paths):
    """Paths the repo deliberately does not ship (docs may still name them)."""
    out = set()
    for fname in (".gitignore", ".docs-check-ignore"):
        fp = os.path.join(root, fname)
        if not os.path.exists(fp):
            continue
        for line in open(fp, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#"):
                out.add(line.rstrip("/").lstrip("/"))
                out.add(os.path.basename(line.rstrip("/")))
    return out


def check(root):
    findings = []

    def add(path, kind, line, msg):
        findings.append((path, kind, line, msg))

    rel_paths, basenames = index_tree(root)
    ignored = gitignored(root, rel_paths)

    for dp, dn, fn in walk(root):
        for f in sorted(fn):
            if not f.endswith(".md"):
                continue
            p = os.path.join(dp, f)
            rel = os.path.relpath(p, root)
            base_dir = os.path.dirname(rel)
            lines = open(p, encoding="utf-8").read().splitlines()

            in_fence = False
            fence_open_line = 0
            fence_count = 0

            for i, line in enumerate(lines, 1):
                if fence_re.match(line):
                    fence_count += 1
                    if not in_fence:
                        in_fence, fence_open_line = True, i
                    else:
                        in_fence = False
                    continue

                if in_fence:
                    continue

                # stray ')' after a URL, but only when the line's parens
                # don't balance (so "(e.g. [x](url))" is not flagged)
                for m in url_link_re.finditer(line):
                    tail = line[m.end():]
                    if tail.startswith(")") and line.count("(") < line.count(")"):
                        add(rel, "PAREN", i, "stray ')' after link URL")

                for label, target in link_re.findall(line):
                    if target.startswith(("http://", "https://", "#", "mailto:")):
                        continue
                    t = target.split("#")[0].rstrip("/")
                    if not t or t.startswith(SKIP_PREFIX):
                        continue
                    cand = os.path.normpath(
                        os.path.join(base_dir, t) if base_dir else t)
                    if cand not in rel_paths and cand not in ignored:
                        add(rel, "LINK", i, f"[{label}]({target}) -> no such path")

                for m in ref_re.findall(line):
                    if m.startswith(SKIP_PREFIX):
                        continue
                    nm = os.path.basename(m)
                    norm = m.lstrip("./")
                    if nm in SKIP_NAMES or nm in basenames or norm in rel_paths:
                        continue
                    if norm in ignored or nm in ignored:
                        continue
                    add(rel, "REF", i, f"`{m}` matches nothing in the tree")

            if fence_count % 2:
                add(rel, "FENCE", fence_open_line,
                    f"odd number of ``` fences ({fence_count})")

    return findings


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("-")]
    warn_only = "--warn-only" in sys.argv
    root = os.path.abspath(args[0]) if args else os.getcwd()

    findings = check(root)
    name = os.path.basename(root)

    if not findings:
        print(f"{name}: no documentation drift found")
        return 0

    print(f"{name}: {len(findings)} finding(s)\n")
    for path, kind, line, msg in sorted(findings):
        print(f"  {path}:{line}: [{kind}] {msg}")
    print()
    return 0 if warn_only else 1


if __name__ == "__main__":
    sys.exit(main())
