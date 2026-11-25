// Cross-check of the Swift port against mosh 1.4.0's own Terminal::Complete.
//
// Each case is a list of operations (host bytes, resizes, ...). The operations go
// through mosh's code (Support/moshref.cc, linked against the mosh tree of the dev
// container) and through the port; the complete state dumps (every field, see
// DebugDump.swift) must be byte-identical.

#if os(Linux)
import Foundation
import XCTest
import MoshTerminal

final class MoshCrossCheckTests: XCTestCase {
    typealias Case = (name: String, ops: [RefOp])

    private static let esc = "\u{1B}"

    /// Curated inputs. Every case starts with `.new`; a dump, a reply and (where a state
    /// was saved) a cmp are added at the end.
    static let cases: [Case] = {
        let e = esc
        var c: [Case] = []
        func add(_ name: String, _ ops: [RefOp]) { c.append((name, ops)) }
        func t(_ s: String) -> RefOp { return .text(s) }

        add("plain text with CR LF", [.new(20, 5), t("hello\r\nworld\r\n\r\nfoo\tbar")])
        add("autowrap fills three rows", [.new(10, 4), t("abcdefghijklmnopqrstuvwxyz")])
        add("wrap pending then CR LF", [.new(10, 4), t("0123456789\r\nX")])
        add("wrap pending then BS", [.new(10, 4), t("0123456789\u{8}X")])
        add("wrap pending then CUP then print", [.new(10, 4), t("0123456789\(e)[1;10HX")])
        add("wrap pending survives SGR and tab", [.new(10, 4), t("0123456789\(e)[1m\tX")])
        add("wrap scrolls at the bottom", [.new(6, 3), t("aaaaaabbbbbbccccccdddddd"), .dump, t("e")])
        add("autowrap off overwrites the last column", [.new(8, 3), t("\(e)[?7labcdefghijkl\(e)[?7hmn")])
        add("wide characters", [.new(12, 3), t("日本語 text 漢字")])
        add("wide character at the right margin wraps", [.new(5, 3), t("abcd日e")])
        add("wide character in the last column without autowrap", [.new(5, 3), t("\(e)[?7labcd日本")])
        add("wide character overwritten half way", [.new(8, 2), t("日本語\(e)[1;2HX\(e)[1;5HY")])
        add("wide characters in a one-column screen", [.new(1, 3), t("日a本")])
        add("combining characters", [.new(10, 3), t("e\u{301}a\u{308}\u{304} o\u{302}")])
        add("combining character at the start of a line", [.new(10, 3), t("\u{301}x\r\n\u{300}\u{301}")])
        add("combining character after erase", [.new(10, 3), t("ab\(e)[2K\u{301}c")])
        add("combining character at the right margin and after a wrap",
            [.new(4, 3), t("abcd\u{301}e\u{302}"), .dump, t("fgh\u{303}\u{304}i")])
        add("combining characters up to the cell limit",
            [.new(6, 2), t("a" + String(repeating: "\u{301}", count: 20) + "b" + String(repeating: "\u{1D167}", count: 12))])
        add("combining character after a resize took its cell away",
            [.new(10, 3), t("abcdefgh"), .resize(4, 3), t("\u{301}"), .dump, t("x\u{301}")])
        add("zero width joiner, variation selector, emoji",
            [.new(20, 3), t("👨\u{200D}👩\u{200D}👧 ❤\u{FE0F} 🇮🇪 \u{AD}|\u{200B}|")])
        add("unprintable characters are dropped", [.new(10, 2), t("a\u{7F}b\u{FFFF}c\u{E0001}d\u{378}e\u{0}f")])
        add("cursor motion and clamping",
            [.new(10, 5), t("\(e)[3;4HA\(e)[99AB\(e)[99BC\(e)[99DD\(e)[99CE\(e)[2AF\(e)[3DG\(e)[0BH\(e)[0CI")])
        add("CUP, HVP, VPA, CHA, HPA", [.new(10, 5), t("\(e)[2;3HA\(e)[4;7fB\(e)[;5HC\(e)[3dD\(e)[9GE\(e)[2`F\(e)[99;99HG\(e)[0;0HH")])
        add("ED 0 with a background colour", [.new(8, 4), t("11111111222222223333333344444444\(e)[2;4H\(e)[44m\(e)[J")])
        add("ED 1 with a background colour", [.new(8, 4), t("11111111222222223333333344444444\(e)[3;4H\(e)[48;5;200m\(e)[1J")])
        add("ED 2 and ED 3", [.new(8, 4), t("1111111122222222\(e)[41m\(e)[2J\(e)[mxx\(e)[3J")])
        add("EL 0, 1, 2 with background colours",
            [.new(8, 4), t("11111111222222223333333344444444\(e)[1;4H\(e)[42m\(e)[K\(e)[2;4H\(e)[43m\(e)[1K\(e)[3;4H\(e)[48;2;1;2;3m\(e)[2K")])
        add("EL clears the wrap mark of a wrapped row", [.new(6, 3), t("aaaaaabbb\(e)[1;3H\(e)[K"), .dump, t("\(e)[1;1Hccccccd\(e)[1;6H\(e)[1K")])
        add("ECH", [.new(10, 3), t("0123456789\(e)[1;3H\(e)[45m\(e)[3X\(e)[1;9H\(e)[99X\(e)[2;1Habc\(e)[2;2H\(e)[X")])
        add("IL and DL", [.new(6, 5), t("1\r\n2\r\n3\r\n4\r\n5\(e)[2;3H\(e)[2L"), .dump, t("\(e)[1;1H\(e)[M"), .dump, t("\(e)[3;1H\(e)[99M\(e)[99L")])
        add("IL and DL inside and outside a scrolling region",
            [.new(6, 6), t("1\r\n2\r\n3\r\n4\r\n5\r\n6\(e)[2;4r\(e)[3;1H\(e)[L"), .dump, t("\(e)[1;1H\(e)[L\(e)[6;1H\(e)[M"), .dump, t("\(e)[5;1H\(e)[L\(e)[2;1H\(e)[9M")])
        add("ICH and DCH", [.new(10, 3), t("0123456789\(e)[1;3H\(e)[2@\(e)[2;1Habcdefghij\(e)[2;3H\(e)[3P\(e)[3;1Hxyz\(e)[3;2H\(e)[99@")])
        add("DCH moves the wrap mark off the last cell", [.new(6, 3), t("aaaaaab\(e)[1;2H\(e)[P"), .dump, t("\(e)[1;1H\(e)[2P\(e)[@")])
        add("ICH and DCH on wide characters with a background", [.new(8, 2), t("日本語x\(e)[1;2H\(e)[41m\(e)[@\(e)[1;6H\(e)[P")])
        add("insert mode", [.new(10, 3), t("abcdef\(e)[1;3H\(e)[4hXY\(e)[4lZ")])
        add("insert mode with wide characters at the margin", [.new(6, 3), t("abcdef\(e)[1;2H\(e)[4h日\(e)[1;6H本")])
        add("scrolling region with LF at the bottom",
            [.new(6, 6), t("1\r\n2\r\n3\r\n4\r\n5\r\n6\(e)[2;4r\(e)[4;1H\n\n"), .dump, t("X\(e)[6;1H\nY")])
        add("scrolling region with RI at the top", [.new(6, 6), t("1\r\n2\r\n3\r\n4\r\n5\r\n6\(e)[2;4r\(e)[2;1H\(e)M\(e)MX"), .dump, t("\(e)[1;1H\(e)MY")])
        add("IND, NEL, RI as ESC and as C1", [.new(6, 4), t("ab\(e)Dcd\(e)Eef\(e)Mgh\u{84}ij\u{85}kl\u{8D}mn")])
        add("VT and FF are line feeds", [.new(6, 4), t("a\u{B}b\u{C}c")])
        add("origin mode", [.new(8, 6), t("\(e)[2;4r\(e)[?6h\(e)[1;1HA\(e)[9;9HB\(e)[99AC"), .dump, t("\(e)[?6l\(e)[1;1HD")])
        add("DECSTBM edge cases", [.new(8, 6), t("x\(e)[4;2ry\(e)[3;3rz\(e)[9;10rw\(e)[;3rv\(e)[2;99ru\(e)[0;0rt")])
        add("SD and SU", [.new(6, 5), t("1\r\n2\r\n3\r\n4\r\n5\(e)[2S"), .dump, t("\(e)[T\(e)[2;4r\(e)[S\(e)[9T")])
        add("SGR attributes", [.new(20, 2), t("\(e)[1mb\(e)[3mi\(e)[4mu\(e)[5mk\(e)[7mr\(e)[8mh\(e)[22;23;24;25;27;28mn\(e)[2mf\(e)[21md\(e)[9ms")])
        add("SGR 16 colours", [.new(20, 2), t("\(e)[31;42ma\(e)[91;102mb\(e)[39mc\(e)[49md\(e)[97;40me\(e)[0mf\(e)[30;47mg\(e)[mh")])
        add("SGR 256 colours", [.new(20, 2), t("\(e)[38;5;1ma\(e)[48;5;255mb\(e)[38;5;0mc\(e)[38;5;300md\(e)[38;5me\(e)[48;5;16;1mf\(e)[38;5;;4mg")])
        add("SGR true colour", [.new(20, 2), t("\(e)[38;2;1;2;3ma\(e)[48;2;255;254;253mb\(e)[38;2;0;0;0mc\(e)[38;2;300;1000;65535md\(e)[48;2;1;2me\(e)[38;2;;;mf")])
        add("SGR odd forms", [.new(20, 2), t("\(e)[38ma\(e)[38;5mb\(e)[38;2;1mc\(e)[1;38;5;9;4;48;2;9;8;7;7md\(e)[;me\(e)[1;;3mf\(e)[99999mg\(e)[1:2mh")])
        add("tabs", [.new(30, 3), t("a\tb\t\tc\(e)[1;29H\td\te")])
        add("HTS, TBC, CHT, CBT", [.new(30, 3), t("\(e)[1;5H\(e)H\(e)[1;12H\u{88}\r\tA\tB\tC\(e)[1;9H\(e)[g\rD\t\tE\(e)[2ZF\(e)[2IG\(e)[99ZH\(e)[3g\tI")])
        add("tab stops after a resize", [.new(10, 2), t("\(e)[1;4H\(e)H"), .resize(30, 2), t("\t1\t2\t3\t4"), .dump, t("\(e)[3g"), .resize(40, 2), t("\rx\ty")])
        add("DECSC and DECRC", [.new(10, 4), t("\(e)[2;3H\(e)[1;31m\(e)[?6h\(e)[?7l\(e)7\(e)[m\(e)[?6l\(e)[?7h\(e)[4;4Hx\(e)8y")])
        add("DECRC without DECSC, and after a resize", [.new(10, 4), t("abc\(e)8x\(e)[4;10H\(e)7"), .resize(5, 2), t("\(e)8y")])
        add("RIS keeps the bell count and the icon name", [.new(10, 3), t("\(e)]0;title\u{7}\u{7}\u{7}\(e)]52;c;Zm9v\u{7}abc\(e)[2;4r\(e)[?6h\(e)[1m\(e)[3g\(e)cx")])
        add("DECSTR", [.new(10, 4), t("\(e)[2;3r\(e)[?6h\(e)[4h\(e)[?25l\(e)[?1h\(e)[1;31m\(e)7\(e)[?7l\(e)[!pabc\(e)8d")])
        add("OSC titles", [.new(10, 2), t("\(e)]0;both\u{7}"), .dump, t("\(e)]1;icon\u{7}"), .dump, t("\(e)]2;title\(e)\\"), .dump, t("\(e)];bare\u{7}\(e)]3;no\u{7}\(e)]2\u{7}\(e)]\u{7}")])
        add("OSC title with Unicode and odd terminators", [.new(10, 2), t("\(e)]2;日本 é\u{301}\u{9C}a\(e)]1;x\u{18}b\(e)]0;y\(e)[1mc\u{9D}2;C1\u{7}")])
        add("OSC title longer than 256 characters", [.new(10, 2), t("\(e)]0;" + String(repeating: "abcdefghij", count: 30) + "\u{7}")])
        add("OSC 52 clipboard", [.new(10, 2), t("\(e)]52;c;aGVsbG8=\u{7}"), .dump, t("\(e)]52;;bm8=\u{7}\(e)]52;p;bm8=\u{7}"), .dump, t("\(e)]52;c;\u{7}"), .dump, t("\(e)]52;c;?\(e)\\")])
        add("OSC longer than the clipboard limit", [.new(10, 2), t("\(e)]52;c;" + String(repeating: "QUJD", count: 5000) + "\u{7}")])
        add("OSC interrupted by controls and by a new OSC", [.new(10, 2), t("\(e)]0;a\nb\rc\u{7}\(e)]2;one\(e)]1;two\u{7}")])
        add("DEC private modes", [.new(10, 3), t("\(e)[?1h\(e)[?5h\(e)[?25l\(e)[?1004h\(e)[?1007h\(e)[?2004h"), .dump, t("\(e)[?1;5;25;1004;1007;2004l\(e)[?7l"), .dump, t("\(e)[?7;9999;25h\(e)[?l\(e)[?0h")])
        add("mouse modes", [.new(10, 3), t("\(e)[?9h"), .dump, t("\(e)[?1000h\(e)[?1006h"), .dump, t("\(e)[?1002;1015h"), .dump, t("\(e)[?1003h\(e)[?1005h"), .dump, t("\(e)[?1001h\(e)[?9l"), .dump, t("\(e)[?1003h\(e)[?1003l\(e)[?1002l\(e)[?1001l\(e)[?1000l\(e)[?1006l")])
        add("DECCOLM clears the screen", [.new(10, 3), t("abc\r\ndef\(e)[41m\(e)[?3hx"), .dump, t("yz\(e)[?3l")])
        add("origin mode set and reset move the cursor", [.new(10, 5), t("\(e)[2;4r\(e)[4;4H\(e)[?6hA\(e)[3;3H\(e)[?6lB")])
        add("ANSI modes", [.new(10, 3), t("\(e)[4habc\(e)[1;1HX\(e)[20h\(e)[4;20lY\(e)[1;1HZ")])
        add("DECALN", [.new(6, 3), t("\(e)[41mab\(e)#8cd\(e)#3\(e)(B\(e))0x")])
        add("DA and DSR replies", [.new(10, 3), t("\(e)[c\(e)[>c\(e)[0c\(e)[5n\(e)[3;4H\(e)[6n\(e)[?6n\(e)[>0c\(e)[=c")])
        add("BEL, BS at the left margin, LF at the last row", [.new(6, 3), t("\u{7}\u{8}\u{8}a\u{7}\n\n\n\nb\u{7}")])
        add("CAN, SUB and ESC inside sequences", [.new(10, 3), t("a\(e)[1;3\u{18}b\(e)[4\u{1A}c\(e)[5\(e)[2Cd\(e)\(e)[1me\(e)[3\nf")])
        add("C0 controls inside a CSI are executed", [.new(10, 4), t("ab\(e)[1\r;\n3\u{8}mc\(e)[2\tCd")])
        add("CSI parameters out of range", [.new(10, 4), t("\(e)[65535Ba\(e)[65536Bb\(e)[99999999999999999999999Cc\(e)[00000000000000000000000000003Cd\(e)[1;1H\(e)[0004;0002He")])
        add("CSI with more than 100 parameter characters", [.new(10, 4), t("\(e)[" + String(repeating: "1;", count: 60) + "3;4Ha\(e)[" + String(repeating: "0", count: 120) + "5Cb")])
        add("CSI intermediates and unknown finals", [.new(10, 4), t("0123456789\(e)[ qa\(e)[1 !pb\(e)[?1;2zc\(e)[>4;1md\(e)[<1;2;3Me\(e)[=1cf\(e)[!!!!!!!!!pg")])
        add("CSI colon and private markers in the wrong place go to ignore", [.new(10, 4), t("\(e)[1:2ma\(e)[1;?2hb\(e)[1 2hc\(e)[:d")])
        add("code points from U+00A0 end a CSI or an ESC sequence", [.new(10, 4), t("0123456789\(e)[1é\(e)[日a\(e)é\(e)[?25日b\(e)(é\(e)[1;2 éc")])
        add("C1 controls from UTF-8", [.new(10, 4), t("a\u{9B}1mb\u{9B}2;3Hc\u{90}x\u{9C}d\u{98}y\u{9C}e\u{9E}z\u{9C}f\u{9F}w\u{9C}g\u{9D}0;t\u{9C}h\u{80}\u{81}\u{99}\u{9A}i")])
        add("DCS, SOS, PM and APC strings are swallowed", [.new(20, 3), t("a\(e)P1;2|data\(e)\\b\(e)Xsos\(e)\\c\(e)^pm\(e)\\d\(e)_apc\(e)\\e\(e)P:\(e)\\f\(e)P$q\"p\u{9C}g\(e)P0;1 q\n\(e)\\h")])
        add("invalid UTF-8", [.new(40, 4), .bytes([0x61, 0x80, 0x62, 0xC0, 0x80, 0x63, 0xC1, 0xBF, 0x64, 0xE0, 0x80, 0x80, 0x65, 0xED, 0xA0, 0x80, 0x66,
                                                    0xF0, 0x80, 0x80, 0x80, 0x67, 0xF4, 0x90, 0x80, 0x80, 0x68, 0xF8, 0x88, 0x80, 0x80, 0x80, 0x69,
                                                    0xFC, 0x84, 0x80, 0x80, 0x80, 0x80, 0x6A, 0xFE, 0x6B, 0xFF, 0x6C, 0xE2, 0x82, 0x6D, 0xE2, 0x6E,
                                                    0xF0, 0x9F, 0x98, 0x6F, 0xC3, 0xC3, 0xA9, 0x70, 0xE2, 0x00, 0x71, 0xE2, 0x82, 0xE2, 0x82, 0xAC, 0x72,
                                                    0xF8, 0x80, 0x80, 0x80, 0x80, 0x73, 0xFD, 0xBF, 0xBF, 0xBF, 0xBF, 0xBF, 0x74, 0xEF, 0xBF, 0xBD, 0x75])])
        add("UTF-8 split across writes and across a resize", [.new(10, 3), .bytes([0xE6, 0x97]), .dump, .bytes([0xA5, 0xE6]), .resize(12, 3), .bytes([0x9C, 0xAC, 0xF0, 0x9F]), .dump, .bytes([0x1B, 0x5B, 0x41])])
        add("escape sequence split across writes and a resize", [.new(10, 3), t("ab\(e)[3"), .dump, .resize(8, 4), t("1mc\(e)]0;ti"), .dump, t("tle\u{7}")])
        add("resize smaller", [.new(10, 4), t("0123456789abcdefghij\r\nrow3\r\nrow4\(e)[2;4r\(e)[?6h"), .resize(6, 2), .dump, t("X")])
        add("resize larger", [.new(6, 2), t("aaaaaabbbb\(e)[41m"), .resize(12, 4), .dump, t("\(e)[4;12HZ\(e)[1;7HY")])
        add("resize height only, width only, unchanged", [.new(6, 3), t("aaaaaabb"), .resize(6, 5), .dump, .resize(9, 5), .dump, .resize(9, 5), .dump, .resize(6, 3), t("c")])
        add("resize with the cursor pending wrap", [.new(6, 3), t("abcdef"), .resize(4, 3), t("g"), .dump, .resize(8, 3), t("h")])
        add("echo ack", [.new(6, 2), .echoAck(5), t("a"), .echoAck(18446744073709551615)])
        add("user bytes are translated on the server", [.new(6, 2), .userBytes(Array("a\(e)OAb\(e)[A\(e)OP\(e)\(e)OD".utf8)), .reply, t("\(e)[?1h"), .userBytes(Array("\(e)OA\(e)OD\(e)O".utf8))])

        // Shapes of real traffic.
        add("vim-like full redraw", [.new(40, 10), t("\(e)[?1049h\(e)[22;0;0t\(e)[?1h\(e)=\(e)[H\(e)[2J\(e)[?25l\(e)[1;1H#include <stdio.h>\r\n\r\nint main(void)\r\n{\r\n    return 0;\r\n}\r\n\(e)[94m~\(e)[m\r\n\(e)[94m~\(e)[m\(e)[10;1H\(e)[1m\(e)[7mfoo.c\(e)[0m \(e)[10;30H1,1   All\(e)[1;1H\(e)[?25h")])
        add("vim-like scroll with a region", [.new(20, 8), t("l1\r\nl2\r\nl3\r\nl4\r\nl5\r\nl6\r\nl7\r\n-- status --\(e)[1;7r\(e)[7;1H\n\(e)[7;1Hl8\(e)[r\(e)[8;1H\(e)[K:w\(e)[1;7r\(e)[1;1H\(e)M\(e)[1;1Hl0\(e)[r")])
        add("tmux status line", [.new(30, 6), t("$ ls\r\nfile1  file2\r\n$ \(e)7\(e)[6;1H\(e)[30m\(e)[42m[0] 0:bash* 1:vim-         \(e)[m\(e)8\(e)[?25h")])
        add("tmux pane split redraw", [.new(21, 6), t("\(e)[H\(e)[2Jleft\(e)[1;11H\(e)[90m│\(e)[mright\(e)[2;11H\(e)[90m│\(e)[m\(e)[3;11H\(e)[90m│\(e)[m\(e)[4;1H──────────┴──────────\(e)[5;1Hbottom\(e)[1;5H")])
        add("mosh display: initial frame", [.new(20, 5), t("\(e)[?25l\(e)[r\(e)[0m\(e)[H\(e)[2J\(e)]0;user@host: ~\u{7}\(e)[0;1;32muser@host\(e)[0m:\(e)[0;1;34m~\(e)[0m$ \(e)[?25h")])
        add("mosh display: scroll and rewrite", [.new(20, 5), t("a\r\nb\r\nc\r\nd\r\ne\(e)[0m\(e)[1;5r\(e)[5;1H\n\n\(e)[r\(e)[4;1Hf\(e)[K\r\ng\(e)[K\(e)[5;2H")])
        add("mosh display: wrapped row", [.new(8, 4), t("\(e)[0m\(e)[1;1Habcdefgh\(e)[1;8Hhi\(e)[K\(e)[2;2H")])
        add("mosh display: modes and titles", [.new(20, 4), t("\(e)[?2004h\(e)[?1004h\(e)[?1002h\(e)[?1006h\(e)]1;icon\u{7}\(e)]2;title\u{7}\(e)[?5h\u{7}\(e)]52;c;dGVzdA==\u{7}")])
        add("shell prompt with colours and line editing", [.new(30, 4), t("\(e)[1;32muser\(e)[0m@\(e)[36mhost\(e)[0m:\(e)[1;34m~/src\(e)[0m$ git statsu\u{8}\u{8}\(e)[Kus\r\n\(e)[31mfatal\(e)[m: not a repo\r\n")])
        add("progress bar with carriage returns", [.new(24, 3), t("[#         ] 10%\r[#####     ] 50%\r[##########] 100%\r\ndone\(e)[K")])
        add("htop-like screen", [.new(40, 6), t("\(e)[H\(e)[2J\(e)[1;1H\(e)[36m  1\(e)[39m[\(e)[32m|||\(e)[30;1m          3.0%\(e)[0m]\(e)[2;1H\(e)[30;46m  PID USER      PRI  NI  VIRT   RES \(e)[K\(e)[m\(e)[3;1H    1 root       20   0  168M 12.5M\(e)[6;1H\(e)[30;46mF1\(e)[0mHelp \(e)[30;46mF2\(e)[0mSetup\(e)[K")])
        add("less-like paging with RI", [.new(20, 5), t("1\r\n2\r\n3\r\n4\r\n:\(e)[H\(e)M0\(e)[5;1H\(e)[K:\(e)[H\(e)M\(e)[1;1H-1\(e)[5;1H\(e)[K:")])
        add("CJK text wrapping with attributes", [.new(11, 4), t("\(e)[1m日本語の\(e)[0;4mテキスト\(e)[0mが折り返す")])

        // Copy on write and mosh's operator==.
        add("saved state: untouched", [.new(8, 3), t("abc"), .save, .cmp])
        add("saved state: one row written", [.new(8, 3), t("abc\r\ndef"), .save, t("\(e)[1;1Hx"), .cmp])
        add("saved state: same text written again", [.new(8, 3), t("abc"), .save, t("\rabc"), .cmp])
        add("saved state: scroll", [.new(8, 3), t("a\r\nb\r\nc"), .save, t("\n"), .cmp])
        add("saved state: erase line resets a row", [.new(8, 3), t("a\r\nb\r\nc"), .save, t("\(e)[2K"), .cmp])
        add("saved state: cursor move only", [.new(8, 3), t("abc"), .save, t("\(e)[2;2H"), .cmp])
        add("saved state: dropped character still unshares the row", [.new(8, 3), t("abc\r\n"), .save, t("\u{7F}"), .cmp])
        add("saved state: title, clipboard, bell", [.new(8, 3), t("abc"), .save, t("\(e)]1;icon\u{7}"), .cmp, t("\(e)]2;t\u{7}"), .cmp, .save, t("\u{7}"), .cmp])
        add("saved state: resize", [.new(8, 3), t("abc\r\ndef"), .save, .resize(8, 4), .cmp, .save, .resize(9, 4), .cmp, .save, .resize(9, 4), .cmp])
        add("saved state: wrap pending flag is not compared", [.new(4, 2), t("abc"), .save, t("d"), .cmp, .save, t("\(e)[1;4H"), .cmp])
        return c
    }()

