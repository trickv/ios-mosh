# Fixture for the titles and bell recording.
p() { printf "$@"; sleep 0.15; }
p 'osc 0\e]0;icon and title\a\n'
p 'osc 1\e]1;only the icon name\a\n'
p 'osc 2\e]2;only the window title\a\n'
p 'osc 2 with ST\e]2;terminated by ESC backslash\e\\\n'
p 'osc 0 utf-8\e]0;tïtle 漢字 \U1F600\a\n'
p 'osc without number\e];no number\a\n'
p 'osc 0 empty\e]0;\a\n'
p 'osc 7 is ignored\e]7;file://host/tmp\a\n'
p 'long title\e]2;%0300d\a\n' 5
p 'bell\a\n'
p 'three bells\a\a\a\n'
p 'title and bell together\e]0;both\a\a\n'
p 'done\n'
