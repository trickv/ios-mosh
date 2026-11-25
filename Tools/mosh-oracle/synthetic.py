#!/usr/bin/env python3
"""Hand-written session files for the "syn-*" cases of the golden corpus.

One case per family of escape sequences that mosh 1.4.0 implements (the list is in
README.md, taken from src/terminal/terminalfunctions.cc), plus parser cases: invalid
UTF-8, C1 controls, long parameter lists and OSC strings, sequences split across
state boundaries, resizes and echo acks.

    python3 Tools/mosh-oracle/synthetic.py Tests/MoshTerminalTests/Corpus

writes <corpus>/syn-NAME/session.jsonl for every case. `mosh-oracle gen` then makes
the other files (scripts/corpus-check.sh --regen does both).

Each argument of Case.feed() is one session line, and so one terminal state. The
"note" key in a session line repeats the bytes in readable form; gen ignores it.
"""

import base64
import json
import os
import sys

ESC = b"\x1b"
CSI = b"\x1b["
OSC = b"\x1b]"
BEL = b"\x07"
ST = b"\x1b\\"

MAX_STATES = 150


def raw(x):
    return x if isinstance(x, bytes) else x.encode("utf-8")


class Case:
    def __init__(self, name, width, height):
        self.name, self.width, self.height = name, width, height
        self.lines = []

    def feed(self, *chunks):
        """Each chunk (bytes, or str encoded as UTF-8) is one session line."""
        for c in chunks:
            data = raw(c)
            assert data, "empty session line in " + self.name
            self.lines.append({"bytes_b64": base64.b64encode(data).decode("ascii"),
                               "note": repr(data)[2:-1]})
        return self

    def split(self, data, n=1):
        """Feed data in pieces of n bytes, one session line each."""
        data = raw(data)
        return self.feed(*[data[i:i + n] for i in range(0, len(data), n)])

    def resize(self, w, h):
        self.lines.append({"resize": [w, h]})
        return self

    def ack(self, n):
        self.lines.append({"echo_ack": n})
        return self

    def write(self, corpus):
        assert 8 <= len(self.lines) <= MAX_STATES, "%s has %d lines" % (self.name, len(self.lines))
        d = os.path.join(corpus, "syn-" + self.name)
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "session.jsonl"), "w", encoding="ascii") as f:
            f.write(json.dumps({"width": self.width, "height": self.height}, separators=(",", ":")) + "\n")
            for line in self.lines:
                f.write(json.dumps(line, separators=(",", ":")) + "\n")


def cup(row, col):
    return CSI + b"%d;%dH" % (row, col)


def fill(width, height, start=ord("a")):
    """Fill the whole screen with letters, one row per letter, without scrolling."""
    out = b""
    for y in range(height):
        out += cup(y + 1, 1) + bytes([start + y % 26]) * width
    return out


CASES = []


def case(name, width, height):
    c = Case(name, width, height)
    CASES.append(c)
    return c


# ---------------------------------------------------------------- C0 controls
c = case("c0", 20, 6)
c.feed(b"abc", b"\x08", b"X", b"\x08\x08\x08\x08\x08", b"Y")           # BS, BS clamps at column 0
c.feed(b"\tT", b"\t\t\t\tE", b"\rCR")                                 # HT to the stops and to the last column, CR
c.feed(b"\nLF", b"\x0bVT", b"\x0cFF")                                 # LF, VT and FF are the same function
c.feed(b"\n\n\n\n\n", b"scrolled")                                    # LF at the bottom scrolls
c.feed(BEL, BEL + BEL + BEL, b"bell" + BEL + b"s")                    # BEL counts
c.feed(b"\x00", b"n\x00ul", b"\x7f", b"d\x7fel")                      # NUL and DEL print nothing
c.feed(b"\x01\x02\x03\x04\x05\x06", b"\x0e\x0f", b"\x1c\x1d\x1e\x1f")  # C0 without a function
c.feed(b"\r\n" + b"x" * 20, b"\x05", b"Z")                            # an unknown control clears the pending wrap
c.feed(b"\r\n" + b"y" * 20, b"\x08", b"W")                            # BS after the last column
c.feed(b"\r\n" + b"z" * 20, b"\r", b"V")                              # CR after the last column
c.feed(b"\r\n" + b"w" * 20, b"\n", b"U")                              # LF after the last column
c.feed(b"\x18", b"\x1a", b"can" + b"\x18" + b"sub" + b"\x1a" + b"end")  # CAN and SUB outside a sequence
c.feed(b"\r\n\r\n\r\n", b"last\r", b"\n")

# ------------------------------------------------------------ cursor movement
c = case("cursor", 20, 8)
c.feed(cup(3, 5) + b"A", CSI + b"H" + b"B", CSI + b";7H" + b"C", CSI + b"4H" + b"D")   # CUP with defaults
c.feed(CSI + b"0;0H" + b"E", CSI + b"99;99H" + b"F", CSI + b"5;5f" + b"G")             # zero, clamped, HVP
c.feed(cup(4, 10), CSI + b"A" + b"1", CSI + b"3A" + b"2", CSI + b"99A" + b"3", CSI + b"0A" + b"4")  # CUU
c.feed(cup(4, 10), CSI + b"B" + b"1", CSI + b"2B" + b"2", CSI + b"99B" + b"3", CSI + b"0B" + b"4")  # CUD
c.feed(cup(4, 10), CSI + b"C" + b"1", CSI + b"5C" + b"2", CSI + b"99C" + b"3", CSI + b"0C" + b"4")  # CUF
c.feed(cup(4, 10), CSI + b"D" + b"1", CSI + b"4D" + b"2", CSI + b"99D" + b"3", CSI + b"0D" + b"4")  # CUB
c.feed(CSI + b"3d" + b"v", CSI + b"d" + b"w", CSI + b"99d" + b"x")                     # VPA
c.feed(CSI + b"7G" + b"g", CSI + b"G" + b"h", CSI + b"99G" + b"i")                     # CHA
c.feed(CSI + b"9`" + b"j", CSI + b"`" + b"k", CSI + b"99`" + b"l")                     # HPA
c.feed(CSI + b"8;1H", CSI + b"B" + b"n", CSI + b"1;1H", CSI + b"A" + b"o")             # no scrolling at the edges
c.feed(CSI + b"2;6r", CSI + b"?6h", cup(1, 1) + b"O", cup(99, 1) + b"P", CSI + b"99A" + b"Q", CSI + b"99B" + b"R")  # origin mode
c.feed(CSI + b"3d" + b"S", CSI + b"?6l", cup(1, 1) + b"T", CSI + b"r")
c.feed(CSI + b"1", b"2;", b"5", b"H", b"split")                                         # split across states
c.feed(cup(5, 20) + b"e", CSI + b"C" + b"f", CSI + b"D" + b"g")                         # moves after the last column

