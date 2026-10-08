//
//  ProcKit.c
//  AppWrangler
//  SPDX-License-Identifier: GPL-2.0-only
//

#include "ProcKit.h"

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

/* ==================================================================== time */

static mach_timebase_info_data_t pk_timebase(void) {
	static mach_timebase_info_data_t tb;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ mach_timebase_info(&tb); });
	return tb;
}

uint64_t pk_ticks_to_ns(uint64_t ticks) {
	mach_timebase_info_data_t tb = pk_timebase();
	if (tb.numer == tb.denom)
		return ticks;
	/* 128-bit intermediate: ticks * 125 overflows 64 bits after ~4.7 years of CPU time. */
	return (uint64_t)(((__uint128_t)ticks * tb.numer) / tb.denom);
}

uint64_t pk_now_ns(void) {
	return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
}

/* ================================================================== system */

static int sysctl_int(const char *name, int fallback) {
	int v = 0;
	size_t len = sizeof(v);
	return (sysctlbyname(name, &v, &len, NULL, 0) == 0) ? v : fallback;
}

void pk_system_info_get(pk_system_info *out) {
	memset(out, 0, sizeof(*out));
	size_t len = sizeof(out->chip);
	if (sysctlbyname("machdep.cpu.brand_string", out->chip, &len, NULL, 0) != 0)
		strlcpy(out->chip, "Unknown CPU", sizeof(out->chip));
	out->ncpu = sysctl_int("hw.logicalcpu", (int)sysconf(_SC_NPROCESSORS_ONLN));
	out->pcores = sysctl_int("hw.perflevel0.physicalcpu", 0);
	out->ecores = sysctl_int("hw.perflevel1.physicalcpu", 0);
	len = sizeof(out->memsize);
	sysctlbyname("hw.memsize", &out->memsize, &len, NULL, 0);
}

int pk_memory_stats_get(pk_memory_stats *out) {
	memset(out, 0, sizeof(*out));
	vm_statistics64_data_t vm;
	mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
	if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS)
		return -1;
	uint64_t page = (uint64_t)vm_kernel_page_size;
	uint64_t internal = vm.internal_page_count > vm.purgeable_count ? vm.internal_page_count - vm.purgeable_count : 0;
	out->app = internal * page;
	out->wired = (uint64_t)vm.wire_count * page;
	out->compressed = (uint64_t)vm.compressor_page_count * page;
	out->used = out->app + out->wired + out->compressed;
	out->pressure_level = sysctl_int("kern.memorystatus_vm_pressure_level", 1);
	return 0;
}

int pk_cpu_ticks_get(pk_cpu_ticks *out) {
	host_cpu_load_info_data_t load;
	mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
	if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&load, &count) != KERN_SUCCESS)
		return -1;
	uint64_t user = load.cpu_ticks[CPU_STATE_USER];
	uint64_t sys = load.cpu_ticks[CPU_STATE_SYSTEM];
	uint64_t nice = load.cpu_ticks[CPU_STATE_NICE];
	uint64_t idle = load.cpu_ticks[CPU_STATE_IDLE];
	out->busy = user + sys + nice;
	out->total = out->busy + idle;
	return 0;
}

/* =============================================================== processes */

int pk_list_pids(pid_t *buf, int max) {
	int n = proc_listallpids(buf, max * (int)sizeof(pid_t));
	return n < 0 ? 0 : n;
}

typedef pid_t (*responsible_fn)(pid_t);

