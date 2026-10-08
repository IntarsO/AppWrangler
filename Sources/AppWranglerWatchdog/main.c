//
//  main.c — AppWranglerWatchdog
//  SPDX-License-Identifier: GPL-2.0-only
//
//  Started by AppWrangler at launch. Waits for AppWrangler to exit — however
//  it exits, even `kill -9` or `killall -9 AppWrangler` — then resumes every
//  app it had paused and moves apps off the efficiency cores. See ProcKit.c.
//

#include "ProcKit.h"

int main(int argc, char **argv) {
	return pk_watchdog_main(argc, argv);
}
