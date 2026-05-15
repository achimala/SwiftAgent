#include "tools/agentkit_ish_runtime.h"

#include <execinfo.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>
#include <mach/mach.h>
#include <pthread.h>

#include "kernel/calls.h"
#include "kernel/task.h"
#include "emu/cpu.h"
#include "emu/tlb.h"

extern __thread volatile sig_atomic_t in_jit;
extern __thread volatile uint64_t jit_saved_pc;
extern __thread volatile uint64_t jit_last_host_fault;
extern __thread volatile uint64_t jit_last_x7;
extern __thread volatile uint64_t jit_last_x10;
extern __thread volatile int jit_crash_count;
extern void jit_crash_trampoline(void);

#define CRASH_CPU_pc 272
#define CRASH_CPU_segfault_addr 832
#define CRASH_CPU_segfault_was_write 840
#define CRASH_LOCAL_jit_exit_sp 920

static jmp_buf agentkit_exit_jmp;
static int agentkit_exit_code;
static struct termios saved_termios;
static int saved_termios_valid;
static int did_install_crash_handler;

static void agentkit_host_exit(int code) {
    agentkit_exit_code = code;
    longjmp(agentkit_exit_jmp, 1);
}

#define exit(code) agentkit_host_exit(code)
#define _exit(code) agentkit_host_exit(code)
#include "xX_main_Xx.h"
#undef exit
#undef _exit

void restore_termios(void) {
    if (saved_termios_valid)
        tcsetattr(agentkit_ish_stdin_fd(), TCSANOW, &saved_termios);
}

static void crash_handler(int sig, siginfo_t *info, void *ctx) {
#ifdef __aarch64__
    if ((sig == SIGSEGV || sig == SIGBUS) && in_jit) {
        ucontext_t *uc = (ucontext_t *)ctx;
        uint64_t cpu_ptr = uc->uc_mcontext->__ss.__x[1];
        uint64_t x7 = uc->uc_mcontext->__ss.__x[7];
        uint64_t x10 = uc->uc_mcontext->__ss.__x[10];
        uint64_t guest_addr = (x7 - x10) & 0xffffffffffffULL;

        jit_last_host_fault = (uint64_t)info->si_addr;
        jit_last_x7 = x7;
        jit_last_x10 = x10;
        jit_crash_count++;

        uint64_t esr = uc->uc_mcontext->__es.__esr;
        int was_write = (esr & 0x40) != 0;

        *(uint64_t *)(cpu_ptr + CRASH_CPU_segfault_addr) = guest_addr;
        *(int *)(cpu_ptr + CRASH_CPU_segfault_was_write) = was_write;
        *(uint64_t *)(cpu_ptr + CRASH_CPU_pc) = (uint64_t)jit_saved_pc;

        uint64_t exit_sp = *(uint64_t *)(cpu_ptr + CRASH_LOCAL_jit_exit_sp);
        uc->uc_mcontext->__ss.__sp = exit_sp;
        uc->uc_mcontext->__ss.__pc = (uint64_t)jit_crash_trampoline;

        sigset_t unblock;
        sigemptyset(&unblock);
        sigaddset(&unblock, sig);
        sigprocmask(SIG_UNBLOCK, &unblock, NULL);
        return;
    }
#endif

    dprintf(agentkit_ish_stderr_fd(), "\nagentkit iSH host crash: signal %d fault=%p\n", sig, info->si_addr);
    void *bt[20];
    int n = backtrace(bt, 20);
    backtrace_symbols_fd(bt, n, agentkit_ish_stderr_fd());
    agentkit_host_exit(139);
}

static void install_crash_handler_once(void) {
    if (did_install_crash_handler)
        return;
    did_install_crash_handler = 1;

    static char altstack[SIGSTKSZ];
    stack_t ss = {.ss_sp = altstack, .ss_size = SIGSTKSZ};
    sigaltstack(&ss, NULL);

    struct sigaction sa = {0};
    sa.sa_sigaction = crash_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
    sigaction(SIGTRAP, &sa, NULL);
}

int agentkit_ish_run_main(int argc, char *const argv[]) {
    if (isatty(agentkit_ish_stdin_fd()) && tcgetattr(agentkit_ish_stdin_fd(), &saved_termios) == 0) {
        saved_termios_valid = 1;
        atexit(restore_termios);
    }
    dup2(agentkit_ish_stderr_fd(), 666);
    install_crash_handler_once();

    char envp[512] = {0};
    size_t p = 0;
    if (getenv("TERM")) {
        p += snprintf(envp + p, sizeof(envp) - p, "TERM=%s", getenv("TERM")) + 1;
    }
    p += snprintf(envp + p, sizeof(envp) - p, "HOME=/root") + 1;
    p += snprintf(envp + p, sizeof(envp) - p, "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin") + 1;
#ifdef GUEST_ARM64
    p += snprintf(envp + p, sizeof(envp) - p, "PYTHONMALLOC=malloc") + 1;
#endif

    agentkit_exit_code = 0;
    if (setjmp(agentkit_exit_jmp) == 0) {
        int err = xX_main_Xx(argc, argv, envp);
        if (err < 0) {
            fprintf(stderr, "xX_main_Xx: %s\n", strerror(-err));
            return -err;
        }
        do_mount(&procfs, "proc", "/proc", "", 0);
        do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);
        task_run_current();
    }

    restore_termios();
    return agentkit_exit_code;
}