static responsible_fn pk_responsible(void) {
	static responsible_fn fn;
	static dispatch_once_t once;
	/* Private but stable libSystem API; Activity Monitor uses the same mechanism. */
	dispatch_once(&once, ^{ fn = (responsible_fn)dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid"); });
	return fn;
}

int pk_proc_ident_get(pid_t pid, pk_proc_ident *out) {
	struct proc_bsdshortinfo info;
	memset(out, 0, sizeof(*out));
	errno = 0;
	if (proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, PROC_PIDT_SHORTBSDINFO_SIZE) != PROC_PIDT_SHORTBSDINFO_SIZE)
		return errno ? errno : ESRCH;
	out->pid = pid;
	out->ppid = (pid_t)info.pbsi_ppid;
	out->uid = info.pbsi_uid;
	responsible_fn fn = pk_responsible();
	pid_t r = fn ? fn(pid) : -1;
	out->rpid = r > 0 ? r : pid;
	if (proc_name(pid, out->name, sizeof(out->name)) <= 0)
		strlcpy(out->name, info.pbsi_comm, sizeof(out->name));
	return 0;
}

int pk_proc_path(pid_t pid, char *buf, uint32_t size) {
	int n = proc_pidpath(pid, buf, size);
	if (n <= 0) {
		if (size)
			buf[0] = '\0';
		return 0;
	}
	return n;
}

int pk_proc_usage_get(pid_t pid, int with_threads, pk_proc_usage *out) {
	static _Atomic int use_v6 = 1;
	memset(out, 0, sizeof(*out));
	errno = 0;
	if (atomic_load_explicit(&use_v6, memory_order_relaxed)) {
		struct rusage_info_v6 ri;
		if (proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)&ri) == 0) {
			out->cpu_ns = pk_ticks_to_ns(ri.ri_user_time + ri.ri_system_time);
			out->footprint = ri.ri_phys_footprint;
			out->resident = ri.ri_resident_size;
			out->disk_read = ri.ri_diskio_bytesread;
			out->disk_written = ri.ri_diskio_byteswritten;
			out->energy_nj = ri.ri_energy_nj;
			out->start_abstime = ri.ri_proc_start_abstime;
			goto threads;
		}
		if (errno != EINVAL)
			return errno ? errno : ESRCH;
		/* Older kernel without v6 */
		atomic_store_explicit(&use_v6, 0, memory_order_relaxed);
	}
	{
		struct rusage_info_v4 ri;
		if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0)
			return errno ? errno : ESRCH;
		out->cpu_ns = pk_ticks_to_ns(ri.ri_user_time + ri.ri_system_time);
		out->footprint = ri.ri_phys_footprint;
		out->resident = ri.ri_resident_size;
		out->disk_read = ri.ri_diskio_bytesread;
		out->disk_written = ri.ri_diskio_byteswritten;
		out->start_abstime = ri.ri_proc_start_abstime;
	}
threads:
	if (with_threads) {
		struct proc_taskinfo ti;
		if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, PROC_PIDTASKINFO_SIZE) == PROC_PIDTASKINFO_SIZE)
			out->threads = (uint32_t)ti.pti_threadnum;
	}
	return 0;
}

/* Cheap CPU-only read for the limiter's hot loop. */
static int pk_proc_cpu_ns(pid_t pid, uint64_t *cpu_ns) {
	struct rusage_info_v2 ri;
	errno = 0;
	if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&ri) != 0)
		return errno ? errno : ESRCH;
	*cpu_ns = pk_ticks_to_ns(ri.ri_user_time + ri.ri_system_time);
	return 0;
}

/* ============================================================== scheduling */

int pk_list_children(pid_t pid, pid_t *buf, int max) {
	int n = proc_listchildpids(pid, buf, max * (int)sizeof(pid_t));
	return n < 0 ? 0 : (n > max ? max : n);
}

/* Processes we put on the efficiency cores, so the crash/exit path can
   restore them. Lock-free; read from signal handlers. */
#define PK_MAX_BACKGROUND 4096

/*
 Every pid we've stopped or put on the efficiency cores, kept in memory that's
 shared with a watchdog process (see pk_install_safety_handlers). If
 AppWrangler dies in any way — even kill -9 — the watchdog reads these tables
 and restores everything. Lock-free atomics; also read from signal handlers.
*/
typedef struct {
	_Atomic pid_t stopped[PK_MAX_GROUPS][PK_MAX_GROUP_PIDS];
	/* Holds stopped pids while a group's slots are being rearranged. */
	_Atomic pid_t scratch[PK_MAX_GROUP_PIDS];
	_Atomic pid_t background[PK_MAX_BACKGROUND];
} pk_tables_t;

