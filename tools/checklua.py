#!/usr/bin/env python3
"""Static checks a Lua parser cannot make: a local function called before it is
defined, or called and never defined at all. Both load cleanly and fail at runtime."""
import re
import sys

KEYWORDS = {"and", "or", "not", "if", "then", "else", "elseif", "end", "function",
            "return", "while", "for", "do", "local", "in", "repeat", "until", "break",
            "nil", "true", "false", "goto"}
# lowercase globals Lua and the WoW client provide
API = {"print", "date", "type", "ipairs", "pairs", "next", "wipe", "select", "tostring",
       "tonumber", "strtrim", "strsplit", "strjoin", "tinsert", "tremove", "unpack",
       "format", "load", "loadstring", "pcall", "error", "assert", "setmetatable",
       "getmetatable", "rawget", "rawset", "hooksecurefunc", "string", "math", "table",
       "os", "bit", "coroutine"}


def check(path):
    raw = open(path, encoding="utf-8").read()
    # blank out string literals: a word before "(" inside one is text, not a call
    src = re.sub(r'"(?:[^"\\\n]|\\.)*"', '""', raw)
    src = re.sub(r"'(?:[^'\\\n]|\\.)*'", "''", src)
    lines = src.split("\n")

    localfns, bound = {}, set()
    for number, line in enumerate(lines, 1):
        match = re.match(r'\s*local function ([A-Za-z_]\w*)', line)
        if match:
            localfns.setdefault(match.group(1), number)
            bound.add(match.group(1))
        for match in re.finditer(r'\blocal\s+([A-Za-z_][\w,\s]*)', line):
            bound.update(n.strip() for n in match.group(1).split(",") if n.strip())
        for match in re.finditer(r'function\s*(?:[\w.:]*)\(([^)]*)\)', line):
            bound.update(n.strip() for n in match.group(1).split(",") if n.strip())
        for match in re.finditer(r'\bfor\s+([\w,\s]+?)\s+(?:=|in)\b', line):
            bound.update(n.strip() for n in match.group(1).split(",") if n.strip())

    problems = []
    for number, line in enumerate(lines, 1):
        if line.lstrip().startswith("--"):
            continue
        for match in re.finditer(r'(?<![\w.:])([a-z][A-Za-z_]\w*)\s*\(', line):
            name = match.group(1)
            if name in KEYWORDS or name in API:
                continue
            if name in localfns:
                if number < localfns[name]:
                    problems.append("%s:%d: %s() called before its definition on line %d"
                                    % (path, number, name, localfns[name]))
            elif name not in bound:
                problems.append("%s:%d: %s() is never defined" % (path, number, name))
    return problems


found = []
for path in sys.argv[1:]:
    found += check(path)
for problem in found:
    print(problem)
print("checklua: %d file(s), %d problem(s)" % (len(sys.argv) - 1, len(found)))
sys.exit(1 if found else 0)
