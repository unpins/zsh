/* zsh startup glue for the unpin-vfs runtime.
 *
 * Called once from main() before zsh_main(). zsh's function/completion tree
 * (the `functions/` and `scripts/` trees that normally live in
 * $out/share/zsh/<ver>/) is carried in the binary's single embedded
 * metadata/runtime ZIP, appended at EOF by the nix build (withUnpinEmbed);
 * the unpin-vfs core (vfs.c in self-EOF mode, linked via `ld --wrap`) reads
 * the running executable back and serves every libc open/stat/opendir/...
 * whose path falls under the mount root.
 *
 * All this glue does is point $fpath at the mount so zsh's autoload/compinit
 * machinery produces paths the wrappers intercept. fpath is the PM_TIED twin
 * of the FPATH environment variable (Src/params.c), imported when zsh builds
 * its parameter table — so exporting FPATH here, before zsh_main() runs, makes
 * the embedded tree the default fpath. We use overwrite=0 so a user-provided
 * FPATH still wins (e.g. someone layering site functions on top).
 *
 * The mount root must match -DUNPIN_VFS_ROOT passed to vfs.c (see flake.nix).
 * The runtime ZIP holds `functions/` and `scripts/` at its root, so the
 * mount-relative paths are exactly $VFS_PREFIX/functions and
 * $VFS_PREFIX/scripts.
 *
 * Idempotent: multiple calls no-op after the first.
 */

#include "vfs.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Bare mount point (no trailing slash); UNPIN_VFS_ROOT is this + "/". */
#define VFS_PREFIX "/__unpins_zshruntime__"

void unpins_zsh_init(void)
{
    static int done;
    if (done) return;

    const char *dbg = getenv("UNPINS_DEBUG");
    if (dbg) fprintf(stderr, "[unpins] unpins_zsh_init called\n");

    /* Fail fast (and visibly under UNPINS_DEBUG) if the embedded blob is
     * unusable; the wrappers would otherwise just lazily ENOENT later. */
    if (!unpin_vfs_init()) {
        if (dbg) fprintf(stderr, "[unpins] unpin_vfs_init failed\n");
        return;
    }

    /* Default $fpath to the embedded functions tree unless the user already
     * set FPATH. setenv(...,0) leaves an existing value untouched. */
    setenv("FPATH", VFS_PREFIX "/functions", 0);
    if (dbg) fprintf(stderr, "[unpins] VFS ready, FPATH=%s\n", getenv("FPATH"));

    done = 1;
}
