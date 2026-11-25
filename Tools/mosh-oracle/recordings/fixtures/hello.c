/* hello.c: fixture for the vim recordings (syntax colours, scrolling). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_NAMES 16
#define GREETING "hello"

struct person {
    const char *name;
    int age;
    double score;
};

static const struct person people[] = {
    { "Ada", 36, 9.5 },
    { "Grace", 85, 9.9 },
    { "Linus", 54, 8.7 },
    { "Margaret", 87, 9.8 },
};

static int compare_age(const void *a, const void *b)
{
    const struct person *pa = a, *pb = b;
    return pa->age - pb->age;
}

static void greet(const struct person *p)
{
    /* a comment inside a function */
    if (p->age > 80) {
        printf("%s, %s! You are %d.\n", GREETING, p->name, p->age);
    } else {
        printf("%s, %s.\n", GREETING, p->name);
    }
}

static unsigned long fib(unsigned n)
{
    unsigned long a = 0, b = 1;
    while (n-- > 0) {
        unsigned long t = a + b;
        a = b;
        b = t;
    }
    return a;
}

int main(int argc, char **argv)
{
    struct person sorted[MAX_NAMES];
    size_t count = sizeof people / sizeof people[0];
    size_t i;

    memcpy(sorted, people, sizeof people);
    qsort(sorted, count, sizeof sorted[0], compare_age);

    for (i = 0; i < count; i++) {
        greet(&sorted[i]);
    }

    for (i = 0; i < 10; i++) {
        printf("fib(%zu) = %lu\n", i, fib((unsigned) i));
    }

    if (argc > 1 && strcmp(argv[1], "--long") == 0) {
        char line[] = "This line is long enough to need more than eighty columns when it is shown in a terminal window.";
        puts(line);
    }

    return EXIT_SUCCESS;
}
