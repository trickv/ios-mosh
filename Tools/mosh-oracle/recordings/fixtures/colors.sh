# Fixture for the colours recording: 16, 256 and true colour, attributes,
# and erasing with a background colour (BCE).
p() { printf "$@"; sleep 0.1; }
for i in 0 1 2 3 4 5 6 7; do printf '\e[3%dm fg%d\e[0m' $i $i; done; p '\n'
for i in 0 1 2 3 4 5 6 7; do printf '\e[4%dm bg%d\e[0m' $i $i; done; p '\n'
for i in 0 1 2 3 4 5 6 7; do printf '\e[9%dm br%d\e[0m' $i $i; done; p '\n'
for i in 0 1 2 3 4 5 6 7; do printf '\e[10%dm bb%d\e[0m' $i $i; done; p '\n'
p '\e[1mbold\e[0m \e[2mfaint\e[0m \e[3mitalic\e[0m \e[4munderline\e[0m \e[5mblink\e[0m \e[7minverse\e[0m \e[8minvisible\e[0m \e[9mstrike\e[0m\n'
p '\e[1;3;4;31;44mall together\e[22;23mno bold italic\e[24;39mno underline fg\e[49mno bg\e[0m\n'
# 256 colours: the 16 base colours, the cube, the grey ramp
for i in $(seq 0 15); do printf '\e[48;5;%dm  ' $i; done; p '\e[0m\n'
for row in 0 1 2 3 4 5; do
  for i in $(seq $((16 + row * 36)) $((51 + row * 36))); do printf '\e[48;5;%dm  ' $i; done
  p '\e[0m\n'
done
for i in $(seq 232 255); do printf '\e[38;5;%dm##' $i; done; p '\e[0m\n'
# true colour
for i in $(seq 0 8 255); do printf '\e[48;2;%d;0;%dm ' $i $((255 - i)); done; p '\e[0m\n'
for i in $(seq 0 8 255); do printf '\e[38;2;0;%d;%dm#' $i $((255 - i)); done; p '\e[0m\n'
# background colour erase
p '\e[44mEL to end\e[K\e[0m\n'
p 'abcdefghijklmnopqrstuvwxyz\r\e[42m\e[10C\e[1K\e[0m\n'
p '\e[45mwhole line\e[2K\e[0m\n'
p 'ECH: 0123456789\r\e[5C\e[43m\e[4X\e[0m\n'
p '\e[48;5;52m\e[38;2;255;200;0mscroll with background\n\n\n\e[0m'
p '\e[41m\e[J\e[0mED to end with red\n'
p '\e[48;2;10;20;30m\e[2J\e[H\e[0mcleared with a true colour background\n'
p 'done\n'
