// The first prompt of the shell that tests run in a fresh mosh-server.
//
// mosh-server 1.4.0 holds the shell back until the first datagram from a client arrives
// (frontend/mosh-server.cc:593 "Wait for parent to release us", :822 "Tell child to start login
// session"). A line the client sends right after that datagram races the shell's start-up: if
// it reaches the pty before the shell runs, the tty echoes it at once, before the prompt, and
// dash (/bin/sh on Ubuntu) then prints "$ " followed by the command's output on one row. Tests
// that look for a row that is exactly the output, or for "$ <command>", wait for this prompt
// before their first line. One test types at once on purpose and checks only what holds either
// way (SessionIntegrationTests.testACommandTypedBeforeThePromptRunsOnce).

import Foundation

public enum ShellPrompt {
    /// Whether one of these screen rows (trailing blanks trimmed) is the prompt the tests give
    /// `/bin/sh` (`PS1="$ "`) with nothing typed after it. Tests that see host bytes instead of a
    /// screen wait for "$ " in them.
    public static func isOnScreen(_ rows: [String]) -> Bool {
        rows.contains { $0 == "$" || $0 == "$ " }
    }

    /// Polls `condition` every 20 ms until it holds or `seconds` have passed.
    public static func wait(seconds: Double = 10, until condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await condition()
    }
}
