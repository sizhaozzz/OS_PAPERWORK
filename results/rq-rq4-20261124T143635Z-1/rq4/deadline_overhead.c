#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>
#include <pthread.h>
#include <sched.h>
#include <time.h>
#include <errno.h>
#include <string.h>
#include <sys/syscall.h>

static int NTHREADS = 1;
static int NYIELDS = 50;
static int USE_DEADLINE = 0;

static void set_deadline(void) {
    struct sched_attr {
        uint32_t size; uint32_t policy; uint64_t flags;
        int32_t nice; uint32_t priority;
        uint64_t runtime, deadline, period;
    } attr;
    memset(&attr, 0, sizeof(attr));
    attr.size = sizeof(attr);
    attr.policy = 6;                /* SCHED_DEADLINE */
    attr.runtime = 20000000;        /* 20 ms */
    attr.deadline = 20000000;       /* 20 ms */
    attr.period = 20000000;         /* 20 ms (no throttling, one yield = one period) */
    if (syscall(314, 0, &attr, 0) != 0) {
        fprintf(stderr, "sched_setattr failed: %s\n", strerror(errno));
        pthread_exit(NULL);
    }
}

static void *worker(void *arg) {
    if (USE_DEADLINE) set_deadline();
    for (int i = 0; i < NYIELDS; i++) sched_yield();
    return NULL;
}

int main(int argc, char **argv) {
    if (argc > 1) NTHREADS = atoi(argv[1]);
    if (argc > 2) NYIELDS = atoi(argv[2]);
    if (argc > 3) USE_DEADLINE = atoi(argv[3]);
    pthread_t th[256];
    if (NTHREADS > 256) return 2;
    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    for (int i = 0; i < NTHREADS; i++) pthread_create(&th[i], NULL, worker, NULL);
    for (int i = 0; i < NTHREADS; i++) pthread_join(th[i], NULL);
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double sec = (t1.tv_sec - t0.tv_sec) + (t1.tv_nsec - t0.tv_nsec) / 1e9;
    printf("threads=%d yields=%d deadline=%d wall_sec=%.6f\n",
           NTHREADS, NYIELDS, USE_DEADLINE, sec);
    return 0;
}