static pk_tables_t *g_tables;

static pk_tables_t *pk_tables(void) {
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		void *m = mmap(NULL, sizeof(pk_tables_t), PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
		g_tables = (m == MAP_FAILED) ? calloc(1, sizeof(pk_tables_t)) : m;
	});
	return g_tables;
}

static void pk_track_background(pid_t pid, int on) {
	if (on) {
		for (int i = 0; i < PK_MAX_BACKGROUND; ++i)
			if (atomic_load(&pk_tables()->background[i]) == pid)
				return;
		for (int i = 0; i < PK_MAX_BACKGROUND; ++i) {
			pid_t empty = 0;
			if (atomic_compare_exchange_strong(&pk_tables()->background[i], &empty, pid))
				return;
		}
	} else {
		for (int i = 0; i < PK_MAX_BACKGROUND; ++i) {
			pid_t expected = pid;
			atomic_compare_exchange_strong(&pk_tables()->background[i], &expected, 0);
		}
	}
}

int pk_set_background(pid_t pid, int on) {
	if (on)
		pk_track_background(pid, 1);	/* record first: a crash right after still restores it */
	if (setpriority(PRIO_DARWIN_PROCESS, pid, on ? PRIO_DARWIN_BG : 0) != 0) {
		int err = errno;
		pk_track_background(pid, 0);
		return err;
	}
	if (!on)
		pk_track_background(pid, 0);
	return 0;
}

/* ================================================================= limiter */

typedef struct {
	int used;
	uint32_t gid;
	int npids;
	pid_t pids[PK_MAX_GROUP_PIDS];
	uint64_t last_cpu[PK_MAX_GROUP_PIDS];	/* 0 == no baseline yet */
	double limit;
	int frozen;
	int denied;
	uint64_t last_t;
	double usage_ema;
	double demand_ema;		/* usage the group would have if never stopped */
	double gain;			/* slow integral correction for signal latency */
	double w;				/* work fraction for the next period */
	double w_applied;		/* work fraction actually used last period */
	uint32_t periods;		/* periods since the last measurement */
} pk_group;

static pk_group g_groups[PK_MAX_GROUPS];
/* Mirrors g_groups[i].pids[j] while that process is stopped by us, 0 otherwise.
   Read lock-free from signal handlers. */

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cv = PTHREAD_COND_INITIALIZER;
static int g_paused;
static uint64_t g_period_ns = 50 * 1000000ULL;
static int g_thread_started;

#define EMA(prev, x, a) ((prev) < 0 ? (x) : (prev) + (a) * ((x) - (prev)))

/* Set by pk_release_all(): from then on nothing may be stopped. */
static _Atomic int g_shutting_down;

static void pk_stop_pid(pk_group *g, int gi, int i) {
	if (atomic_load(&pk_tables()->stopped[gi][i]) || atomic_load(&g_shutting_down))
		return;
	pid_t pid = g->pids[i];
	/* Publish before signalling so a crash between the two still resumes it. */
	atomic_store(&pk_tables()->stopped[gi][i], pid);
	if (kill(pid, SIGSTOP) != 0) {
		atomic_store(&pk_tables()->stopped[gi][i], 0);
		if (errno == EPERM)
			g->denied = 1;
		return;
	}
	/*
	 Release raced with us: pk_release_all() may have scanned the table before
	 our publish above, so it never saw this pid. Both sides use seq_cst
	 atomics (flag-then-scan vs publish-stop-then-check), so either the
	 release sees our entry or we see its flag — never neither.
	*/
	if (atomic_load(&g_shutting_down))
		kill(pid, SIGCONT);
}

static void pk_cont_pid(int gi, int i) {
	pid_t pid = atomic_exchange(&pk_tables()->stopped[gi][i], 0);
	if (pid > 0)
		kill(pid, SIGCONT);
}

static void pk_cont_group(int gi) {
	for (int i = 0; i < g_groups[gi].npids; ++i)
		pk_cont_pid(gi, i);
}

