{
  description = "zsh as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # zsh as a single self-contained static binary — every upstream module linked
  # in, the runtime function/completion tree embedded, no /nix/store closure.
  #
  # Deltas vs nixpkgs pkgsStatic.zsh:
  #   - hardeningDisable = [ "fortify" ]: pkgsStatic's _FORTIFY_SOURCE=2
  #     triggers a GCC ICE (tree-object-size.cc, check_for_plus_in_loops)
  #     compiling Src/sort.c at -O2 under musl. Drop fortify to dodge the
  #     compiler bug — no functional change.
  #   - ncurses fallback-terminfo (zsh's zle/terminfo modules look up terminal
  #     capabilities via ncurses; baked fallbacks avoid reading host
  #     /usr/share/terminfo) is now applied centrally to every engine ncurses in
  #     native-overlay/ncurses.nix — no per-package override (same for dash).
  #   - ALL modules forced into the static link (config.modules `link=no` →
  #     `link=static`) + --enable-gdbm; otherwise pkgsStatic ships a shell
  #     missing mathfunc, pcre, regex, system, zpty, stat, … (everything whose
  #     .mdd says `link=dynamic`).
  #   - unpin-vfs: zsh's function/completion tree (share/zsh/<ver>/functions +
  #     scripts) is embedded in the binary's EOF ZIP and served by the VFS core
  #     interposing zsh's libc file calls; $fpath is pointed at the mount (FPATH
  #     env, set in unpins_zsh_init.c). compinit globs $fpath, so the VFS runs in
  #     DIRS mode (opendir/readdir). Without this the shell runs but
  #     completion/autoload break in a self-contained binary.
  #
  # VFS interception — ONE scheme, Linux AND macOS: vfs.c's shims front the
  # program's open/stat/lstat/access/opendir/readdir/closedir/fopen. Linux
  # engages them with `ld --wrap` (NIX_LDFLAGS); macOS, where ld64 has no
  # --wrap, DEFINES those symbols so the shim definitions shadow libSystem and
  # reaches the real calls via dlsym(RTLD_NEXT, …) — nix-lib's dns-fallback
  # pattern. No objcopy/relink; both compose with the engine's -flto bitcode.
  # Windows (cosmo) is a separate build that keeps `ld --wrap` (cosmo supports
  # it). See vfs.c's platform blocks and injectVfs.
  #
  # Targets (all built; the runtime tree + 30–38 modules verified on each):
  #   - Linux (static-musl, every arch): $fpath points at the embedded mount,
  #     compinit/autoload served from /proc/self/exe (strace: 0 /nix/store
  #     reads), all 38 modules linked. x86_64 ~4.82 MB. cap/libcap enabled.
  #   - macOS (Mach-O, libSystem-only): same interposition via define + dlsym.
  #     cap/libcap is Linux-only and stays a stub here, as it should.
  #   - Windows (Cosmopolitan APE): see cosmo.nix — mingw is a dead end for zsh
  #     (needs fork/job-control/signals), so the Windows binary is cosmocc-built
  #     with the modules cosmo can back and the same VFS core.
  outputs = { self, unpins-lib }:
    let
      # The native static zsh with every module linked in. Used both as the
      # binary we inject the VFS into AND (un-pruned) as the source of the
      # runtime tree staged into the embed.
      # Fallback terminfo is baked centrally for every engine ncurses, linux +
      # darwin (native-overlay/ncurses.nix), so p.ncurses already carries it.
      zshBase = pkgs:
        let p = pkgs.pkgsStatic;
        in (p.zsh.override { ncurses = p.ncurses; }).overrideAttrs (o: {
          hardeningDisable = (o.hardeningDisable or [ ]) ++ [ "fortify" "fortify3" ];

          # Optional libs zsh links against. Two modules are gated behind both a
          # configure flag AND a library (the rest auto-detect against libc):
          #   - zsh/db/gdbm → --enable-gdbm + gdbm. nixpkgs' own zsh leaves it
          #     off; we turn it on for parity with "ship every feature".
          #   - zsh/cap    → --enable-cap + libcap (POSIX.1e capabilities;
          #     getcap/setcap/cap builtins). Without it the module loads but is
          #     a stub ("not available on this system"). libcap/capabilities are
          #     Linux-only, so gate the dep + flag on Linux — on macOS/Windows
          #     the module stays a stub, which is correct.
          # (libiconv is NOT needed: musl libc provides iconv, so multibyte/
          # $'…' conversions work without it — verified.)
          # Also drop the NixOS-only global zshenv
          # (`--enable-zshenv=<store>/etc/zshenv`): it sources
          # /etc/set-environment, meaningless for a portable single binary, and
          # bakes a dead /nix/store path the shell stats at every startup.
          buildInputs = (o.buildInputs or [ ]) ++ [ p.gdbm ]
            ++ pkgs.lib.optional pkgs.stdenv.hostPlatform.isLinux p.libcap;
          #   - --disable-dynamic (darwin): link EVERY module statically into the
          #     zsh binary instead of shipping loadable .so's dlopen'd from
          #     MODULE_PATH at runtime. Linux static-musl can't dlopen so its
          #     configure forces this implicitly; macOS CAN dlopen (libSystem is
          #     dynamic), so without the flag zsh builds zsh/zle/zsh/pcre/… as
          #     .so under $out/lib/zsh and bakes MODULE_PATH — a live /nix/store
          #     runtime dep, and the shell breaks the moment that path is scrubbed
          #     or absent. --disable-dynamic makes macOS match Linux: one
          #     self-contained binary, zmodload resolving to the built-ins.
          configureFlags =
            (builtins.filter
              (f: !(pkgs.lib.hasPrefix "--enable-zshenv=" f))
              (o.configureFlags or [ ]))
            ++ [ "--enable-gdbm" ]
            ++ pkgs.lib.optional pkgs.stdenv.hostPlatform.isLinux "--enable-cap"
            ++ pkgs.lib.optional pkgs.stdenv.hostPlatform.isDarwin "--disable-dynamic";

          # zsh's configure locates the system signal.h and errno.h by greping a
          # REAL on-disk header for the SIG<n> / E<name> macros (it feeds those
          # files to signames*.awk / errnames*.awk to generate the name tables).
          # The unpin-llvm engine resolves <signal.h>/<errno.h> into its embedded
          # VFS sysroot, so the probe sees only VFS paths plus the musl
          # /usr/include fallback list — none exist as files in the sandbox — and
          # aborts "SIGNAL/ERROR MACROS NOT FOUND". Pre-seed both cache vars with
          # musl's real bits/{signal,errno}.h (the path a non-engine CPP would
          # have resolved to). Linux-only: darwin's engine uses the host SDK (real
          # headers on disk), Windows is cosmo.nix.
          preConfigure = (o.preConfigure or "")
            + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
            export zsh_cv_path_signal_h=${pkgs.lib.getDev p.musl}/include/bits/signal.h
            export zsh_cv_path_errno_h=${pkgs.lib.getDev p.musl}/include/bits/errno.h
          '';

          # Force ALL modules into the static binary (config.modules edit is the
          # upstream-supported knob, zsh INSTALL). Verified: all 38 modules
          # `zmodload`-load and work (sqrt/pcre_match/…).
          preBuild = (o.preBuild or "") + ''
            sed -i 's/ link=no / link=static /' config.modules
          '';
        });

      # Layer the unpin-vfs core onto the binary: copy sources, front zsh's libc
      # file calls with the VFS shims, pin $fpath at the mount. One scheme on
      # both platforms (Linux `--wrap`, macOS define+dlsym — see the header
      # note); the VFS objects just have to be on the link line either way.
      #
      # zsh's real build runs through a recursive `make -f Makemod` that passes
      # CC/CFLAGS/EXTRA_LDFLAGS on the sub-make command line (those override any
      # makefile assignment) and is generated fresh from the .mdd files — so
      # neither appended compile rules nor an `EXTRA_LDFLAGS +=` survive there.
      # Two robustness moves: pre-compile the VFS objects in preBuild (they just
      # have to exist as files; EXTRAZSHOBJS, concatenated into Makemod, places
      # them on the link line), and on Linux inject the `--wrap` flags via
      # NIX_LDFLAGS (the nix cc-wrapper applies them to the final link regardless
      # of the makefile) — exported in preBuild, AFTER configure, so the conftest
      # links that have no vfs.o don't hit an undefined __wrap_open.
      injectVfs = pkgs: drv: drv.overrideAttrs (old:
        let
          lib = pkgs.lib;
          isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
        in
        {
        postPatch = (old.postPatch or "") + ''
          echo "==> inject unpin-vfs core (vfs.c + miniz.c)"
          cp ${./vfs.c}            Src/vfs.c
          cp ${./vfs.h}            Src/vfs.h
          cp ${./miniz.c}          Src/miniz.c
          cp ${./miniz.h}          Src/miniz.h
          cp ${./unpin_zstd.c}     Src/unpin_zstd.c
          cp ${./unpin_zstd.h}     Src/unpin_zstd.h
          cp ${./zstddeclib.c}     Src/zstddeclib.c
          cp ${./unpins_zsh_init.c} Src/unpins_zsh_init.c

          echo "==> wire unpins_zsh_init() into main()"
          sed -i '1i extern void unpins_zsh_init(void);' Src/main.c
          sed -i 's|return (zsh_main(argc, argv));|unpins_zsh_init();\n    return (zsh_main(argc, argv));|' Src/main.c
        '';

        # Runs after configure (Src/Makefile exists) and after zshBase's
        # config.modules edit.
        preBuild = (old.preBuild or "") + ''
          echo "==> pre-compile unpin-vfs objects (Makemod regen drops appended rules)"
          UNPIN_VFS_DEFS="-DUNPIN_VFS_DIRS -DUNPIN_VFS_SELF -DUNPIN_VFS_ROOT=\"/__unpins_zshruntime__/\""
          MINIZ_DEFS="-DMINIZ_USE_ZSTD -DMINIZ_NO_TIME -DMINIZ_NO_ARCHIVE_WRITING_APIS -DMINIZ_NO_ZLIB_APIS -DMINIZ_NO_ZLIB_COMPATIBLE_NAMES"
          ( cd Src
            $CC -O2 -c vfs.c            $UNPIN_VFS_DEFS $MINIZ_DEFS -o vfs.o
            $CC -O2 -c miniz.c          -D_GNU_SOURCE -w $MINIZ_DEFS -o miniz.o
            $CC -O2 -c unpin_zstd.c     -D_GNU_SOURCE -w $MINIZ_DEFS -DUNPIN_ZSTD_VENDORED -o unpin_zstd.o
            $CC -O2 -c unpins_zsh_init.c -D_GNU_SOURCE -o unpins_zsh_init.o
          )

          echo "==> link the VFS objects into zsh (EXTRAZSHOBJS survives into Makemod)"
          echo 'EXTRAZSHOBJS += vfs.o miniz.o unpin_zstd.o unpins_zsh_init.o' >> Src/Makefile
        '' + lib.optionalString (!isDarwin) ''
          echo "==> Linux: route zsh's libc file calls through the wrappers via NIX_LDFLAGS"
          export NIX_LDFLAGS="$NIX_LDFLAGS --wrap=open --wrap=stat --wrap=lstat --wrap=access --wrap=opendir --wrap=readdir --wrap=closedir --wrap=fopen"
        '';

        # macOS needs NO extra link step: vfs.c DEFINES open/stat/… (see vfs.c's
        # macOS block), and a definition in a linked object shadows the libSystem
        # import for every reference — so zsh binds to our shims and the real
        # calls go through dlsym(RTLD_NEXT, …). The old objcopy --redefine-sym +
        # relink pass is gone; it couldn't touch the engine's -flto bitcode
        # objects anyway. One scheme, both platforms — only the Linux `--wrap`
        # above differs (ld64 has no --wrap; the define shim replaces it).
      });
      cosmoMod = import ./cosmo.nix { inherit unpins-lib; };
    in
    unpins-lib.lib.mkStandaloneFlake {
      inherit self;
      name = "zsh";

      # Build via the unpin-llvm engine + emit a bitcode multicall module.
      engine = "unpin-llvm";
      multicall = {
        programs = [{ name = "zsh"; }];
        # zsh's configure bakes its own $out into the binary's default
        # module_path / fpath / scriptpath constants, and into a handful of
        # shipped function files (run-help's HELPDIR, autoloaded-function
        # shebangs). Every module is statically linked and $fpath is repointed
        # at the VFS mount, so those baked paths are DEAD — but Nix still counts
        # them as runtime refs and drags the base zsh's closure. Scrub the
        # rodata constants here (unpinEmbedWrap → remove-references-to); the
        # function-file copies are sanitised in runtimeStage below.
        # Two spellings because the base derivation is named per platform:
        # pkgsStatic gives `zsh-static-<ver>`, the cosmo cross gives
        # `zsh-x86_64-unknown-cosmo-gnu-<ver>`. The native pattern alone left the
        # .exe holding a live ref to its own base (measured: refs 1 → 0).
        removeReferences = [ "zsh-static" "zsh-x86_64-unknown-cosmo" ];
      };
      license = "MIT";

      smoke = [ "-f" "-c" "echo unpins-smoke-ok" ];
      smokePattern = "unpins-smoke-ok";

      # Windows via Cosmopolitan (mingw is a dead end for zsh — needs
      # fork/job-control/signals). See cosmo.nix.
      windowsBuild = pkgs: (cosmoMod pkgs).base;

      # PRISTINE VFS zsh base (no embed); the function/script trees + man are
      # embedded once, post-build, via runtimeEmbed → unpinEmbedWrap (the single
      # embed path). Windows (cosmo) provides its own base + embed from cosmo.nix.
      build = pkgs: injectVfs pkgs (zshBase pkgs);
      runtimeEmbed = {
        native = pkgs: base: {
          man = true;
          manRoot = "${base.man}";
          # Stage the function + script trees at the ZIP root (functions/,
          # scripts/) — the mount-relative paths $fpath/UNPIN_VFS_ROOT use.
          # Then sanitise the base zsh's own $out out of the staged files: a
          # few shipped functions bake it into shebangs / HELPDIR defaults, and
          # those strings would ride into the EOF ZIP as live store refs. They
          # point at paths that don't exist in the portable binary (dead), so
          # rewrite them to the mount root — keeps behaviour, drops the ref.
          # `sed` without `-i` so it's portable across the GNU/BSD build hosts.
          runtimeStage = ''
            mkdir -p "$__unpin_stage/functions" "$__unpin_stage/scripts"
            cp -a ${base}/share/zsh/*/functions/. "$__unpin_stage/functions/"
            cp -a ${base}/share/zsh/*/scripts/.   "$__unpin_stage/scripts/" 2>/dev/null || true
            chmod -R u+w "$__unpin_stage"
            find "$__unpin_stage" -type f | while read -r __f; do
              sed "s#${base}#/__unpins_zshruntime__#g" "$__f" > "$__f.__unpin_tmp" \
                && mv "$__f.__unpin_tmp" "$__f"
            done
          '';
        };
        windows = pkgs: base: (cosmoMod pkgs).embed;
      };
    };
}