    private func finish(_ ops: [RefOp]) -> [RefOp] {
        var ops = ops
        ops.append(.dump)
        ops.append(.reply)
        return ops
    }

    /// Run all cases in one process and compare case by case. Returns (matched, failures).
    private func check(_ cases: [Case], file: StaticString = #filePath, line: UInt = #line) throws -> (Int, [String]) {
        var all: [RefOp] = []
        var ranges: [Range<Int>] = []
        var blockCount = 0
        for c in cases {
            let ops = finish(c.ops)
            let n = ops.filter { $0.producesBlock }.count
            ranges.append(blockCount..<(blockCount + n))
            blockCount += n
            all += ops
        }
        let expected = try MoshRef.reference(all)
        let actual = MoshRef.port(all)
        XCTAssertEqual(expected.count, blockCount, "moshref produced an unexpected number of blocks", file: file, line: line)
        XCTAssertEqual(actual.count, blockCount, file: file, line: line)
        guard expected.count == blockCount, actual.count == blockCount else { return (0, ["block count"]) }

        var matched = 0
        var failures: [String] = []
        for (i, c) in cases.enumerated() {
            var ok = true
            for b in ranges[i] where expected[b] != actual[b] {
                ok = false
                failures.append("\(c.name): block \(b - ranges[i].lowerBound + 1) of \(ranges[i].count) differs at "
                    + MoshRef.firstDifference(expected[b], actual[b]))
                break
            }
            if ok { matched += 1 }
        }
        return (matched, failures)
    }

