# Fixture for the OSC 52 recording: valid, invalid and oversize clipboard writes.
p() { printf "$@"; sleep 0.15; }
p 'valid\e]52;c;%s\a\n' "$(printf 'hello from OSC 52' | base64)"
p 'the same again\e]52;c;%s\a\n' "$(printf 'hello from OSC 52' | base64)"
p 'valid with ST\e]52;c;%s\e\\\n' "$(printf 'second clip' | base64)"
p 'empty selection, as tmux sends it (dropped)\e]52;;%s\a\n' "$(printf 'dropped' | base64)"
p 'primary selection (dropped)\e]52;p;%s\a\n' "$(printf 'dropped too' | base64)"
p 'not base64 (stored as it is)\e]52;c;!!! not base64 ???\a\n'
p 'query\e]52;c;?\a\n'
p 'empty payload\e]52;c;\a\n'
p 'utf-8 payload\e]52;c;%s\a\n' "$(printf 'grüße 漢字 \U1F600' | base64)"
p 'oversize\e]52;c;%s\a\n' "$(head -c 15000 /dev/zero | tr '\0' 'x' | base64 -w0)"
p 'small again\e]52;c;%s\a\n' "$(printf 'after the big one' | base64)"
p 'done\n'