static void pk_remove_slot(pk_group *g, int gi, int i) {
	pk_cont_pid(gi, i);
	int last = g->npids - 1;
	if (i != last) {
		g->pids[i] = g->pids[last];
		g->last_cpu[i] = g->last_cpu[last];
		atomic_store(&pk_tables()->stopped[gi][i], atomic_exchange(&pk_tables()->stopped[gi][last], 0));
	}
	g->npids = last;
}

static int pk_find_group(uint32_t gid) {
	for (int i = 0; i < PK_MAX_GROUPS; ++i)
		if (g_groups[i].used && g_groups[i].gid == gid)
			return i;
	return -1;
}

/* Pausing lifts CPU limits but never thaws frozen groups: a freeze is an
   explicit "keep this stopped", e.g. after an app blew its memory limit. */
static int pk_has_work_locked(void) {
	for (int i = 0; i < PK_MAX_GROUPS; ++i)
		if (g_groups[i].used && g_groups[i].npids > 0 && (!g_paused || g_groups[i].frozen))
			return 1;
	return 0;
}

static void pk_cont_unfrozen_locked(void) {
	for (int gi = 0; gi < PK_MAX_GROUPS; ++gi)
		if (g_groups[gi].used && !g_groups[gi].frozen)
			pk_cont_group(gi);
}

/* Measure usage since the last period and choose the next work fraction. */
static void pk_measure_locked(pk_group *g, int gi, uint64_t now) {
	uint64_t delta = 0;
	for (int i = 0; i < g->npids; ) {
		uint64_t cpu;
		int err = pk_proc_cpu_ns(g->pids[i], &cpu);
		if (err == ESRCH) {
			pk_remove_slot(g, gi, i);	/* process exited */
			continue;
		}
		if (err == 0) {
			if (g->last_cpu[i] && cpu >= g->last_cpu[i])
				delta += cpu - g->last_cpu[i];
			g->last_cpu[i] = cpu;
		}
		++i;
	}

	if (g->last_t && now > g->last_t) {
		double usage = (double)delta / (double)(now - g->last_t);
		double run = g->w_applied > 0.01 ? g->w_applied : 0.01;
		g->usage_ema = EMA(g->usage_ema, usage, 0.25);
		g->demand_ema = EMA(g->demand_ema, usage / run, 0.25);

		if (!g->frozen) {
			/* Integral term corrects for SIGSTOP latency and multi-threaded overshoot. */
			if (g->usage_ema > g->limit * 1.05)
				g->gain *= 0.97;
			else if (g->usage_ema < g->limit * 0.95 && g->w < 1.0)
				g->gain *= 1.03;
			if (g->gain < 0.25) g->gain = 0.25;
			if (g->gain > 2.0) g->gain = 2.0;

			double w = g->demand_ema > 1e-6 ? (g->limit / g->demand_ema) * g->gain : 1.0;
			if (w > 1.0) w = 1.0;
			if (w < 0.01) w = 0.01;
			g->w = w;
		}
	}
	g->last_t = now;
}

static void pk_sleep_until(uint64_t deadline_ns) {
	uint64_t now = pk_now_ns();
	if (deadline_ns <= now)
		return;
	uint64_t d = deadline_ns - now;
	struct timespec ts = { (time_t)(d / 1000000000ULL), (long)(d % 1000000000ULL) };
	while (nanosleep(&ts, &ts) == -1 && errno == EINTR)
		;
}

typedef struct { int gi; uint32_t gid; uint64_t at; } pk_event;

static int pk_event_cmp(const void *a, const void *b) {
	uint64_t x = ((const pk_event *)a)->at, y = ((const pk_event *)b)->at;
	return (x > y) - (x < y);
}

static uint32_t pk_ns_to_ticks(uint64_t ns) {
	mach_timebase_info_data_t tb = pk_timebase();
	return (uint32_t)((__uint128_t)ns * tb.denom / tb.numer);
}