    /// The comparison is only worth something if it can fail: the reference output must
    /// be a real dump, and a one-byte change of the input must show up.
    func testHarnessDetectsDifferences() throws {
        let e = MoshCrossCheckTests.esc
        let ops: [RefOp] = [.new(6, 2), .text("ab\(e)[1;31mc\(e)]2;t\u{7}"), .dump]
        let reference = try MoshRef.reference(ops)
        XCTAssertEqual(reference.count, 1)
        let expected = """
            complete echo_ack=0 input_history=[]
            parser state=Ground utf8_buf=[]
            dispatch params="" parsed=0 parsed_params=[1,31] dispatch_chars=[] terminal_to_host=[]
            osc_string len=3 "2;t"
            user state=Ground
            fb width=6 height=2 bell_count=0 title_initialized=1
            icon_name len=0 ""
            window_title len=1 "t"
            clipboard len=0 ""
            cursor row=0 col=3 combining_row=0 combining_col=2
            scrolling_region top=0 bottom=1
            tabs default=1 stops=[0]
            pen fg=31 bg=0 attrs=01
            saved cursor_row=0 cursor_col=0 auto_wrap=1 origin=0 fg=0 bg=0 attrs=00
            modes next_print_will_wrap=0 origin=0 auto_wrap=1 insert=0 cursor_visible=1 reverse_video=0 bracketed_paste=0 mouse_reporting=0 mouse_focus_event=0 mouse_alternate_scroll=0 mouse_encoding=0 application_cursor_keys=0
            row 0 obj=0 gen=0 wrap=0 text="abc   "
              61:0:0:00:- 62:0:0:00:- 63:31:0:01:- 3*-:0:0:00:-
            row 1 obj=1 gen=0 wrap=0 text="      "
              6*-:0:0:00:-

            """
        XCTAssertEqual(String(decoding: reference[0], as: UTF8.self), expected)
        XCTAssertEqual(MoshRef.port(ops), reference)

        let changed: [RefOp] = [.new(6, 2), .text("ab\(e)[1;32mc\(e)]2;t\u{7}"), .dump]
        XCTAssertNotEqual(MoshRef.port(changed), reference)
        // The pen is on line 13 of the dump; the stale parsed parameters on line 3 differ first.
        XCTAssertTrue(MoshRef.firstDifference(reference[0], MoshRef.port(changed)[0]).hasPrefix("line 3:"))
    }

