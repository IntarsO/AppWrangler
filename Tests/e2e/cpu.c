// SPDX-License-Identifier: GPL-2.0-only
/* e2e helper: combined CPU usage (cores) of pids over a window.  cpu <seconds> <pid>... */
#include "ProcKit.h"
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
static uint64_t total(int n, char **pids) {
	uint64_t sum = 0; pk_proc_usage u;
	for (int i = 0; i < n; i++) if (pk_proc_usage_get(atoi(pids[i]), 0, &u) == 0) sum += u.cpu_ns;
	return sum;
}
int main(int argc, char **argv) {
	double secs = atof(argv[1]);
	uint64_t a = total(argc - 2, argv + 2), t = pk_now_ns();
	usleep((useconds_t)(secs * 1e6));
	printf("%.3f\n", (double)(total(argc - 2, argv + 2) - a) / (double)(pk_now_ns() - t));
	return 0;
}
