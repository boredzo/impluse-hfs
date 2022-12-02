#  impluse engine: Driving HFS volumes forward

Got an old-school HFS (Mac OS Standard) volume that you can't mount anymore since macOS dropped support for it?

impluse is an open-source tool that converts HFS volumes into HFS+ (Mac OS Extended) volumes that you can then mount.

impluse is:

- intentionally misspelled (it's “impulse” rearranged to have “plus” in it)
- not an in-place converter: you must have a source and a destination (such as a read-only disk image, and an empty disk image large enough to hold its contents)
- a command-line tool
- for modern macOS machines (Catalina and later)
- brand-new and untested

impluse does not guarantee to:
- maintain locations of files within each volume
- change locations of files within each volume (e.g., don't expect it to defragment or prune free space)
- change allocation block size (HFS+ can, theoretically, have a smaller allocation block size for many/most volumes, which was one of its selling points over HFS)
- maintain the same allocation block size
- preserve catalog or extents-overflow entries for deleted files (if such entries exist in either file but are not reachable from the root file/folder node)
- prune catalog or extents-overflow entries for deleted files
- decode filenames correctly (there may be an option at some point to specify an encoding hint)
- produce the optimal HFS+ volume for the input contents (e.g., DiskWarrior or PlusOptimizer may have a lot of improvements to suggest)
- produce an HFS wrapper volume for the HFS+ output

impluse's goals *do* include:
- reproduce file contents, including resource forks, accurately (should be testable by hashing any file on both volumes)
- reproduce file metadata, excluding filenames, accurately (e.g., creation/modification dates shouldn't change)
- produce a volume that mounts successfully on modern macOS, at least read-only
- pass HFS+ consistency checks (fsck, DiskWarrior, etc.)
