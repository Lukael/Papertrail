#include "PPRProcessSupervisor.h"

#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

static int32_t retry_getpgid(pid_t pid, pid_t *pgid_out) {
  pid_t result;
  do {
    result = getpgid(pid);
  } while (result == -1 && errno == EINTR);
  if (result == -1) {
    return errno;
  }
  *pgid_out = result;
  return 0;
}

static int32_t retry_getsid(pid_t pid, pid_t *sid_out) {
  pid_t result;
  do {
    result = getsid(pid);
  } while (result == -1 && errno == EINTR);
  if (result == -1) {
    return errno;
  }
  *sid_out = result;
  return 0;
}

int32_t ppr_spawn_owned_process_group(const char *executable,
                                      char *const argv[], char *const envp[],
                                      const char *working_directory,
                                      int stdin_fd, int stdout_fd,
                                      int stderr_fd, pid_t *pid_out) {
  posix_spawnattr_t attributes;
  posix_spawn_file_actions_t actions;
  int error = posix_spawnattr_init(&attributes);
  if (error != 0) {
    return error;
  }
  error = posix_spawn_file_actions_init(&actions);
  if (error != 0) {
    posix_spawnattr_destroy(&attributes);
    return error;
  }

  sigset_t empty_signal_mask;
  sigset_t default_signals;
  sigemptyset(&empty_signal_mask);
  sigemptyset(&default_signals);
  sigaddset(&default_signals, SIGCHLD);

  short flags =
      POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
  error = posix_spawnattr_setflags(&attributes, flags);
  if (error == 0) {
    error = posix_spawnattr_setsigmask(&attributes, &empty_signal_mask);
  }
  if (error == 0) {
    error = posix_spawnattr_setsigdefault(&attributes, &default_signals);
  }
  if (error == 0) {
    error = posix_spawn_file_actions_addchdir_np(&actions, working_directory);
  }
  if (error == 0) {
    error = posix_spawn_file_actions_adddup2(&actions, stdin_fd, STDIN_FILENO);
  }
  if (error == 0) {
    error =
        posix_spawn_file_actions_adddup2(&actions, stdout_fd, STDOUT_FILENO);
  }
  if (error == 0) {
    error =
        posix_spawn_file_actions_adddup2(&actions, stderr_fd, STDERR_FILENO);
  }
  if (error == 0 && stdin_fd != STDIN_FILENO) {
    error = posix_spawn_file_actions_addclose(&actions, stdin_fd);
  }
  if (error == 0 && stdout_fd != STDOUT_FILENO) {
    error = posix_spawn_file_actions_addclose(&actions, stdout_fd);
  }
  if (error == 0 && stderr_fd != STDERR_FILENO) {
    error = posix_spawn_file_actions_addclose(&actions, stderr_fd);
  }

  pid_t pid = -1;
  if (error == 0) {
    do {
      error = posix_spawn(&pid, executable, &actions, &attributes, argv, envp);
    } while (error == EINTR);
  }
  posix_spawn_file_actions_destroy(&actions);
  posix_spawnattr_destroy(&attributes);
  if (error != 0) {
    return error;
  }

  error = ppr_signal_owned_process_group(pid, pid, 0);
  if (error != 0) {
    kill(pid, SIGKILL);
    while (waitpid(pid, NULL, 0) == -1 && errno == EINTR) {
    }
    return error;
  }
  pid_t session_id = -1;
  error = retry_getsid(pid, &session_id);
  if (error == ESRCH) {
    int32_t has_exited = 0;
    error = ppr_observe_exit(pid, &has_exited);
    if (error == 0 && has_exited) {
      session_id = pid;
    }
  }
  if (error != 0 || session_id != pid) {
    ppr_signal_owned_process_group(pid, pid, SIGKILL);
    while (waitpid(pid, NULL, 0) == -1 && errno == EINTR) {
    }
    return error != 0 ? error : EPERM;
  }
  *pid_out = pid;
  return 0;
}

int32_t ppr_observe_exit(pid_t pid, int32_t *has_exited_out) {
  siginfo_t info;
  int result;
  do {
    info.si_pid = 0;
    result = waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT);
  } while (result == -1 && errno == EINTR);
  if (result == -1) {
    return errno;
  }
  *has_exited_out = info.si_pid == pid;
  return 0;
}

int32_t ppr_reap_process(pid_t pid, int32_t *status_out,
                         int32_t *signaled_out) {
  int wait_status = 0;
  pid_t result;
  do {
    result = waitpid(pid, &wait_status, 0);
  } while (result == -1 && errno == EINTR);
  if (result == -1) {
    return errno;
  }
  if (WIFSIGNALED(wait_status)) {
    *status_out = WTERMSIG(wait_status);
    *signaled_out = 1;
  } else if (WIFEXITED(wait_status)) {
    *status_out = WEXITSTATUS(wait_status);
    *signaled_out = 0;
  } else {
    return ECHILD;
  }
  return 0;
}

int32_t ppr_signal_owned_process_group(pid_t pid, pid_t pgid,
                                       int signal_number) {
  int32_t leader_exited_unreaped = 0;
  int32_t error = ppr_observe_exit(pid, &leader_exited_unreaped);
  if (error != 0) {
    return error;
  }
  pid_t actual_group = -1;
  error = 0;
  if (!leader_exited_unreaped) {
    error = retry_getpgid(pid, &actual_group);
    if (error != 0) {
      return error;
    }
  }
  if ((!leader_exited_unreaped && actual_group != pgid) || pgid <= 1 ||
      pid != pgid) {
    return EPERM;
  }
  int result;
  do {
    result = kill(-pgid, signal_number);
  } while (result == -1 && errno == EINTR);
  if (result == -1) {
    if (errno == ESRCH || (leader_exited_unreaped && errno == EPERM)) {
      return 0;
    }
    return errno;
  }
  return 0;
}
