#ifndef PPR_PROCESS_SUPERVISOR_H
#define PPR_PROCESS_SUPERVISOR_H

#include <stdint.h>
#include <sys/types.h>

int32_t ppr_spawn_owned_process_group(const char *executable,
                                      char *const argv[], char *const envp[],
                                      const char *working_directory,
                                      int stdin_fd, int stdout_fd,
                                      int stderr_fd, pid_t *pid_out);

int32_t ppr_observe_exit(pid_t pid, int32_t *has_exited_out);
int32_t ppr_reap_process(pid_t pid, int32_t *status_out, int32_t *signaled_out);
int32_t ppr_signal_owned_process_group(pid_t pid, pid_t pgid,
                                       int signal_number);
#endif