# -------------------------------------------------------------------- erasing
c = case("erase", 20, 8)
c.feed(fill(20, 8))
c.feed(cup(1, 10) + CSI + b"K", cup(2, 10) + CSI + b"0K", cup(3, 10) + CSI + b"1K", cup(4, 10) + CSI + b"2K")  # EL
c.feed(cup(5, 10) + CSI + b"3K", cup(5, 20) + CSI + b"K", cup(6, 1) + CSI + b"1K")      # invalid parameter; edges
c.feed(CSI + b"44m" + cup(7, 5) + CSI + b"K", CSI + b"42m" + cup(8, 15) + CSI + b"1K", CSI + b"0m")  # erase with a background
c.feed(fill(20, 8, ord("A")))
c.feed(cup(4, 10) + CSI + b"J", fill(20, 8, ord("a")), cup(4, 10) + CSI + b"1J")        # ED 0, ED 1
c.feed(fill(20, 8, ord("A")), CSI + b"45m" + cup(4, 10) + CSI + b"2J", CSI + b"0m")     # ED 2 keeps the cursor
c.feed(fill(20, 8), cup(4, 10) + CSI + b"3J", cup(4, 10) + CSI + b"0J")                 # ED 3 is not implemented
c.feed(fill(20, 8, ord("A")))
c.feed(cup(1, 5) + CSI + b"X", cup(2, 5) + CSI + b"5X", cup(3, 5) + CSI + b"99X", cup(4, 5) + CSI + b"0X")  # ECH
c.feed(CSI + b"48;5;200m" + cup(5, 5) + CSI + b"3X", CSI + b"48;2;1;2;3m" + cup(6, 18) + CSI + b"9X", CSI + b"0m")
c.feed(cup(7, 1) + "漢字漢字".encode(), cup(7, 2) + CSI + b"X", cup(7, 5) + CSI + b"2X")  # ECH on half of a wide character
c.feed(cup(1, 1) + b"q" * 25, cup(1, 10) + CSI + b"1K", cup(1, 10) + CSI + b"K")        # the wrap flag and EL
c.feed(cup(3, 1) + b"r" * 25, cup(3, 20) + CSI + b"X", cup(5, 1) + b"s" * 25, cup(5, 1) + CSI + b"2K")
c.split(cup(8, 3) + CSI + b"1K")

# ----------------------------------------------------------------------- SGR
c = case("sgr", 40, 12)
c.feed(CSI + b"1mbold", CSI + b"22m off ", CSI + b"3mitalic", CSI + b"23m off ", CSI + b"4munder", CSI + b"24m off")
c.feed(b"\r\n" + CSI + b"5mblink", CSI + b"25m off ", CSI + b"7minverse", CSI + b"27m off ", CSI + b"8mhid", CSI + b"28m off")
c.feed(b"\r\n" + CSI + b"2mfaint", CSI + b"9mstrike", CSI + b"21mdouble", CSI + b"53mover", CSI + b"0m")  # not implemented
c.feed(b"\r\n" + b"".join(CSI + b"%dm%d" % (n, n % 10) for n in range(30, 38)) + CSI + b"39m.")
c.feed(b"".join(CSI + b"%dm%d" % (n, n % 10) for n in range(40, 48)) + CSI + b"49m.")
c.feed(b"\r\n" + b"".join(CSI + b"%dm%d" % (n, n % 10) for n in range(90, 98)) + CSI + b"39m.")
c.feed(b"".join(CSI + b"%dm%d" % (n, n % 10) for n in range(100, 108)) + CSI + b"49m.")
c.feed(b"\r\n" + b"".join(CSI + b"38;5;%dm#" % n for n in (0, 7, 8, 15, 16, 196, 231, 232, 255)) + CSI + b"0m")
c.feed(b"".join(CSI + b"48;5;%dm " % n for n in (0, 7, 8, 15, 16, 21, 231, 232, 255)) + CSI + b"0m")
c.feed(b"\r\n" + CSI + b"38;5;256mA", CSI + b"38;5mB", CSI + b"38mC", CSI + b"38;5;mD", CSI + b"0m")   # bad 256-colour forms
c.feed(b"\r\n" + CSI + b"38;2;1;2;3mA", CSI + b"48;2;4;5;6mB", CSI + b"38;2;0;0;0mC", CSI + b"48;2;255;255;255mD", CSI + b"0m")
c.feed(b"\r\n" + CSI + b"38;2;300;300;300mA", CSI + b"38;2;65535;65535;65535mB", CSI + b"38;2;1;2mC",
       CSI + b"0m", CSI + b"48;2;;;mD", CSI + b"0m")                                                  # true colour edge cases
c.feed(b"\r\n" + CSI + b"mA", CSI + b"0;1;4;31;42mB", CSI + b"1;;4mC", CSI + b";mD", CSI + b"0m")     # empty parameters reset
c.feed(b"\r\n" + CSI + b"38;5;196;48;5;21mA", CSI + b"1;38;2;10;20;30;4;48;5;99;7mB", CSI + b"0m")
c.feed(b"\r\n" + CSI + b"38:5:196mA", CSI + b"4:3mB", CSI + b"31:1mC", CSI + b"0m")                   # a colon makes mosh ignore the CSI
c.feed(b"\r\n" + CSI + b"31;1m" + b"p" * 40, CSI + b"44m", b"q")                                      # SGR keeps the pending wrap
c.feed(CSI + b"0m", b"\r\n", CSI + b"7;35;4" + b"6m", b"split", CSI + b"m")
c.feed(CSI + b"41m" + b"\r\n\r\n\r\n", b"bg scroll", CSI + b"0m")                                     # new rows take the background

# ---------------------------------------------------------------------- tabs
c = case("tabs", 40, 6)
c.feed(b"\tA", b"\tB", b"\t\tC", b"\r" + cup(1, 4), ESC + b"H", b"\r\tD")              # HTS at column 3
c.feed(b"\r\n" + CSI + b"I" + b"a", CSI + b"3I" + b"b", CSI + b"0I" + b"c", CSI + b"99I" + b"d")   # CHT
c.feed(b"\r\n" + cup(2, 30), CSI + b"Z" + b"e", CSI + b"2Z" + b"f", CSI + b"0Z" + b"g", CSI + b"99Z" + b"h")  # CBT
c.feed(cup(3, 9), CSI + b"g", b"\r\tI", cup(3, 17), CSI + b"0g", b"\r\t\tJ")           # TBC at the cursor
c.feed(cup(3, 12) + b"\xc2\x88", b"\r\t\tK")                                           # HTS as a C1 control
c.resize(60, 6)
c.feed(b"\r\n\t\t\t\t\t\t\tL")                                                         # new columns get default stops
c.feed(CSI + b"3g", b"\r\n\tM", cup(5, 6) + ESC + b"H", b"\r\tN")                       # TBC 3, then one stop
c.resize(80, 6)
c.feed(b"\r\tO\tP")                                                                    # no default stops any more
c.resize(20, 6)
c.feed(b"\r\n\tQ\tR")
c.feed(cup(1, 1) + b"t" * 20, b"\t", b"S", CSI + b"I", b"T", CSI + b"g", b"U")          # HT, CHT and TBC keep the pending wrap
c.feed(ESC + b"c", b"\tV\tW")                                                          # RIS brings the default stops back