/*
 Make the limiter a time-constraint (real-time) thread. When a throttled app
 saturates every P-core, even QOS_CLASS_USER_INTERACTIVE wakes ~6 ms late on
 Apple Silicon, so a 0.5 ms run slice became 6 ms and low limits overshot 4x.
 Real-time threads preempt promptly; we only need ~0.2 ms of CPU per period.
*/
static void pk_make_realtime(uint64_t period_ns) {
	thread_time_constraint_policy_data_t policy = {
		.period = pk_ns_to_ticks(period_ns),
		.computation = pk_ns_to_ticks(200000),
		.constraint = pk_ns_to_ticks(1000000),
		.preemptible = 1,
	};
	thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY,
					  (thread_policy_t)&policy, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
}

static void *pk_limiter_thread(void *arg) {
	(void)arg;
	static pk_event events[PK_MAX_GROUPS];
	uint64_t rt_period = 0;
	pthread_setname_np("AppWrangler.limiter");

	for (;;) {
		pthread_mutex_lock(&g_mu);
		while (!pk_has_work_locked()) {
			pk_cont_unfrozen_locked();
			for (int gi = 0; gi < PK_MAX_GROUPS; ++gi)
				g_groups[gi].last_t = 0;	/* don't count idle time as a measurement */
			pthread_cond_wait(&g_cv, &g_mu);
		}

		uint64_t period = g_period_ns;
		int only_frozen = 1;
		for (int gi = 0; gi < PK_MAX_GROUPS; ++gi)
			if (g_groups[gi].used && g_groups[gi].npids > 0 && !g_groups[gi].frozen && !g_paused)
				only_frozen = 0;
		/* Frozen groups only need re-checking for new helper pids; wake rarely. */
		if (only_frozen && period < 250000000ULL)
			period = 250000000ULL;
		if (period != rt_period) {
			pk_make_realtime(period);
			rt_period = period;
		}
		uint64_t t0 = pk_now_ns();
		int nevents = 0;
		for (int gi = 0; gi < PK_MAX_GROUPS; ++gi) {
			pk_group *g = &g_groups[gi];
			if (!g->used || g->npids == 0)
				continue;
			if (g_paused && !g->frozen) {
				g->last_t = 0;
				continue;
			}
			/*
			 Measuring costs one proc_pid_rusage() per process, so measure only as
			 often as control needs: every 2nd period while the group is being held
			 back, every 5th while it's under its limit (a spike is still caught
			 within ~250 ms), and every 5th for frozen groups (to drop exited pids).
			 The duty cycle itself still runs every period.
			*/
			uint32_t every = (g->frozen || g->w >= 0.995) ? 5 : 2;
			if (++g->periods >= every || g->last_t == 0) {
				g->periods = 0;
				pk_measure_locked(g, gi, t0);
			}
			if (g->frozen) {
				g->w_applied = 0;
				events[nevents++] = (pk_event){ gi, g->gid, 0 };
			} else if (g->w < 0.995) {
				g->w_applied = g->w;
				events[nevents++] = (pk_event){ gi, g->gid, (uint64_t)(g->w * (double)period) };
			} else {
				g->w_applied = 1.0;
			}
		}
		pthread_mutex_unlock(&g_mu);

		qsort(events, (size_t)nevents, sizeof(pk_event), pk_event_cmp);
		for (int e = 0; e < nevents; ++e) {
			pk_sleep_until(t0 + events[e].at);
			pthread_mutex_lock(&g_mu);
			pk_group *g = &g_groups[events[e].gi];
			if (g->used && g->gid == events[e].gid && (!g_paused || g->frozen))
				for (int i = 0; i < g->npids; ++i)
					pk_stop_pid(g, events[e].gi, i);
			pthread_mutex_unlock(&g_mu);
		}

		pk_sleep_until(t0 + period);

		pthread_mutex_lock(&g_mu);
		for (int gi = 0; gi < PK_MAX_GROUPS; ++gi)
			if (g_groups[gi].used && !g_groups[gi].frozen)
				pk_cont_group(gi);
		pthread_mutex_unlock(&g_mu);
	}
	return NULL;
}

