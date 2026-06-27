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
  #     scripts) is embedded in the binary's EOF ZIP and served by the VFS
  #     core via `ld --wrap`; $fpath is pointed at the mount (FPATH env, set in
  #     unpins_zsh_init.c). compinit globs $fpath, so the VFS runs in DIRS mode
  #     (opendir/readdir). Without this the shell runs but completion/autoload
  #     break in a self-contained binary.
  #
  # Targets (all built; the runtime tree + 30–38 modules verified on each):
  #   - Linux (static-musl, every arch): $fpath points at the embedded mount,
  #     compinit/autoload served from /proc/self/exe (strace: 0 /nix/store
  #     reads), all 38 modules linked. x86_64 ~4.82 MB.
  #   - macOS (Mach-O, libSystem-only): no `ld --wrap`, so zsh's own objects'
  #     libc file refs are rewritten to the VFS shims with llvm-objcopy
  #     --redefine-sym + relink (mirrors vim's darwin branch). cap/libcap is
  #     Linux-only and stays a stub here, as it should.
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
          configureFlags =
            (builtins.filter
              (f: !(pkgs.lib.hasPrefix "--enable-zshenv=" f))
              (o.configureFlags or [ ]))
            ++ [ "--enable-gdbm" ]
            ++ pkgs.lib.optional pkgs.stdenv.hostPlatform.isLinux "--enable-cap";

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

      # Layer the unpin-vfs core onto the binary: copy sources, route zsh's
      # libc file calls through the wrappers (ld --wrap), pin $fpath at the
      # mount. Mirrors vim's injectVfs (Linux branch only for now).
      #
      # zsh's real build runs through a recursive `make -f Makemod` that passes
      # CC/CFLAGS/EXTRA_LDFLAGS on the sub-make command line (those override any
      # makefile assignment) and is generated fresh from the .mdd files — so
      # neither appended compile rules nor an `EXTRA_LDFLAGS +=` survive there.
      # Two robustness moves: pre-compile the VFS objects in preBuild (they just
      # have to exist as files; EXTRAZSHOBJS, concatenated into Makemod, places
      # them on the link line), and inject the `--wrap` flags via NIX_LDFLAGS
      # (the nix cc-wrapper applies them to the final link regardless of the
      # makefile) — exported in preBuild, AFTER configure, so the conftest links
      # that have no vfs.o don't hit an undefined __wrap_open.
      injectVfs = pkgs: drv: drv.overrideAttrs (old:
        let
          lib = pkgs.lib;
          isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
          # macOS has no `ld --wrap`; rewrite zsh's own objects' libc file refs
          # to the VFS shims with llvm-objcopy --redefine-sym (GNU objcopy can't
          # touch Mach-O), then relink. buildPackages so cross-darwin uses a
          # tool that runs on the build host. Mirrors vim's injectVfs.
          objcopy = "${pkgs.buildPackages.llvm}/bin/llvm-objcopy";
        in
        {
        postPatch = (old.postPatch or "") + ''
          echo "==> inject unpin-vfs core (vfs.c + miniz.c, routed via ld --wrap)"
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

        # macOS: zsh is built+linked once already (real libc refs, with our
        # vfs.o/miniz.o/unpin_zstd.o/unpins_zsh_init.o present via EXTRAZSHOBJS
        # but only reached through the redefined refs). Now rewrite every zsh
        # object's libc file references to the _unpinvfs_* shims and relink.
        # The four VFS objects are left untouched so their own REAL_* calls
        # still resolve to libc. x86_64-darwin carries the $INODE64 ABI suffix
        # on stat/lstat/opendir/readdir; aarch64-darwin uses the plain names —
        # list both (--redefine-sym no-ops on absent symbols). Same wrap set as
        # Linux (open/stat/lstat/access/opendir/readdir/closedir/fopen), proven
        # sufficient for compinit's fpath glob + autoload.
        postBuild = (old.postBuild or "") + lib.optionalString isDarwin ''
          echo "==> macOS: redefine zsh's libc file refs -> _unpinvfs_*"
          for o in $(find Src -name '*.o'); do
            case "$o" in
              */vfs.o|*/miniz.o|*/unpin_zstd.o|*/unpins_zsh_init.o) continue ;;
            esac
            ${objcopy} \
              --redefine-sym _open=_unpinvfs_open \
              --redefine-sym _access=_unpinvfs_access \
              --redefine-sym _fopen=_unpinvfs_fopen \
              --redefine-sym _closedir=_unpinvfs_closedir \
              --redefine-sym '_stat$INODE64=_unpinvfs_stat'       --redefine-sym _stat=_unpinvfs_stat \
              --redefine-sym '_lstat$INODE64=_unpinvfs_lstat'     --redefine-sym _lstat=_unpinvfs_lstat \
              --redefine-sym '_opendir$INODE64=_unpinvfs_opendir' --redefine-sym _opendir=_unpinvfs_opendir \
              --redefine-sym '_readdir$INODE64=_unpinvfs_readdir' --redefine-sym _readdir=_unpinvfs_readdir \
              "$o"
          done
          echo "==> macOS: relink zsh against the rewritten objects"
          rm -f Src/zsh
          make -C Src -j''${NIX_BUILD_CORES:-1}
        '';
      });
    in
    unpins-lib.lib.mkStandaloneFlake {
      inherit self;
      name = "zsh";

      # Build via the unpin-llvm engine + emit a bitcode multicall module.
      engine = "unpin-llvm";
      multicall = {
        programs = [{ name = "zsh"; }];
      };
      license = "MIT";

      smoke = [ "-f" "-c" "echo unpins-smoke-ok" ];
      smokePattern = "unpins-smoke-ok";

      # Windows via Cosmopolitan (mingw is a dead end for zsh — needs
      # fork/job-control/signals). See cosmo.nix.
      windowsBuild = import ./cosmo.nix { inherit unpins-lib; };

      build = pkgs:
        let
          vfsDrv = injectVfs pkgs (zshBase pkgs);
        in
        unpins-lib.lib.withUnpinEmbed pkgs
          {
            primary = "zsh";
            man = true;
            manRoot = "${vfsDrv.man}";
            # Stage the function + script trees at the ZIP root (functions/,
            # scripts/) — the mount-relative paths $fpath/UNPIN_VFS_ROOT use.
            runtimeStage = ''
              mkdir -p "$__unpin_stage/functions" "$__unpin_stage/scripts"
              cp -a ${vfsDrv}/share/zsh/*/functions/. "$__unpin_stage/functions/"
              cp -a ${vfsDrv}/share/zsh/*/scripts/.   "$__unpin_stage/scripts/" 2>/dev/null || true
              chmod -R u+w "$__unpin_stage"
            '';
          }
          vfsDrv;
    };
}