# ------------------------------------------------------- scrolling and regions
c = case("scroll", 20, 8)
c.feed(fill(20, 8))
c.feed(CSI + b"2;5r", b"X", cup(5, 1) + b"\n", b"Y", b"\n\n", b"Z")                     # DECSTBM homes; LF scrolls the region
c.feed(cup(7, 1) + b"\n", b"1", b"\n", b"2", b"\n", b"3")                               # below the region: no scroll at the bottom
c.feed(cup(2, 1) + ESC + b"M", b"4", ESC + b"M", b"5", cup(1, 1) + ESC + b"M", b"6")    # RI at the top of the region
c.feed(cup(5, 3) + ESC + b"D", b"7", ESC + b"E", b"8", cup(5, 3) + b"\x0b", b"9", b"\x0c", b"0")  # IND, NEL, VT, FF
c.feed(fill(20, 8, ord("A")))
c.feed(CSI + b"S", CSI + b"2S", CSI + b"T", CSI + b"3T", CSI + b"0S", CSI + b"99S")     # SU and SD inside the region
c.feed(fill(20, 8))
c.feed(cup(3, 5) + CSI + b"L", b"i", CSI + b"2L", b"j", cup(7, 5) + CSI + b"L", b"k", cup(3, 5) + CSI + b"99L", b"l")  # IL
c.feed(fill(20, 8, ord("A")))
c.feed(cup(3, 5) + CSI + b"M", b"m", CSI + b"3M", b"n", cup(1, 5) + CSI + b"M", b"o", cup(2, 5) + CSI + b"99M", b"p")  # DL
c.feed(CSI + b"5;2r", b"a", CSI + b"9;9r", b"b", CSI + b"30;40r", b"c", CSI + b"0;1r", b"d")  # invalid regions are ignored
c.feed(CSI + b";4r", b"e", CSI + b"3r", b"f", CSI + b"r", b"g", CSI + b"1;8r", b"h")
c.feed(CSI + b"3;6r" + CSI + b"46m" + cup(6, 1) + b"\n\n", CSI + b"S", CSI + b"T", CSI + b"L", CSI + b"M", CSI + b"0m" + CSI + b"r")  # background in new rows
c.feed(fill(20, 8))
c.feed(CSI + b"4;6r" + CSI + b"?6h", b"O", cup(3, 1) + b"\n", b"P", CSI + b"?6l", cup(8, 1) + b"Q", CSI + b"r")
c.feed(cup(8, 1) + b"\n\n\n", b"end")

# ----------------------------------------------- insert and delete characters
c = case("insdel", 20, 6)
c.feed(fill(20, 6))
c.feed(cup(1, 5) + CSI + b"@", cup(2, 5) + CSI + b"3@", cup(3, 5) + CSI + b"99@", cup(4, 20) + CSI + b"@", cup(5, 1) + CSI + b"0@")  # ICH
c.feed(fill(20, 6, ord("A")))
c.feed(cup(1, 5) + CSI + b"P", cup(2, 5) + CSI + b"4P", cup(3, 5) + CSI + b"99P", cup(4, 20) + CSI + b"P", cup(5, 1) + CSI + b"0P")  # DCH
c.feed(CSI + b"43m" + cup(6, 5) + CSI + b"2P", cup(6, 10) + CSI + b"2@", CSI + b"0m")   # blank cells take the background
c.feed(cup(1, 1) + CSI + b"2K" + b"0123456789", cup(1, 4) + CSI + b"4h", b"abc", b"de", CSI + b"4l", b"XY")  # IRM
c.feed(cup(2, 1) + CSI + b"2K" + b"0123456789abcdefghi", cup(2, 18) + CSI + b"4h", b"12345", CSI + b"4l")   # insert at the margin
c.feed(cup(3, 1) + CSI + b"2K" + b"0123456789", cup(3, 4) + CSI + b"4h", "漢".encode(), "字x".encode(), CSI + b"4l")
c.feed(cup(4, 1) + CSI + b"2K" + "0123456789abcdefg漢".encode(), cup(4, 4) + CSI + b"@", CSI + b"@", CSI + b"P")  # a wide character pushed over the edge
c.feed(cup(5, 1) + b"w" * 25, cup(5, 5) + CSI + b"P", b"1", cup(5, 5) + CSI + b"@", b"2", cup(5, 5) + CSI + b"2P", cup(5, 5) + CSI + b"@")  # DCH and ICH move the wrap bit
c.resize(19, 6)
c.feed(b"3")
c.resize(20, 6)
c.split(cup(1, 2) + CSI + b"2@" + CSI + b"1P")

# --------------------------------------------------------------------- modes
c = case("modes", 20, 6)
c.feed(CSI + b"?1h", b"a", CSI + b"?1l", b"b")                                          # DECCKM
c.feed(CSI + b"?5h", b"c", CSI + b"?5l", b"d")                                          # reverse video
c.feed(CSI + b"?25l", b"e", CSI + b"?25h", b"f")                                        # cursor visible
c.feed(CSI + b"?2004h", b"g", CSI + b"?2004l", b"h")                                    # bracketed paste
c.feed(CSI + b"?1004h", b"i", CSI + b"?1004l", b"j")                                    # focus events
c.feed(CSI + b"?1007h", b"k", CSI + b"?1007l", b"l")                                    # alternate scroll
c.feed(CSI + b"?9h", CSI + b"?1000h", CSI + b"?1001h", CSI + b"?1002h", CSI + b"?1003h", CSI + b"?9l")   # mouse reporting
c.feed(CSI + b"?1002h", CSI + b"?1000l", CSI + b"?1003h", CSI + b"?1003l")              # any mouse reset turns reporting off
c.feed(CSI + b"?1005h", CSI + b"?1006h", CSI + b"?1015h", CSI + b"?1005l", CSI + b"?1006h", CSI + b"?1006l")  # mouse encoding
c.feed(CSI + b"?1000;1006;2004;1004h", b"m", CSI + b"?1000;1006;2004;1004l", b"n")      # several in one sequence
c.feed(b"\r\n" + CSI + b"?7l", b"o" * 25, b"\r\n" + CSI + b"?7h", b"p" * 25)            # auto wrap off and on
c.feed(b"\r\n" + CSI + b"4h", b"q", b"\r" + b"r", CSI + b"4l", b"\r" + b"s")            # insert mode
c.feed(CSI + b"20h", CSI + b"4;20h", b"\rt", CSI + b"4;20l", b"\ru")                    # other ANSI modes are ignored
c.feed(CSI + b"2;4r" + CSI + b"?6h", b"v", CSI + b"?6l", b"w", CSI + b"r")              # origin mode homes the cursor
c.feed(fill(20, 6), cup(3, 7) + CSI + b"?3h", b"x", fill(20, 6, ord("A")), cup(3, 7) + CSI + b"?3l", b"y")  # DECCOLM clears
c.feed(CSI + b"?47h", CSI + b"?1047h", CSI + b"?1049h", CSI + b"?2026h", CSI + b"?12h", CSI + b"?h", CSI + b"?0h")  # not implemented
c.feed(CSI + b"?1049l", CSI + b"?25;1049;5h", b"z", CSI + b"?25;5l", CSI + b"?25h")
c.feed(cup(6, 1) + b"u" * 20, CSI + b"?25l", b"V", cup(6, 1) + b"v" * 20, CSI + b"?6h", b"W", CSI + b"?6l" + CSI + b"?25h")  # DECSET keeps the pending wrap
c.split(CSI + b"?1002;1006h")
c.feed(CSI + b"?1002l" + CSI + b"?1006l")

