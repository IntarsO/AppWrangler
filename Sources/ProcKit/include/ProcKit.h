//
//  ProcKit.h
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Low-level process sampling and CPU limiting for Apple Silicon (and Intel).
//
//  All CPU times returned by this module are in nanoseconds. On Apple Silicon
//  the kernel reports task times in Mach ticks (24 MHz, timebase 125/3), which
//  the original AppPolice treated as nanoseconds; everything here converts.
//

#ifndef PROCKIT_H
#define PROCKIT_H

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PK_MAX_GROUPS       256
#define PK_MAX_GROUP_PIDS   512
#define PK_NAME_MAX         64
#define PK_PATH_MAX         4096

/* ---------------------------------------------------------------- time */

uint64_t pk_ticks_to_ns(uint64_t ticks);
/* Monotonic nanoseconds (continues during sleep). */
uint64_t pk_now_ns(void);

/* -------------------------------------------------------------- system */

typedef struct {
	char chip[PK_NAME_MAX];		/* "Apple M1" */
	int ncpu;					/* logical CPUs */
	int pcores;					/* performance cores (0 if unknown) */
	int ecores;					/* efficiency cores (0 if unknown) */
	uint64_t memsize;			/* bytes */
} pk_system_info;

void pk_system_info_get(pk_system_info *out);

typedef struct {
	uint64_t used;				/* app + wired + compressed, like Activity Monitor */
	uint64_t app;
	uint64_t wired;
	uint64_t compressed;
	int pressure_level;			/* 1 normal, 2 warning, 4 critical */
} pk_memory_stats;

int pk_memory_stats_get(pk_memory_stats *out);

/* Host-wide CPU ticks; diff two samples to get total system load. */
typedef struct {
	uint64_t busy;
	uint64_t total;
} pk_cpu_ticks;

int pk_cpu_ticks_get(pk_cpu_ticks *out);

/* ----------------------------------------------------------- processes */

/* Fill buf with running pids; returns count. */
int pk_list_pids(pid_t *buf, int max);

typedef struct {
	pid_t pid;
	pid_t ppid;
	pid_t rpid;					/* responsible pid (the app that owns an XPC/helper) */
	uid_t uid;
	char name[PK_NAME_MAX];
} pk_proc_ident;

/* Returns 0 on success, errno otherwise. */
int pk_proc_ident_get(pid_t pid, pk_proc_ident *out);
int pk_proc_path(pid_t pid, char *buf, uint32_t size);

typedef struct {
	uint64_t cpu_ns;			/* user + system, nanoseconds */
	uint64_t footprint;			/* physical footprint (Activity Monitor "Memory") */
	uint64_t resident;
	uint64_t disk_read;
	uint64_t disk_written;
	uint64_t energy_nj;			/* 0 if unavailable */
	uint64_t start_abstime;		/* process identity, detects pid reuse */
	uint32_t threads;			/* only filled when requested */
} pk_proc_usage;

/* Returns 0 on success, errno otherwise. */
int pk_proc_usage_get(pid_t pid, int with_threads, pk_proc_usage *out);

/* --------------------------------------------------------- scheduling */

/* Darwin background policy: on Apple Silicon this confines the process to the
   efficiency cores and throttles its disk and network I/O. Processes started
   by a background process inherit the policy. */
int pk_set_background(pid_t pid, int on);

/* Direct children of pid; returns count. */
int pk_list_children(pid_t pid, pid_t *buf, int max);

/* ------------------------------------------------------------ limiter */

/*
 Limit the combined CPU usage of a group of processes (an app plus its helpers)
 by duty-cycling them with SIGSTOP/SIGCONT.

 limit_cores	1.0 == 100% of one core. Ignored when frozen.
 frozen			Keep every process in the group stopped until unfrozen.

 Calling again with the same gid updates pids/limit in place. Processes that
 leave the group are always resumed first.
*/
void pk_lim_set_group(uint32_t gid, const pid_t *pids, int npids, double limit_cores, int frozen);
void pk_lim_remove_group(uint32_t gid);
void pk_lim_remove_all(void);
void pk_lim_set_paused(int paused);
/* Duty cycle period, clamped to 10..1000 ms. */
void pk_lim_set_period_ms(uint32_t ms);

typedef struct {
	uint32_t gid;
	double usage_cores;			/* smoothed measured usage */
	double demand_cores;		/* estimated usage if it weren't limited */
	double work_fraction;		/* share of each period the group is allowed to run */
	int npids;
	int denied;					/* a signal failed with EPERM */
	int frozen;
} pk_lim_status;

int pk_lim_status_get(pk_lim_status *out, int max);

/* Resume every process this module has stopped, and take every process it
   put on the efficiency cores back off them. Async-signal-safe.
   Terminal: afterwards the limiter never stops anything again (it's called
   when AppWrangler is exiting or crashing).
   Pausing (pk_lim_set_paused) lifts CPU limits but keeps frozen groups frozen. */
void pk_release_all(void);

/* Tests only: undo pk_release_all()'s shutdown so later tests can limit again. */
void pk_release_all_reset_for_testing(void);

/* Install handlers so a crash or kill of AppWrangler never leaves apps frozen,
   and fork a watchdog that restores everything even after kill -9. Call once,
   first thing in main, before other threads exist. */
void pk_install_safety_handlers(void);

/* main() of the AppWranglerWatchdog helper that pk_install_safety_handlers starts. */
int pk_watchdog_main(int argc, char **argv);

/* True for a shell's foreground job (SIGSTOP would suspend it as a job). */
int pk_is_terminal_foreground(pid_t pid);

#ifdef __cplusplus
}
#endif

#endif
