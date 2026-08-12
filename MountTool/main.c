#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <unistd.h>

static const char *kMountPoint = "/System/Library/Fonts";

static int has_exact_mount(const char *source) {
    struct statfs *mounts = NULL;
    int count = getmntinfo(&mounts, MNT_NOWAIT);
    for (int i = 0; i < count; i++) {
        if (strcmp(mounts[i].f_mntonname, kMountPoint) == 0) {
            return source == NULL || strcmp(mounts[i].f_mntfromname, source) == 0;
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    if (geteuid() != 0) return 77;
    if (argc < 2) return 64;

    if (strcmp(argv[1], "status") == 0) {
        return has_exact_mount(argc == 3 ? argv[2] : NULL) ? 0 : 1;
    }
    if (strcmp(argv[1], "unmount") == 0) {
        if (!has_exact_mount(NULL)) return 0;
        if (unmount(kMountPoint, 0) == 0) return 0;
        fprintf(stderr, "unmount %s: %s\n", kMountPoint, strerror(errno));
        return errno ? errno : 1;
    }
    if (strcmp(argv[1], "mount") == 0 && argc == 3) {
        char source[MAXPATHLEN];
        if (realpath(argv[2], source) == NULL) {
            fprintf(stderr, "realpath %s: %s\n", argv[2], strerror(errno));
            return errno ? errno : 1;
        }
        if (has_exact_mount(source)) return 0;
        if (has_exact_mount(NULL) && unmount(kMountPoint, 0) != 0) {
            fprintf(stderr, "replace existing font mount: %s\n", strerror(errno));
            return errno ? errno : 1;
        }
        if (mount("bindfs", kMountPoint, 0, source) == 0) return 0;
        fprintf(stderr, "mount %s on %s: %s\n", source, kMountPoint, strerror(errno));
        return errno ? errno : 1;
    }
    return 64;
}