# ------------------------------------------------- save and restore the cursor
c = case("savecursor", 20, 8)
c.feed(ESC + b"8", b"a")                                                               # DECRC with nothing saved
c.feed(cup(3, 7) + CSI + b"1;31;44m", ESC + b"7", cup(6, 2) + CSI + b"0;32m" + b"b", ESC + b"8", b"c")
c.feed(CSI + b"0m" + cup(8, 20) + b"d", ESC + b"7", cup(1, 1) + b"e", ESC + b"8", b"f")  # saved in the last column
c.feed(CSI + b"?7l", ESC + b"7", CSI + b"?7h", ESC + b"8", cup(4, 1) + b"g" * 25, CSI + b"?7h")  # auto wrap is saved
c.feed(CSI + b"2;6r" + CSI + b"?6h" + cup(2, 3), ESC + b"7", CSI + b"?6l" + cup(8, 1) + b"h", ESC + b"8", b"i", CSI + b"?6l" + CSI + b"r")  # origin mode is saved
c.feed(cup(8, 20), ESC + b"7")
c.resize(10, 4)
c.feed(ESC + b"8", b"j")                                                               # restored into a smaller window
c.resize(20, 8)
c.feed(ESC + b"8", b"k")
c.feed(cup(5, 5) + CSI + b"35m", ESC + b"7", CSI + b"!p", ESC + b"8", b"l")             # DECSTR forgets the saved cursor
c.feed(cup(5, 5) + CSI + b"36m", ESC + b"7", ESC + b"c", ESC + b"8", b"m")              # so does RIS
c.split(cup(2, 2) + ESC + b"7" + cup(7, 7) + ESC + b"8" + b"n")

# --------------------------------------------------------------------- resets
c = case("reset", 20, 6)
c.feed(fill(20, 6), OSC + b"0;title" + BEL, OSC + b"1;icon" + BEL, OSC + b"52;c;Y2xpcA==" + BEL, BEL)
c.feed(CSI + b"1;33;45m", CSI + b"2;4r", CSI + b"?6h", CSI + b"4h", CSI + b"?25l", CSI + b"?1h", cup(2, 5) + ESC + b"7")
c.feed(CSI + b"?5h" + CSI + b"?2004h" + CSI + b"?1002h" + CSI + b"?1006h" + CSI + b"?1004h" + CSI + b"?1007h" + CSI + b"?7l")
c.feed(CSI + b"3g", cup(2, 3) + ESC + b"H", b"x")
c.feed(CSI + b"!p", b"after soft reset", ESC + b"8", b"y")                              # DECSTR
c.feed(CSI + b"1;33;45m" + CSI + b"2;4r" + CSI + b"?6h" + CSI + b"4h" + CSI + b"?25l" + CSI + b"?1h", cup(1, 5) + ESC + b"7")
c.feed(ESC + b"c", b"after hard reset", b"\tz", ESC + b"8", b"w")                       # RIS
c.feed(OSC + b"2;again" + BEL, OSC + b"52;c;YWdhaW4=" + BEL, BEL, ESC + b"c", BEL)       # RIS keeps icon name and bell count
c.feed(ESC + b"#8", CSI + b"42m" + ESC + b"#8", CSI + b"0m" + cup(3, 3) + b"mid")        # DECALN
c.feed(cup(4, 1) + "漢字".encode(), ESC + b"#8", ESC + b"#3", ESC + b"#9", b"q")
c.feed(ESC + b"c", ESC, b"c", CSI + b"!", b"p", b"end")

# ----------------------------------------------------------------------- OSC
c = case("osc", 40, 6)
c.feed(OSC + b"0;both" + BEL, OSC + b"1;icon" + BEL, OSC + b"2;title" + BEL, OSC + b"2;with ST" + ST)
c.feed(OSC + b"0;c1 st" + b"\xc2\x9c", b"\xc2\x9d" + b"2;c1 osc" + BEL, OSC + b";no number" + BEL)
c.feed(OSC + b"0" + BEL, OSC + BEL, OSC + b"3;three" + BEL, OSC + b"10;?" + BEL, OSC + b"00;x" + BEL, OSC + b"7;file:///" + BEL)  # ignored
c.feed(OSC + b"2;" + b"t" * 300 + BEL, OSC + b"0;" + b"u" * 254 + BEL, OSC + b"1;" + b"v" * 255 + BEL)  # cut at 256 with the prefix
c.feed(OSC + "0;tïtle 漢字 😀".encode() + BEL, OSC + b"2;a;b;c" + BEL, OSC + b"2;del\x7fete" + BEL)
c.feed(OSC + b"2;line\nfeed\ttab" + BEL, OSC + b"2;can" + b"\x18" + b"cel", OSC + b"2;esc" + CSI + b"31m" + b"red" + CSI + b"0m")  # controls inside
c.feed(OSC + b"2;sub" + b"\x1a" + b"stitute", OSC + b"2;c1 inside" + b"\xc2\x85" + b"x", OSC + b"2;" + BEL, OSC + b"0;" + BEL)
c.feed(OSC + b"1;same" + BEL, OSC + b"2;same" + BEL, OSC + b"1;icon only" + BEL, b"x", OSC + b"2;title only" + BEL)
c.feed(OSC + b"52;c;aGVsbG8=" + BEL, OSC + b"52;c;aGVsbG8=" + BEL, OSC + b"52;c;d29ybGQ=" + ST)   # clipboard
c.feed(OSC + b"52;;ZHJvcHBlZA==" + BEL, OSC + b"52;p;ZHJvcHBlZA==" + BEL, OSC + b"52;c" + BEL, OSC + b"52" + BEL, OSC + b"5;c;x" + BEL)  # dropped
c.feed(OSC + b"52;c;?" + BEL, OSC + b"52;c;not base64 !!" + BEL, OSC + b"52;c;" + BEL, OSC + "52;c;grüße 漢".encode() + BEL)
c.feed(OSC + b"2;52;c;title" + BEL, OSC + b"52;c;x" + BEL + OSC + b"52;c;y" + BEL, OSC + b"52;c;x" + BEL + OSC + b"52;c;y" + BEL)
c.feed(OSC + b"52;c;" + b"A" * 6000, b"B" * 6000, b"C" * 8000 + BEL, b"after")          # cut at 16384 with the prefix
c.feed(OSC + b"0;" + b"w" * 9000, b"x" * 9000 + BEL, OSC + b"52;c;small" + BEL)
c.split(OSC + b"2;split" + BEL)
c.split(OSC + b"52;c;QQ==" + ST)

