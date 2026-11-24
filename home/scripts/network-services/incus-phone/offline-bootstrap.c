/* Offline TrollStore bootstrap for an owner-authorized iOS 16 device.
 * Run only inside the removable app prepared by TrollRestore. The sibling
 * OfflineHelper is the unmodified official PersistenceHelper_Embedded.
 */
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern int posix_spawnattr_set_persona_np(posix_spawnattr_t *, uid_t, unsigned int);
extern int posix_spawnattr_set_persona_uid_np(posix_spawnattr_t *, uid_t);
extern int posix_spawnattr_set_persona_gid_np(posix_spawnattr_t *, gid_t);

static int run_as_root(const char *helper, char *const args[]) {
    posix_spawnattr_t attr;
    int rc = posix_spawnattr_init(&attr);
    if (rc) return rc;
    rc = posix_spawnattr_set_persona_np(&attr, 99, 1);
    if (!rc) rc = posix_spawnattr_set_persona_uid_np(&attr, 0);
    if (!rc) rc = posix_spawnattr_set_persona_gid_np(&attr, 0);
    pid_t pid;
    if (!rc) rc = posix_spawn(&pid, helper, NULL, &attr, args, NULL);
    posix_spawnattr_destroy(&attr);
    if (rc) {
        fprintf(stderr, "root spawn failed: %d\n", rc);
        return rc;
    }
    int status;
    if (waitpid(pid, &status, 0) == -1) return errno;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}

int main(void) {
    int fd = open("/var/mobile/Media/PublicStaging/se2-offline-install.log",
                  O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd == -1) return 70;
    dup2(fd, STDOUT_FILENO);
    dup2(fd, STDERR_FILENO);
    close(fd);
    setbuf(stdout, NULL);
    setbuf(stderr, NULL);
    char helper[PATH_MAX];
    uint32_t length = sizeof(helper);
    if (_NSGetExecutablePath(helper, &length) != 0) return 71;
    char *slash = strrchr(helper, '/');
    if (!slash || (size_t)(slash - helper) + 15 >= sizeof(helper)) return 72;
    strcpy(slash + 1, "OfflineHelper");
    char *steps[][6] = {
        {helper, "install-trollstore", "/var/mobile/Media/PublicStaging/TrollStore.tar", NULL},
        {helper, "install-ldid", "/var/mobile/Media/PublicStaging/ldid", "v2.1.5-procursus7-new", NULL},
        {helper, "install", "force", "/var/mobile/Media/PublicStaging/Dopamine.ipa", NULL},
        {helper, "install", "force", "/var/mobile/Media/PublicStaging/WebDriverAgentRunner.ipa", NULL},
    };
    for (size_t i = 0; i < sizeof(steps) / sizeof(steps[0]); ++i) {
        printf("step %zu: %s\n", i + 1, steps[i][1]);
        int rc = run_as_root(helper, steps[i]);
        printf("step %zu exit: %d\n", i + 1, rc);
        if (rc) return rc;
    }
    puts("OFFLINE_INSTALL_COMPLETE");
    return 0;
}