static void pk_ensure_thread_locked(void) {
	if (g_thread_started)
		return;
	pthread_attr_t attr;
	pthread_attr_init(&attr);
	pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
	/* High QoS keeps the timing tight; the thread sleeps almost all the time. */
	pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
	pthread_t th;
	if (pthread_create(&th, &attr, pk_limiter_thread, NULL) == 0)
		g_thread_started = 1;
	pthread_attr_destroy(&attr);
}

void pk_lim_set_group(uint32_t gid, const pid_t *pids, int npids, double limit_cores, int frozen) {
	if (npids > PK_MAX_GROUP_PIDS)
		npids = PK_MAX_GROUP_PIDS;
	pid_t self = getpid();

	pthread_mutex_lock(&g_mu);
	int gi = pk_find_group(gid);
	if (gi < 0) {
		for (int i = 0; i < PK_MAX_GROUPS; ++i)
			if (!g_groups[i].used) { gi = i; break; }
		if (gi < 0) {
			pthread_mutex_unlock(&g_mu);
			return;
		}
		pk_group *g = &g_groups[gi];
		memset(g, 0, sizeof(*g));
		g->used = 1;
		g->gid = gid;
		g->usage_ema = -1;
		g->demand_ema = -1;
		g->gain = 1.0;
		g->w = 1.0;
		g->w_applied = 1.0;
	}
	pk_group *g = &g_groups[gi];

	/* Keep baselines and stopped state of retained pids; resume pids that left. */
	static pid_t new_pids[PK_MAX_GROUP_PIDS];
	static uint64_t new_cpu[PK_MAX_GROUP_PIDS];
	static pid_t new_stopped[PK_MAX_GROUP_PIDS];
	static char retained[PK_MAX_GROUP_PIDS];
	memset(retained, 0, sizeof(retained));
	int n = 0;
	for (int k = 0; k < npids; ++k) {
		pid_t p = pids[k];
		if (p <= 1 || p == self)
			continue;
		int dup = 0;
		for (int m = 0; m < n; ++m)
			if (new_pids[m] == p) { dup = 1; break; }
		if (dup)
			continue;
		new_pids[n] = p;
		new_cpu[n] = 0;
		new_stopped[n] = 0;
		for (int i = 0; i < g->npids; ++i) {
			if (g->pids[i] == p) {
				new_cpu[n] = g->last_cpu[i];
				new_stopped[n] = atomic_load(&pk_tables()->stopped[gi][i]);
				retained[i] = 1;
				break;
			}
		}
		++n;
	}
	/* Unfreezing (or switching to a plain limit) resumes the whole group now. */
	if (g->frozen && !frozen) {
		pk_cont_group(gi);
		for (int k = 0; k < n; ++k)
			new_stopped[k] = 0;
	}
	for (int i = 0; i < g->npids; ++i)
		if (!retained[i])
			pk_cont_pid(gi, i);
	/* Park stopped pids in the scratch table while slots move around. */
	for (int k = 0; k < n; ++k)
		atomic_store(&pk_tables()->scratch[k], new_stopped[k]);
	for (int i = 0; i < PK_MAX_GROUP_PIDS; ++i)
		atomic_store(&pk_tables()->stopped[gi][i], i < n ? new_stopped[i] : 0);
	for (int k = 0; k < n; ++k)
		atomic_store(&pk_tables()->scratch[k], 0);
	/* A release on another thread may have scanned mid-rewrite and missed a
	   moved pid; it set the shutdown flag first, so resume them here. */
	if (atomic_load(&g_shutting_down))
		for (int k = 0; k < n; ++k)
			if (new_stopped[k] > 0)
				kill(new_stopped[k], SIGCONT);
	memcpy(g->pids, new_pids, (size_t)n * sizeof(pid_t));
	memcpy(g->last_cpu, new_cpu, (size_t)n * sizeof(uint64_t));
	g->npids = n;

	if (g->limit != limit_cores || g->frozen != frozen) {
		g->gain = 1.0;
		g->denied = 0;
	}
	g->limit = limit_cores > 0.001 ? limit_cores : 0.001;
	g->frozen = frozen ? 1 : 0;
	/* Freeze takes effect immediately, including for newly added helpers. */
	if (g->frozen)
		for (int i = 0; i < g->npids; ++i)
			pk_stop_pid(g, gi, i);

	pk_ensure_thread_locked();
	pthread_cond_signal(&g_cv);
	pthread_mutex_unlock(&g_mu);
}

