/*
 * Generates Sources/MoshTerminal/WCWidthTable.swift from the C library's wcwidth().
 *
 * mosh decides how many columns a character takes by calling wcwidth() on the server
 * and again on the client, and both must agree. The Swift client cannot call the
 * server's C library, so it carries glibc's answers for every code point as a table.
 *
 * Run it in the dev container (glibc 2.39, locales en_US.UTF-8 and C.UTF-8), from the
 * repository root:
 *
 *   scripts/dev.sh bash -c 'gcc -O2 -Wall -o /tmp/gen-wcwidth scripts/gen-wcwidth.c \
 *       && /tmp/gen-wcwidth > Sources/MoshTerminal/WCWidthTable.swift'
 *
 * The table is taken in en_US.UTF-8 (the locale the bootstrap asks mosh-server to
 * use). The program also reads the widths in C.UTF-8 and fails if they differ.
 */
#define _XOPEN_SOURCE 700
#include <gnu/libc-version.h>
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#define NCP 0x110000

static signed char *widths_in(const char *locale)
{
    if (!setlocale(LC_ALL, locale)) {
        fprintf(stderr, "gen-wcwidth: locale %s is not available\n", locale);
        exit(1);
    }
    signed char *w = malloc(NCP);
    if (!w) { perror("malloc"); exit(1); }
    for (long cp = 0; cp < NCP; cp++) {
        int v = wcwidth((wchar_t)cp);
        if (v < -1 || v > 2) {
            fprintf(stderr, "gen-wcwidth: unexpected width %d for U+%04lX\n", v, cp);
            exit(1);
        }
        w[cp] = (signed char)v;
    }
    return w;
}

int main(void)
{
    const char *locale = "en_US.UTF-8";
    signed char *w = widths_in(locale);
    signed char *c = widths_in("C.UTF-8");
    if (memcmp(w, c, NCP) != 0) {
        fprintf(stderr, "gen-wcwidth: en_US.UTF-8 and C.UTF-8 disagree\n");
        return 1;
    }

    long runs = 0;
    long count[4] = {0, 0, 0, 0};
    for (long cp = 0; cp < NCP; cp++) {
        if (cp == 0 || w[cp] != w[cp - 1]) runs++;
        count[w[cp] + 1]++;
    }

    printf("// GENERATED FILE, DO NOT EDIT. Written by scripts/gen-wcwidth.c.\n");
    printf("//\n");
    printf("// wcwidth() of glibc %s in the locale %s (C.UTF-8 is identical), for every\n",
           gnu_get_libc_version(), locale);
    printf("// code point U+0000...U+10FFFF, as runs of equal width. mosh positions characters with\n");
    printf("// the C library's wcwidth() on both ends; this table stands in for it on the client.\n");
    printf("//\n");
    printf("// To regenerate, in the dev container from the repository root:\n");
    printf("//   scripts/dev.sh bash -c 'gcc -O2 -Wall -o /tmp/gen-wcwidth scripts/gen-wcwidth.c \\\n");
    printf("//       && /tmp/gen-wcwidth > Sources/MoshTerminal/WCWidthTable.swift'\n");
    printf("//\n");
    printf("// %ld runs. Code points with width -1: %ld, 0: %ld, 1: %ld, 2: %ld.\n",
           runs, count[0], count[1], count[2], count[3]);
    printf("\n");
    printf("enum WCWidthTable {\n");
    printf("    static let glibcVersion = \"%s\"\n", gnu_get_libc_version());
    printf("    static let runCount = %ld\n", runs);
    printf("\n");
    printf("    /// First code point of each run, ascending. Run i ends before `starts[i + 1]`;\n");
    printf("    /// the last run ends at U+10FFFF.\n");
    printf("    static let starts: [UInt32] = [");
    long n = 0;
    for (long cp = 0; cp < NCP; cp++) {
        if (cp == 0 || w[cp] != w[cp - 1]) {
            printf("%s0x%lX,", (n % 12 == 0) ? "\n        " : " ", cp);
            n++;
        }
    }
    printf("\n    ]\n\n");
    printf("    /// Width of each run: -1 (not printable), 0 (combining), 1 or 2.\n");
    printf("    static let widths: [Int8] = [");
    n = 0;
    for (long cp = 0; cp < NCP; cp++) {
        if (cp == 0 || w[cp] != w[cp - 1]) {
            printf("%s%d,", (n % 24 == 0) ? "\n        " : " ", w[cp]);
            n++;
        }
    }
    printf("\n    ]\n");
    printf("}\n");
    return 0;
}