# --------------------------------------------------------------------- UTF-8
c = case("utf8", 20, 10)
c.feed("é€😀".encode(), b"\r\n")
c.split("é€😀".encode())                                                               # every byte in its own state
c.feed(b"\r\n" + b"\x80", b"\xbf", b"a\x80b", b"\r\n")                                 # lone continuation bytes
c.feed(b"\xc0\xaf", b"\xc1\xbf", b"\xe0\x80\xaf", b"\xf0\x80\x80\xaf", b"\r\n")        # overlong forms
c.feed(b"\xe2\x82", b"A", b"\xf0\x9f\x98", b"B", b"\xc3", b"C", b"\r\n")               # truncated, then ASCII
c.feed(b"\xed\xa0\x80", b"\xed\xbf\xbf", b"\xf4\x90\x80\x80", b"\xf7\xbf\xbf\xbf", b"\r\n")  # surrogates, above U+10FFFF
c.feed(b"\xf8\x88\x80\x80\x80", b"\xfc\x84\x80\x80\x80\x80", b"\xfe", b"\xff", b"\r\n")  # five and six byte forms
c.feed(b"\xc3", b"\xa9", b"\xe2", b"\x82", b"\xac", b"\xe2\x28\xa1", b"\xc3\xc3\xa9", b"\r\n")  # split, and broken by a new lead byte
c.feed(b"\xe2\x82" + ESC + b"[31m" + b"r", b"\xf0\x9f" + b"\n", b"\xe2" + b"\x18" + b"x", CSI + b"0m\r\n")  # broken by a control
c.feed("�".encode(), b"\xef\xbf\xbf", b"\xef\xbf\xbe", "﻿".encode(), "a​b".encode(), "c­d".encode(), b"\r\n")
c.feed(b"\xc2\xa0", "  ".encode(), "\U0010ffff".encode(), "\U000e0001".encode(), " x".encode(), b"\r\n")
c.feed(b"\xe2", b"\x82")
c.resize(30, 10)
c.feed(b"\xac", b"!")                                                                  # a resize inside a character
c.feed(CSI + b"\xe2\x82\xac", b"m", CSI + b"3\xc3\xa9", b"n")                           # UTF-8 where a CSI final byte belongs

# ------------------------------------------------------------- C1 and strings
c = case("c1", 20, 8)
c.feed(b"ab" + b"\xc2\x84" + b"cd", b"\xc2\x85" + b"ef", cup(1, 6) + b"\xc2\x88", b"\r\tg", cup(1, 1) + b"\xc2\x8d" + b"h")  # IND NEL HTS RI
c.feed(b"\xc2\x9b" + b"31m" + b"red", b"\xc2\x9b" + b"0m", b"\xc2\x9b" + b"3;3H" + b"i", b"\xc2\x9d" + b"2;c1 title" + b"\xc2\x9c")
c.feed(b"\xc2\x90" + b"1$r0m" + b"\xc2\x9c", b"j", b"\xc2\x98" + b"sos" + b"\xc2\x9c", b"k", b"\xc2\x9e" + b"pm" + ST, b"l", b"\xc2\x9f" + b"apc" + ST, b"m")
c.feed(b"\xc2\x80", b"\xc2\x8e", b"\xc2\x8f", b"\xc2\x91", b"\xc2\x97", b"\xc2\x99", b"\xc2\x9a", b"\xc2\x9c", b"n")  # C1 without a function
c.feed(cup(4, 1) + b"x" * 20, b"\xc2\x86", b"o")                                       # an unknown C1 clears the pending wrap
c.feed(cup(5, 1) + b"p" + ESC + b"D" + b"q", ESC + b"E" + b"r", cup(5, 9) + ESC + b"H", b"\r\ts", cup(1, 1) + ESC + b"M" + b"t")  # 7-bit forms
c.feed(ESC + b"P" + b"q#0;2;0;0;0#0!10~" + ST, b"u", ESC + b"X" + b"sos text" + ST, b"v", ESC + b"^" + b"pm" + ST, b"w", ESC + b"_" + b"apc" + ST, b"x")
c.feed(ESC + b"P" + b"1;2|data" + BEL + b"still dcs" + ST, b"y", ESC + b"_" + b"apc with\nnewline" + b"\x18", b"z")
c.feed(ESC + b"N", ESC + b"O", ESC + b"Z", ESC + b"\\", ESC + b"=", ESC + b">", ESC + b"(B", ESC + b")0", ESC + b"%G", b"A")  # no function
c.feed(CSI + b"3" + b"\x18" + b"1mB", CSI + b"3" + b"\x1a" + b"2mC", CSI + b"3" + CSI + b"1mD", CSI + b"0m")  # CAN, SUB, ESC inside a CSI
c.feed(CSI + b"3" + b"\n" + b"1mE", CSI + b"\r" + b"32mF", CSI + b"3" + BEL + b"3mG", CSI + b"0m")             # C0 inside a CSI executes
c.feed(ESC + b"\x18" + b"H", ESC + ESC + b"[35mI", ESC + b"\n" + b"7", ESC + b" " + b"\r" + b"F", CSI + b"0m")
c.feed(ESC + b"P" + b"0;1" + b"\x1a" + b"J", b"\xc2\x90" + b":" + b"xyz" + b"\xc2\x9c" + b"K", ESC + b"P" + b" " + b"q" + ST + b"L")
c.split(b"\xc2\x9b" + b"1;34m" + b"M" + b"\xc2\x9d" + b"0;s" + b"\xc2\x9c" + ESC + b"P" + b"x" + ST)