void pk_lim_remove_group(uint32_t gid) {
	pthread_mutex_lock(&g_mu);
	int gi = pk_find_group(gid);
	if (gi >= 0) {
		pk_cont_group(gi);
		g_groups[gi].used = 0;
		g_groups[gi].npids = 0;
	}
	pthread_mutex_unlock(&g_mu);
}

void pk_lim_remove_all(void) {
	pthread_mutex_lock(&g_mu);
	for (int gi = 0; gi < PK_MAX_GROUPS; ++gi) {
		if (!g_groups[gi].used)
			continue;
		pk_cont_group(gi);
		g_groups[gi].used = 0;
		g_groups[gi].npids = 0;
	}
	pthread_mutex_unlock(&g_mu);
}

void pk_lim_set_paused(int paused) {
	pthread_mutex_lock(&g_mu);
	g_paused = paused ? 1 : 0;
	if (g_paused)
		pk_cont_unfrozen_locked();
	pthread_cond_signal(&g_cv);
	pthread_mutex_unlock(&g_mu);
}

void pk_lim_set_period_ms(uint32_t ms) {
	if (ms < 10) ms = 10;
	if (ms > 1000) ms = 1000;
	pthread_mutex_lock(&g_mu);
	g_period_ns = (uint64_t)ms * 1000000ULL;
	pthread_mutex_unlock(&g_mu);
}

int pk_lim_status_get(pk_lim_status *out, int max) {
	int n = 0;
	pthread_mutex_lock(&g_mu);
	for (int gi = 0; gi < PK_MAX_GROUPS && n < max; ++gi) {
		pk_group *g = &g_groups[gi];
		if (!g->used)
			continue;
		out[n].gid = g->gid;
		out[n].usage_cores = g->usage_ema < 0 ? 0 : g->usage_ema;
		out[n].demand_cores = g->demand_ema < 0 ? 0 : g->demand_ema;
		out[n].work_fraction = g->frozen ? 0 : g->w;
		out[n].npids = g->npids;
		out[n].denied = g->denied;
		out[n].frozen = g->frozen;
		++n;
	}
	pthread_mutex_unlock(&g_mu);
	return n;
}

/* ============================================================ safety net */

/* Resume stopped pids; with `everything`, also restore efficiency-core pids. */
static void pk_release_tables(pk_tables_t *t, int everything) {
	if (!t)
		return;
	for (int gi = 0; gi < PK_MAX_GROUPS; ++gi) {
		for (int i = 0; i < PK_MAX_GROUP_PIDS; ++i) {
			pid_t pid = atomic_exchange(&t->stopped[gi][i], 0);
			if (pid > 0)
				kill(pid, SIGCONT);
		}
	}
	for (int i = 0; i < PK_MAX_GROUP_PIDS; ++i) {
		pid_t pid = atomic_exchange(&t->scratch[i], 0);
		if (pid > 0)
			kill(pid, SIGCONT);
	}
	if (!everything)
		return;
	/* setpriority is a plain syscall, fine in a signal handler. Entries are
	   left in place so the watchdog can also restore children that inherited
	   the policy once we're gone. */
	for (int i = 0; i < PK_MAX_BACKGROUND; ++i) {
		pid_t pid = atomic_load(&t->background[i]);
		if (pid > 0)
			setpriority(PRIO_DARWIN_PROCESS, pid, 0);
	}
}

void pk_release_all(void) {
	/* Lock-free on purpose: called from signal handlers and atexit. */
	atomic_store(&g_shutting_down, 1);
	pk_release_tables(g_tables, 1);
}

void pk_release_all_reset_for_testing(void) {
	atomic_store(&g_shutting_down, 0);
}

static void pk_install_handlers(void);

