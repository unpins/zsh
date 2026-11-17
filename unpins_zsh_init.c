/* zsh startup glue for the unpin-vfs runtime.
 *
 * Called once from main() before zsh_main(). zsh's `functions/` and
 * `scripts/` trees (normally under $out/share/zsh/<ver>/) are carried in the
 * binary's embedded runtime ZIP, appended at EOF by the nix build
 * (unpinEmbedWrap). The unpin-vfs core (vfs.c in self-EOF mode) reads the
 * running executable back and serves every open/stat/opendir/... whose path
 * falls under the mount root. Natively zsh's own references to those calls
 * are renamed to the VFS shims in the IR; the cosmo build uses `ld --wrap`.
 *
 * zsh finds the trees by itself: the build compiles fndir/scriptdir as
 * /__unpins_zshruntime__/{functions,scripts} into zshpaths.h, which must
 * match -DUNPIN_VFS_ROOT passed to vfs.c (see flake.nix). All this glue does
 * is open the embedded image early, so an unusable one shows up under
 * UNPINS_DEBUG instead of as lazy ENOENTs later.
 *
 * Idempotent: multiple calls no-op after the first.
 */

#include "vfs.h"

#include <stdio.h>
#include <stdlib.h>

void unpins_zsh_init(void)
{
    static int done;
    if (done) return;

    const char *dbg = getenv("UNPINS_DEBUG");
    if (dbg) fprintf(stderr, "[unpins] unpins_zsh_init called\n");

    if (!unpin_vfs_init()) {
        if (dbg) fprintf(stderr, "[unpins] unpin_vfs_init failed\n");
        return;
    }
    if (dbg) fprintf(stderr, "[unpins] VFS ready\n");

    done = 1;
}
