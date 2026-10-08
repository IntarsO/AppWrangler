// SPDX-License-Identifier: GPL-2.0-only
/* e2e helper: burn N threads, optionally hold M megabytes.  burner <threads> [MB] */
#include <pthread.h>
#include <stdlib.h>
#include <unistd.h>
static volatile char *hold;
static void *burn(void *arg) { (void)arg; volatile double x = 0; for (;;) x += 1; return 0; }
int main(int argc, char **argv) {
	int threads = argc > 1 ? atoi(argv[1]) : 1;
	size_t mb = argc > 2 ? (size_t)atol(argv[2]) : 0;
	if (mb) { hold = malloc(mb << 20); for (size_t i = 0; i < (mb << 20); i += 4096) hold[i] = (char)i; }
	if (threads == 0) for (;;) pause();
	for (int i = 1; i < threads; i++) { pthread_t t; pthread_create(&t, 0, burn, 0); }
	burn(0);
}