# ----------------------------------------------- wide and combining characters
c = case("wide", 20, 10)
c.feed("漢".encode(), "字x".encode(), cup(1, 19) + "漢".encode(), b"y")                  # a wide character that just fits
c.feed(cup(2, 20) + "漢".encode(), b"z")                                                # no room: wraps without the flag
c.feed(cup(3, 1) + b"a" * 19, "漢".encode(), b"b")
c.feed(cup(5, 1) + b"c" * 20, "漢".encode(), b"d")                                      # pending wrap, then a wide character
c.feed(CSI + b"?7l" + cup(7, 20) + "漢".encode(), b"e", cup(7, 19) + "字".encode(), "漢".encode(), CSI + b"?7h")  # auto wrap off
c.feed(cup(8, 1) + "漢字漢字".encode(), cup(8, 1) + b"f", cup(8, 4) + b"g", cup(8, 6) + "漢".encode())  # overwriting halves
c.feed(cup(9, 1) + b"e", "́".encode(), "̂̃".encode(), b"x" + "̈".encode())      # combining marks
c.feed(cup(10, 1) + "́".encode(), b"h", cup(10, 10) + "́̂".encode(), b"i")           # on an empty cell
c.feed(cup(9, 10) + "漢".encode(), "́".encode(), cup(9, 15) + b"j" + CSI + b"D", "́".encode())  # on a wide cell; after a move
c.feed(cup(10, 15) + b"k", cup(10, 15) + CSI + b"X", "́".encode(), b"l")                       # after the cell was erased
c.feed(cup(1, 1) + CSI + b"2J" + b"a" + "́".encode() * 10, "́".encode() * 10, "̂".encode())  # a cell holds at most 32 bytes
c.feed(cup(2, 1) + "a​b‍c️d".encode(), cup(3, 1) + "😀👍🏽".encode(), "👨‍👩‍👧".encode(), "🇮🇪".encode())
c.feed(cup(4, 1) + "한국어".encode(), "각".encode(), "สวัสดี".encode(), "नमस्ते".encode())
c.feed(cup(5, 20) + b"m", "́".encode(), b"n", cup(6, 19) + "漢".encode(), "́".encode(), b"o")  # combining in the last column
c.feed(cup(7, 1) + CSI + b"4h" + "漢字".encode(), cup(7, 2) + b"p", cup(7, 1) + "漢".encode(), CSI + b"4l")  # wide in insert mode
c.feed(cup(8, 18) + b"q")
c.resize(10, 10)
c.feed("́".encode(), b"r")                                                        # the combining cell is gone after a resize
c.resize(20, 10)
c.feed(cup(9, 1) + "±§°α→".encode(), " ".encode(), "­".encode(), CSI + b"31;42m" + "漢".encode() + CSI + b"0m")
c.split(cup(10, 1) + "漢é".encode())

# ---------------------------------------------------------------------- wrap
c = case("wrap", 10, 6)
c.feed(b"0123456789", b"a", b"bcdefghij", b"k")                                        # pending wrap, then the flag
c.feed(cup(3, 1) + b"0123456789", CSI + b"A", b"l")                                    # a cursor move clears it
c.feed(cup(4, 1) + b"0123456789", CSI + b"31m", b"m", CSI + b"0m")                     # SGR does not
c.feed(cup(1, 10) + b"n", cup(1, 10) + b"o")                                           # rewriting the last cell clears the flag
c.feed(cup(2, 1) + b"p" * 25)                                                          # three rows
c.feed(cup(6, 1) + b"q" * 15, b"r" * 10, b"s")                                         # wrapping at the bottom scrolls
c.feed(CSI + b"?7l", cup(1, 1) + b"t" * 15, b"u", CSI + b"?7h", b"v", b"w")             # auto wrap off: the last cell is rewritten
c.feed(cup(3, 1) + b"0123456789", CSI + b"?7l", b"x", CSI + b"?7h", b"y")
c.feed(cup(4, 1) + b"z" * 10, CSI + b"K", b"A", cup(4, 10) + CSI + b"K", cup(5, 1) + b"B" * 12, cup(5, 1) + CSI + b"2K")  # EL and the flag
c.feed(cup(1, 1) + CSI + b"2J" + b"C" * 10 + b"D" * 10 + b"E" * 5)
c.resize(12, 6)
c.feed(b"F")                                                                           # a new width clears the flags
c.resize(10, 6)
c.feed(cup(1, 1) + b"G" * 12)
c.resize(10, 3)
c.feed(b"H")                                                                           # a new height does not
c.resize(10, 6)
c.feed(cup(3, 1) + b"I" * 10 + b"\r\n" + b"J", cup(5, 1) + b"K" * 10 + b"\n" + b"L", cup(6, 1) + b"M" * 9, b"N", b"\b", b"O")
c.feed(cup(6, 1) + b"P" * 10, b"\t", b"Q")                                             # HT keeps the pending wrap

# ---------------------------------------------------- parameters and oddities
c = case("params", 20, 6)
c.feed(CSI + b"1;" * 60 + b"H" + b"a", CSI + b"3;" + b"0" * 120 + b"5H" + b"b", CSI + b";" * 120 + b"H" + b"c")  # over 100 characters
c.feed(CSI + b"99999;5H" + b"d", CSI + b"65535;5H" + b"e", CSI + b"3;65536H" + b"f", CSI + b"3;" + b"9" * 30 + b"H" + b"g")  # above the limit
c.feed(CSI + b"00004;00007H" + b"h", CSI + b";;;5H" + b"i", CSI + b"5;H" + b"j", CSI + b"2;3;4;5;6;7;8;9H" + b"k")
c.feed(CSI + b" q", CSI + b"2 q", CSI + b"\"q", CSI + b"!!!!!!!!!!p", CSI + b"1$p", CSI + b"?1$p", b"l")       # intermediates
c.feed(CSI + b">c", CSI + b"=c", CSI + b"<1m", CSI + b">4;2m", CSI + b"?u", CSI + b">1u", CSI + b"=5u", b"m")  # private markers
c.feed(CSI + b"1?h", CSI + b"1;?5h", CSI + b"1:2m", CSI + b"?5:1h", CSI + b" 1m", CSI + b"1 2m", b"n")         # CSI ignored
c.feed(CSI + b"1~", CSI + b"200~", CSI + b"1{", CSI + b"1|", CSI + b"1}", CSI + b"@", CSI + b"1^", b"o")       # final bytes
c.feed(CSI + b"1" + "é".encode(), b"p", CSI + b"1" + "漢".encode(), b"q", CSI + "é".encode(), b"r", CSI + b"?" + "é".encode(), b"s")
c.feed(CSI + b"3\x7f1m" + b"t", CSI + b"\x7f\x7f0m", CSI + b"3\x001m" + b"u", CSI + b"0m")                     # DEL and NUL inside
c.feed(CSI + b"c", CSI + b"0c", CSI + b">c", CSI + b">0c", CSI + b"5n", CSI + b"6n", cup(4, 9) + CSI + b"6n", CSI + b"?6n", CSI + b"0n")  # reports
c.feed(CSI + b"1;2c", CSI + b"=0c", CSI + b"18t", CSI + b"14t", CSI + b"?1;2$y", CSI + b"x", b"v")
c.feed(ESC + b"[", CSI + b"[A", b"w", ESC + b"(" + b"(" + b"B", ESC + b"#" + b"$" + b"%" + b"8", b"x")
c.feed(CSI + b"1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17;18;19;20;31m" + b"y", CSI + b"m")
c.feed(CSI + b"-1;5H" + b"z", CSI + b"+3;5H" + b"A", CSI + b"3.5;5H" + b"B", CSI + b"3,5H" + b"C")              # not parameters
c.split(CSI + b"0003;0005H" + b"D")

