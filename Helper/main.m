#import <Foundation/Foundation.h>
#import "../Shared/LanguagePreferences.h"

#import <roothide.h>
#import <grp.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

static int rebootUserspace(void) {
    const char *launchctl = jbroot("/bin/launchctl");
    char *const argv[] = {(char *)launchctl, "reboot", "userspace", NULL};
    pid_t pid = 0;
    int spawnResult = posix_spawn(&pid, launchctl, NULL, NULL, argv, environ);
    if (spawnResult != 0) return spawnResult;

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) return 70;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 71;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (geteuid() != 0) {
            NSLog(@"fontchange-helper must run as root");
            return 77;
        }

        NSString *argument = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"";
        if ([argument isEqualToString:@"--reboot"]) {
            sync();
            return rebootUserspace();
        }

        if ([argument isEqualToString:@"--resume"]) {
            if (![NSFileManager.defaultManager fileExistsAtPath:FCStatePath()]) return 0;
            sleep(8);

            pid_t restorePID = fork();
            if (restorePID < 0) return 72;
            if (restorePID == 0) {
                setgroups(0, NULL);
                if (setgid(501) != 0 || setuid(501) != 0) _exit(73);

                NSError *error = nil;
                if (!FCRestoreSavedLanguage(&error)) {
                    NSLog(@"Language restore failed: %@", error);
                    _exit(1);
                }
                _exit(0);
            }

            int restoreStatus = 0;
            if (waitpid(restorePID, &restoreStatus, 0) < 0 ||
                !WIFEXITED(restoreStatus) || WEXITSTATUS(restoreStatus) != 0) {
                return 1;
            }

            sync();
            sleep(2);
            return rebootUserspace();
        }

        NSLog(@"Usage: fontchange-helper --reboot|--resume");
        return 64;
    }
}