    func testCuratedCasesMatchMosh() throws {
        let cases = MoshCrossCheckTests.cases
        XCTAssertGreaterThanOrEqual(cases.count, 30)
        let (matched, failures) = try check(cases)
        print("MoshCrossCheck: curated cases matched \(matched) of \(cases.count)")
        for f in failures.prefix(20) { XCTFail(f) }
        XCTAssertEqual(matched, cases.count)
    }

    /// Number of random cases: `MOSH_FUZZ_CASES` in the environment, or the default.
    private func fuzzCount(_ standard: Int) -> Int {
        if let s = ProcessInfo.processInfo.environment["MOSH_FUZZ_CASES"], let n = Int(s), n > 0 { return n }
        return standard
    }

    func testRandomSequencesMatchMosh() throws {
        var cases: [Case] = []
        for seed in 0..<fuzzCount(400) {
            var g = TerminalFuzz(seed: UInt64(seed))
            cases.append(("fuzz seed \(seed)", g.makeCase()))
        }
        let (matched, failures) = try check(cases)
        print("MoshCrossCheck: random cases matched \(matched) of \(cases.count)")
        for f in failures.prefix(10) { XCTFail(f) }
        XCTAssertEqual(matched, cases.count)
    }

    func testRandomBytesMatchMosh() throws {
        // Raw byte soup: mostly exercises UTF-8 error handling and the parser's states.
        var cases: [Case] = []
        for seed in 0..<fuzzCount(200) {
            var g = TerminalFuzz(seed: 0x5EED_0000 + UInt64(seed))
            cases.append(("bytes seed \(seed)", g.makeByteSoupCase()))
        }
        let (matched, failures) = try check(cases)
        print("MoshCrossCheck: random byte cases matched \(matched) of \(cases.count)")
        for f in failures.prefix(10) { XCTFail(f) }
        XCTAssertEqual(matched, cases.count)
    }
}
#endif