# -------------------------------------------- sequences split across states
c = case("split", 20, 6)
c.split(CSI + b"1;31m" + b"R" + CSI + b"0m")
c.split(OSC + b"2;t" + BEL)
c.split(CSI + b"?1000;1006h")
c.split("漢é".encode() + "é".encode())
c.split(ESC + b"#8")
c.split(CSI + b"2;5r" + ESC + b"7" + cup(4, 4) + ESC + b"8")
c.split(ESC + b"P" + b"1$r" + ST)
c.split(OSC + b"52;c;QQ==" + ST)
c.split(b"\xc2\x9b" + b"2J" + b"\xc2\x85")
c.split(CSI + b"38;2;1;2;3m" + b"x" + CSI + b"m", 2)
c.split(CSI + b"48;5;200m" + b" " + CSI + b"K" + CSI + b"m", 3)
c.split(CSI + b"?1000l" + CSI + b"?1006l" + CSI + b"r", 5)
c.split(CSI + b"1:2m" + b"i")                                                          # CSI ignored after a colon
c.split(ESC + b"P" + b":x" + ST + b"d")                                                # DCS ignored
c.split(ESC + b"_" + b"ab" + ST + b"a" + b"\xc2\x98" + b"s" + b"\xc2\x9c")              # APC, SOS

# -------------------------------------------------------------------- resize
c = case("resize", 20, 8)
c.feed(fill(20, 8), cup(8, 20), CSI + b"31;44m")
c.resize(30, 10)
c.feed(b"A")
c.resize(10, 4)
c.feed(b"B")
c.resize(1, 1)
c.feed(b"C", b"D")
c.resize(2, 2)
c.feed(b"EFG", "漢".encode())
c.resize(80, 24)
c.feed(b"H", CSI + b"0m")
c.resize(20, 1)
c.feed(b"I\r\n", b"J")
c.resize(1, 20)
c.feed(b"K\r\n", b"L")
c.resize(20, 8)
c.feed(fill(20, 8, ord("A")))
c.resize(20, 8)                                                                        # the same size again
c.feed(cup(3, 1) + b"w" * 45)
c.resize(15, 8)
c.resize(25, 8)
c.resize(25, 12)
c.resize(25, 5)
c.feed(CSI + b"2;4r", cup(4, 1) + b"\n")
c.resize(25, 6)                                                                        # the scrolling region is reset
c.feed(b"\n\n\n", b"M")
c.feed(cup(1, 1) + b"x" * 25)
c.resize(30, 6)                                                                        # with a wrap pending
c.feed(b"N")
c.feed(cup(2, 30) + b"e")
c.resize(20, 6)
c.feed("́".encode(), b"O")                                                        # the combining cell was cut off
c.feed(cup(3, 5) + ESC + b"H" + CSI + b"3")
c.resize(40, 6)                                                                        # inside an escape sequence
c.feed(b"1m" + b"P", CSI + b"0m" + b"\r\t\t\t\t\tQ")
c.feed(cup(6, 40) + ESC + b"7")
c.resize(10, 3)
c.feed(ESC + b"8" + b"R")
c.resize(20, 8)
c.feed(b"S")

# ----------------------------------------------------------------- echo acks
c = case("echoack", 20, 6)
c.ack(1)
c.feed(b"a")
c.ack(2)
c.ack(2)                                                                               # no change: an empty diff
c.feed(b"b")
c.ack(5)
c.resize(30, 6)
c.ack(6)
c.feed(b"c")
c.ack(7)
c.feed(CSI + b"?1h")                                                                   # nothing to show
c.ack(8)
c.resize(20, 6)
c.feed(b"d")
c.ack(1099511627776)
c.feed(b"e")
c.ack(1099511627777)

# ------------------------------------------- changes the client never sees
c = case("invisible", 20, 6)
c.feed(b"a", CSI + b"?1h", CSI + b"?1l", CSI + b"4h", CSI + b"4l", CSI + b"?7l", CSI + b"?7h")   # modes the display does not send
c.feed(cup(1, 5) + ESC + b"H", CSI + b"3g", ESC + b"7", CSI + b"?1007h", CSI + b"?1007l")         # tabs, saved cursor, alternate scroll
c.feed(ESC, b"[", b"3", b"1", b"m", CSI + b"0m")                                                 # the pen changes with nothing drawn
c.feed(CSI + b"c", CSI + b"6n", CSI + b"5n", ESC + b"P" + b"q" + ST, ESC + b"_" + b"x" + ST)      # queries and ignored strings
c.feed(cup(1, 1) + b"a", b"\r" + b"a", CSI + b"C" + CSI + b"D", cup(1, 2))                        # redrawing the same thing
c.feed(OSC + b"0;t" + BEL, OSC + b"1;icon only" + BEL, b"b", OSC + b"1;t" + BEL, OSC + b"2;t" + BEL)  # an icon-only change is not sent
c.feed(OSC + b"1;second icon" + BEL, b"\x08" + b"b")                                          # sent here only because this diff has an older base
c.feed(BEL, CSI + b"2;4r", CSI + b"r", b"\xe2", b"\x82", b"\xac")
c.feed(OSC + b"52;c;eA==" + BEL, OSC + b"52;c;eA==" + BEL, OSC + b"52;;eA==" + BEL, b"end")

# The four cases below were added after measuring which lines of the emulator and of
# Display::new_frame the first 34 cases never reached (README.md, "Coverage").

