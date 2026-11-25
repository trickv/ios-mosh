#!/usr/bin/env python3
"""Reference loader for expected.jsonl and server.jsonl, and a check of the format.

    python3 Tools/mosh-oracle/check_format.py ORACLE CORPUS_DIR

This loader is written from FORMAT.md alone. For every case it rebuilds each state
from the delta lines and compares it with the oracle's own full dump of the same
state (`mosh-oracle apply DIR --full`, `mosh-oracle server DIR --full`), key by key
and cell by cell. A difference means the delta encoding lost something or FORMAT.md
is wrong. scripts/corpus-check.sh --gen runs it.

It is also the shortest correct loader to copy from.
"""

import json
import os
import subprocess
import sys


def initial_state(width, height):
    """The state before the first line: a fresh terminal (FORMAT.md, "Initial values")."""
    return {
        "width": width,
        "height": height,
        "cursor": [0, 0],
        "combining": [0, 0],
        "default_tabs": True,
        "tabs": list(range(0, width, 8)),
        "scroll_region": [0, height - 1],
        "pen": {},
        "saved": {"cursor": [0, 0], "pen": {}, "auto_wrap_mode": True, "origin_mode": False},
        "next_print_will_wrap": False,
        "origin_mode": False,
        "auto_wrap_mode": True,
        "insert_mode": False,
        "cursor_visible": True,
        "reverse_video": False,
        "bracketed_paste": False,
        "mouse_reporting_mode": 0,
        "mouse_focus_event": False,
        "mouse_alternate_scroll": False,
        "mouse_encoding_mode": 0,
        "application_mode_cursor_keys": False,
        "icon_name": "",
        "window_title": "",
        "title_initialized": False,
        "clipboard": "",
        "bell_count": 0,
        "echo_ack": 0,
        "parser_state": "Ground",
        "utf8_buf": [],
        "params": "",
        "dispatch_chars": [],
        "parsed": False,
        "parsed_params": [],
        "osc_string": "",
    }


def expand_row(runs, width):
    """A row (array of runs) as a list of cells:
    (contents bytes, fg, bg, at, wide, fallback, wrap)."""
    cells = []
    for run in runs:
        kinds = [k for k in ("t", "c", "e") if k in run]
        assert len(kinds) == 1, run
        if "t" in run:
            assert all(0x20 <= ord(ch) <= 0x7E for ch in run["t"]) and run["t"], run
            contents = [ch.encode("ascii") for ch in run["t"]]
        elif "c" in run:
            assert run["c"], run
            contents = [text.encode("utf-8") for text in run["c"]]
        else:
            assert run["e"] >= 1, run
            contents = [b""] * run["e"]
        attrs = (run.get("fg", 0), run.get("bg", 0), run.get("at", 0),
                 run.get("wide", False), run.get("fallback", False), run.get("wrap", False))
        assert set(run) <= {"t", "c", "e", "fg", "bg", "at", "wide", "fallback", "wrap"}, run
        cells.extend((c,) + attrs for c in contents)
    assert len(cells) == width, (len(cells), width)
    return cells


def load_delta(path, width, height):
    """Yield (line, state, rows) for every line; rows is a list of expanded rows."""
    state = initial_state(width, height)
    rows = [expand_row([{"e": width}], width) for _ in range(height)]
    with open(path, encoding="utf-8") as f:
        for text in f:
            line = json.loads(text)
            resized = "width" in line or "height" in line
            for key, value in line.items():
                if key not in ("num", "rows", "reply_b64"):
                    assert key in state, key
                    state[key] = value
            listed = line.get("rows", {})
            if resized:
                assert sorted(int(k) for k in listed) == list(range(state["height"])), "all rows after a resize"
                new_rows = [None] * state["height"]
            else:
                new_rows = list(rows)
            for key, value in listed.items():
                if isinstance(value, int):
                    assert not resized
                    new_rows[int(key)] = rows[value]      # row `value` of the previous line
                else:
                    new_rows[int(key)] = expand_row(value, state["width"])
            rows = new_rows
            yield line, dict(state), rows


def load_full(text):
    for t in text.splitlines():
        line = json.loads(t)
        rows = [expand_row(r, line["width"]) for r in line["rows"]]
        assert len(rows) == line["height"]
        yield line, rows


def check(name, delta_path, full_text, width, height):
    count = 0
    full = list(load_full(full_text))
    delta = list(load_delta(delta_path, width, height))
    assert len(full) == len(delta), "%s: %d full lines, %d delta lines" % (name, len(full), len(delta))
    for (dline, state, rows), (fline, frows) in zip(delta, full):
        where = "%s line %d" % (name, count + 1)
        assert dline["num"] == fline["num"], where
        assert dline.get("reply_b64") == fline.get("reply_b64"), where
        for key, value in state.items():
            assert fline[key] == value, "%s: key %s: %r != %r" % (where, key, value, fline[key])
        assert set(fline) - {"num", "rows", "reply_b64"} == set(state), where
        assert rows == frows, "%s: rows differ" % where
        count += 1
    return count


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    oracle, corpus = sys.argv[1], sys.argv[2]
    total = 0
    for name in sorted(os.listdir(corpus)):
        d = os.path.join(corpus, name)
        if not os.path.isfile(os.path.join(d, "meta.json")):
            continue
        with open(os.path.join(d, "meta.json")) as f:
            meta = json.load(f)
        assert meta["format"] == 1
        full = subprocess.run([oracle, "apply", d, "--full"], check=True, capture_output=True).stdout.decode("utf-8")
        total += check(name + "/expected.jsonl", os.path.join(d, "expected.jsonl"), full, meta["width"], meta["height"])
        if os.path.isfile(os.path.join(d, "server.jsonl")):
            full = subprocess.run([oracle, "server", d, "--full"], check=True, capture_output=True).stdout.decode("utf-8")
            total += check(name + "/server.jsonl", os.path.join(d, "server.jsonl"), full, meta["width"], meta["height"])
    print("check_format: %d states rebuilt from delta lines equal the full dumps" % total)


if __name__ == "__main__":
    main()
