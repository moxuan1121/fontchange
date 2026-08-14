# Third-party notices

FontChange's bindfs mounting component is informed by these MIT-licensed projects:

- `lunaynx/mount-bindfs-dopamine` — Copyright (c) 2023 lunaynx.

FontChange uses the `bsdtar` command supplied by `libarchive-tools` to read supported font archives. libarchive is distributed under the New BSD license. FontChange does not bundle or modify libarchive; the package manager installs it as a dependency.

- `libarchive/libarchive` — https://github.com/libarchive/libarchive
- `w2599/Dopamine` RootHide mount implementation — derived from Dopamine, Copyright (c) Lars Fröder and contributors.

The original license notices are retained by their respective repositories. FontChange's implementation adds RootHide path translation, an owned font snapshot, lifecycle checks, and a launch daemon.