# ------------------------------------- DEL, NUL and C0 inside escape sequences
c = case("del", 20, 6)
c.feed(ESC, b"\x7f", b"[", b"1", b"m", b"a")                                   # DEL in Escape: no rule, stays
c.feed(ESC, b"(", b"\x7f", b"B", b"b")                                         # DEL in Escape_Intermediate
c.feed(CSI, b"!", b"\x7f", b"p", b"c")                                         # DEL in CSI_Intermediate (this is DECSTR)
c.feed(CSI, b" ", b"\n", b"q", b"d")                                           # C0 in CSI_Intermediate is executed
c.feed(CSI, b":", b"1", b"m", b"e")                                             # ':' first: CSI_Ignore
c.feed(CSI, b":", b"\r", b"\n", b"m", b"f")                                    # C0 in CSI_Ignore is executed
c.feed(CSI, b"3", b"\x00", b"1", b"\x7f", b"m", b"g")                          # NUL and DEL inside the parameters
c.feed(b"\xc3\x00", b"h", b"\xe2\x82\x00", b"i", b"\xe2", b"\x00", b"j")      # NUL cuts a UTF-8 sequence short
c.feed(b"\xf0\x9f\x00\x98\x80", b"k", b"\x00\xc3\xa9", b"l")                  # and the bytes after it start afresh
c.feed(OSC + b"0;t\x00i\x7ftle" + BEL, ESC + b"X" + b"s\x7fo\x00s" + ST, b"m")  # in an OSC string, in SOS

# --------------------------------------------------- DCS: every way through
c = case("dcs", 20, 6)
c.feed(ESC + b"P", b"<", b"1", b"q", b"data", ST, b"a")                        # private marker: DCS_Param
c.feed(ESC + b"P", b"\x7f", b"\n", b"q", ST, b"b")                             # DEL and C0 in DCS_Entry: no rule
c.feed(ESC + b"P", b"1", b"\x7f", b"\x08", b";", b"2", b"q", ST, b"c")          # and in DCS_Param
c.feed(ESC + b"P", b"1", b":", b"q", b"x", ST, b"d")                           # ':' after a parameter: DCS_Ignore
c.feed(ESC + b"P", b"1", b"?", b"q", ST, b"e")                                 # a private marker after a parameter too
c.feed(ESC + b"P", b":", b"1", b"q", ST, b"f")                                 # ':' first
c.feed(ESC + b"P", b"$", b"#", b"q", ST, b"g")                                 # two intermediates
c.feed(ESC + b"P", b"$", b"1", b"q", ST, b"h")                                 # a parameter after an intermediate: DCS_Ignore
c.feed(ESC + b"P", b"$", b"\x7f", b"\n", b"q", ST, b"i")                       # DEL and C0 in DCS_Intermediate
c.feed(ESC + b"P", b"q", b"ab", b"\x7f", b"\n", b"c", ST, b"j")                 # DEL in the passthrough, C0 is "put"
c.feed(ESC + b"P", b"1", b"$", b"q", b"\x18", b"k")                            # CAN ends it
c.feed(ESC + b"P", b"q", b"\x9c".decode("latin-1").encode(), b"l")             # C1 ST ends it
c.feed(ESC + b"P", b"q", ESC, b"[", b"1", b"m", b"m", CSI + b"0m")             # ESC ends it and starts the next sequence
c.feed(b"\xc2\x90", b"1", b"q", b"z", ST, b"n")                                # C1 DCS

# ------------------------------- margins and tab clearing: the remaining branches
c = case("margins", 20, 8)
c.feed(fill(20, 8))
c.feed(CSI + b"3;99r", b"A", cup(8, 1), b"\n", b"B")                           # a bottom margin past the screen is the last row
c.feed(CSI + b"?6h", b"C", CSI + b"2;4r", b"D")                                # set while in origin mode: the cursor goes to the new top
c.feed(cup(3, 3), b"E", cup(9, 9), b"F", b"\n\n", b"G")                        # addressing and scrolling inside the margins
c.feed(CSI + b"4;99r", b"H", CSI + b"99;99r", b"I", CSI + b"1;1r", b"J")       # clamped, and two that are refused
c.feed(CSI + b"r", b"K", CSI + b"?6l", b"L")
c.feed(cup(1, 5) + ESC + b"H", CSI + b"1g", CSI + b"2g", CSI + b"4g", CSI + b"5g")   # TBC other than 0 and 3 does nothing
c.feed(b"\r\tM", CSI + b"0;3g", b"\r\tN", CSI + b"3;0g", b"\r\tO")             # only the first parameter counts

# ------------------------------ runs of erased cells, as Display::new_frame sees them
c = case("blanks", 30, 8)
c.feed(cup(1, 1) + CSI + b"41m" + CSI + b"5X" + CSI + b"5C" + CSI + b"42m" + CSI + b"5X" + CSI + b"0m")      # two runs, two colours
c.feed(cup(2, 1) + CSI + b"41m" + CSI + b"6X" + CSI + b"6C" + CSI + b"42m" + CSI + b"2X" + CSI + b"2C"
       + CSI + b"43m" + CSI + b"K" + CSI + b"0m")                                                          # long, short, to the end of the line
c.feed(cup(3, 1) + b"ab" + CSI + b"44m" + CSI + b"3X" + CSI + b"3C" + CSI + b"45m" + CSI + b"7X" + CSI + b"7C"
       + CSI + b"0m" + b"text")                                                                           # between text
c.feed(cup(1, 1) + CSI + b"42m" + CSI + b"5X" + CSI + b"0m")                                              # the first run takes the colour of the second
c.feed(cup(1, 3) + CSI + b"46m" + CSI + b"4X" + CSI + b"0m")                                              # a run inside two others
c.feed(cup(2, 7) + CSI + b"X" + cup(2, 10) + CSI + b"47m" + CSI + b"X" + CSI + b"0m")                     # single cells
c.feed(cup(4, 1) + CSI + b"7m" + CSI + b"10X" + CSI + b"10C" + CSI + b"0;1m" + CSI + b"10X" + CSI + b"10C"
       + CSI + b"0;4m" + CSI + b"K" + CSI + b"0m")                                                         # attributes instead of colours
c.feed(cup(5, 1) + b"x" * 30 + b"y" + b"\r" + CSI + b"X")                                                 # a wrapped line continues with an erased cell
c.feed(cup(7, 1) + b"z" * 30 + b"w" + b"\r" + CSI + b"41m" + CSI + b"3X" + CSI + b"0m")                   # and with a coloured one
c.feed(cup(5, 1) + CSI + b"42m" + CSI + b"K" + cup(6, 1) + CSI + b"43m" + CSI + b"K" + CSI + b"0m")        # whole lines
c.feed(CSI + b"2J", b"end")


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    names = set()
    for c in CASES:
        assert c.name not in names
        names.add(c.name)
        c.write(sys.argv[1])
        print("syn-%s: %d lines" % (c.name, len(c.lines)))


if __name__ == "__main__":
    main()