static void pk_fatal_handler(int sig) {
	pk_release_all();
	signal(sig, SIG_DFL);
	raise(sig);
}

/*
 Ctrl-Z on AppWrangler run from a terminal: resume everything we paused (so
 nothing stays frozen while we're suspended) but don't shut the limiter down —
 it picks up again on SIGCONT.
*/
static void pk_tstp_handler(int sig) {
	pk_release_tables(g_tables, 0);
	signal(sig, SIG_DFL);
	raise(sig);
}

/* After a SIGTSTP stop + SIGCONT, re-arm the handlers. */
static void pk_cont_handler(int sig) {
	(void)sig;
	pk_install_handlers();
}

static void pk_install_handlers(void) {
	static const int sigs[] = { SIGTERM, SIGINT, SIGHUP, SIGQUIT,
								SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP };
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sigemptyset(&sa.sa_mask);
	sa.sa_handler = pk_fatal_handler;
	sa.sa_flags = SA_NODEFER | SA_RESETHAND;
	for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); ++i)
		sigaction(sigs[i], &sa, NULL);
	sa.sa_handler = pk_tstp_handler;
	sigaction(SIGTSTP, &sa, NULL);
	sa.sa_handler = pk_cont_handler;
	sa.sa_flags = 0;
	sigaction(SIGCONT, &sa, NULL);
}

/* Restore a process and everything it started from the efficiency cores. */
static void pk_watchdog_unbackground(pid_t pid, int depth) {
	setpriority(PRIO_DARWIN_PROCESS, pid, 0);
	if (depth > 6)
		return;
	pid_t kids[256];
	int n = proc_listchildpids(pid, kids, (int)sizeof(kids));
	for (int i = 0; i < n && i < 256; ++i)
		if (kids[i] > 1 && kids[i] != pid)
			pk_watchdog_unbackground(kids[i], depth + 1);
}

/* Runs in the forked watchdog: wait for AppWrangler to go away, then clean up. */
static void pk_watchdog(int fd, pk_tables_t *t) {
	signal(SIGINT, SIG_IGN);	/* Ctrl-C in a terminal reaches us too; outlive the app */
	signal(SIGHUP, SIG_IGN);
	signal(SIGTSTP, SIG_IGN);
	signal(SIGTERM, SIG_IGN);	/* logout: wait for the app to exit, then clean up */
	char c;
	for (;;) {
		ssize_t r = read(fd, &c, 1);
		if (r == 0 || (r < 0 && errno != EINTR))
			break;
	}
	pk_release_tables(t, 0);
	for (int i = 0; i < PK_MAX_BACKGROUND; ++i) {
		pid_t pid = atomic_exchange(&t->background[i], 0);
		if (pid > 0)
			pk_watchdog_unbackground(pid, 0);
	}
	_exit(0);
}

void pk_install_safety_handlers(void) {
	pk_tables_t *t = pk_tables();
	pk_install_handlers();
	atexit(pk_release_all);

	/* Watchdog: holds the read end of a pipe; when every write end closes
	   (AppWrangler exited, crashed or was SIGKILLed) read() returns 0. */
	int fds[2];
	if (pipe(fds) != 0)
		return;
	pid_t child = fork();
	if (child == 0) {
		close(fds[1]);
		pk_watchdog(fds[0], t);
	}
	close(fds[0]);
	if (child < 0) {
		close(fds[1]);
		return;
	}
	/* Don't leak the write end into processes we spawn, or they'd keep it open. */
	fcntl(fds[1], F_SETFD, FD_CLOEXEC);
}

/* A shell's foreground job: SIGSTOP would make the shell treat it as suspended. */
int pk_is_terminal_foreground(pid_t pid) {
	struct proc_bsdinfo info;
	if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, PROC_PIDTBSDINFO_SIZE) != PROC_PIDTBSDINFO_SIZE)
		return 0;
	return (info.pbi_flags & PROC_FLAG_CONTROLT) && info.e_tpgid > 0 && (pid_t)info.pbi_pgid == (pid_t)info.e_tpgid;
}
