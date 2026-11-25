# Fixture for the unicode recording. Run with bash in a 40-column terminal.
p() { printf "$@"; sleep 0.15; }
p 'emoji: \U1F600 \U1F680 \U1F44D\U1F3FD\n'
p 'zwj family: \U1F468‍\U1F469‍\U1F467 flag: \U1F1EE\U1F1EA\n'
p 'CJK: 漢字かなカナ 한국어 中文\n'
p 'combining: é ǟ ỗ́ ñ\n'
p 'combining at column 0:\ńx̂\n'
p 'vs16: ❤️ keycap: 1️⃣\n'
p 'thai: สวัสดี deva: नमस्ते\n'
p 'ambiguous: ±§°α→ soft­hyphen nbsp end\n'
p 'box:\n┌──┬──┐\n│漢│字│\n└──┴──┘\n'
# wide characters at the right margin (the terminal is 40 columns wide)
p '%039d' 0; p '漢\n'
p '%038d' 0; p '漢\n'
p '%040d' 0; p '漢\n'
p '%039d' 0; p '\U1F600\n'
# a row of wide characters that runs over the margin
p '漢%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; p '\n'
# a combining mark after a character in the last column
p '%039d' 0; p 'e'; p '́'; p '\n'
# a wide character overwritten on its right half, then on its left half
p '漢字\r\e[1Cx\n'
p '漢字\rx\n'
p 'done\n'
