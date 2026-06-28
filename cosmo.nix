# zsh via cosmoStaticCross (= pkgs.pkgsCross.cosmo) for Windows-x86_64.
#
# Full single-binary: cosmocc builds zsh with every cosmo-buildable
# module linked in (--disable-dynamic) AND the runtime function/completion tree
# embedded via the shared unpin-vfs core, same as the native build. The cosmo
# cross stdenv auto-apelinks $out/bin/* (ELF -> PE32+, rename to <name>.exe) in
# fixupPhase; withUnpinEmbed's postFixup then appends the runtime+man container
# at EOF (after apelink — PE tolerates trailing overlay data, verified).
#
# unpin-vfs on cosmo: cosmo defines neither _WIN32 nor __APPLE__, so vfs.c
# compiles its Linux branch — `ld --wrap` works under cosmocc's ld.bfd. Two
# Linux assumptions do NOT hold on the APE, so vfs.c has two __COSMOPOLITAN__
# arms (both probed under wine, then confirmed on a real Windows VM):
#   - self_open: /proc/self/exe is synthesized on cosmo-Windows and reports the
#     baked image size, hiding the EOF-appended container — so it reads
#     GetProgramExecutableName() (the real on-disk path) instead.
#   - anon_fd: memfd_create returns -1 on cosmo-Windows, so it uses
#     mkstemp+unlink (cosmo emulates POSIX delete-while-open).
{ unpins-lib }:
pkgs:
let
  cosmoPkgs = unpins-lib.lib.cosmoStaticCross pkgs;

  cosmoZsh = cosmoPkgs.zsh.overrideAttrs (oa: {
    # Same GCC-ICE dodge as native (sort.c under _FORTIFY_SOURCE=2). Harmless on
    # cosmocc; keep for parity.
    hardeningDisable = (oa.hardeningDisable or [ ]) ++ [ "fortify" "fortify3" ];

    postPatch = (oa.postPatch or "") + ''
      # Cosmopolitan abstracts over several OSes whose rlimit numbering differs,
      # so it exposes RLIM_NLIMITS / RLIMIT_* as runtime `extern const` symbols,
      # NOT compile-time constants. zsh's core uses RLIM_NLIMITS as a file-scope
      # array dimension (`struct rlimit current_limits[RLIM_NLIMITS]` in exec.c,
      # mirrored into exec.epro) — a constant expression is required there. Pin
      # it to a fixed upper bound right after <sys/resource.h> (the loops that
      # walk it call getrlimit(i) and tolerate EINVAL for unused slots). 16
      # covers every RLIMIT_* cosmo defines (RLIMIT_AS..RLIMIT_SWAP).
      substituteInPlace Src/zsh_system.h \
        --replace '# include <sys/resource.h>' \
                  '# include <sys/resource.h>
# ifdef __COSMOPOLITAN__
#  undef RLIM_NLIMITS
#  define RLIM_NLIMITS 16
# endif'

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

      # Windows command lookup: catalog programs install as `<name>.exe`
      # hardlinks (cmd.exe/PowerShell find them via PATHEXT), but Cosmopolitan
      # does not append an executable suffix during path resolution, so a bare
      # `ls` typed at the zsh prompt never resolves. The patch teaches zsh's PATH
      # search (hashcmd) to retry a candidate with `.exe` when the bare name is
      # missing, hashing the resolved `.exe` path so it reaches zexecve —
      # mirroring native Windows shells and keeping a single on-disk name (no
      # `ls` + `ls.exe` pair). `__COSMOCC__`-guarded, inert elsewhere.
      patch -p1 < ${./findcmd-exe-lookup.patch}
    '';

    # Drop the NixOS-only global zshenv (dead /nix/store path stat'd every
    # start; meaningless on Windows), and force a single self-contained binary:
    # --disable-dynamic links every module into the executable instead of
    # producing per-module .so files (cosmo's APE can't dlopen anyway). It also
    # resolves the cross-module link errors (rlimits.so: undefined
    # `setfeatureenables`) — those symbols live in the main binary and only
    # resolve once modules are statically linked in.
    configureFlags =
      builtins.filter
        (f: !(pkgs.lib.hasPrefix "--enable-zshenv=" f))
        (oa.configureFlags or [ ])
      ++ [ "--disable-dynamic" ];

    # Force every cosmo-buildable module into the static binary (same knob as
    # the native build: editing config.modules after configure is upstream-
    # supported). Exclude the modules whose backing library/header cosmo doesn't
    # provide — forcing them from `link=no` to `link=static` would fail to
    # compile/link:
    #   - zsh/cap     → libcap (Linux POSIX.1e capabilities); no cosmo port, and
    #                   capabilities are meaningless on Windows anyway.
    #   - zsh/db/*    → gdbm / Berkeley DB / tdb; no cosmo overlay for any.
    #   - zsh/attr    → <sys/xattr.h> (Linux/macOS xattrs); absent on cosmo.
    #   - zsh/net/tcp → <netinet/in_systm.h> (BSD raw-IP header) absent on cosmo.
    #   - zsh/zftp    → <arpa/telnet.h> absent on cosmo.
    #   - zsh/zpty    → <sys/stropts.h>/openpty: no POSIX ptys on Windows.
    # Everything else (mathfunc, pcre, regex, system, stat, net/socket, …) is
    # forced in; modules that are no-ops on Windows still load and degrade
    # gracefully at runtime.
    #
    # Then pre-compile the VFS objects and put them on the link line. zsh links
    # through a recursive `make -f Makemod` that overrides EXTRA_LDFLAGS and is
    # regenerated from the .mdd files, so (as on native) the only robust hooks
    # are EXTRAZSHOBJS (concatenated into Makemod) for the objects and
    # NIX_LDFLAGS for the `--wrap` flags. Compiled in preBuild, after configure.
    preBuild = (oa.preBuild or "") + ''
      sed -i 's/ link=no / link=static /' config.modules
      for m in zsh/cap zsh/db/gdbm zsh/db/db zsh/db/tdb zsh/attr \
               zsh/net/tcp zsh/zftp zsh/zpty; do
        sed -i "\#name=$m #s/ link=[a-z]* / link=no /" config.modules
      done

      echo "==> pre-compile unpin-vfs objects (cosmocc)"
      UNPIN_VFS_DEFS="-DUNPIN_VFS_DIRS -DUNPIN_VFS_SELF -DUNPIN_VFS_ROOT=\"/__unpins_zshruntime__/\""
      MINIZ_DEFS="-DMINIZ_USE_ZSTD -DMINIZ_NO_TIME -DMINIZ_NO_ARCHIVE_WRITING_APIS -DMINIZ_NO_ZLIB_APIS -DMINIZ_NO_ZLIB_COMPATIBLE_NAMES"
      ( cd Src
        $CC -O2 -c vfs.c            $UNPIN_VFS_DEFS $MINIZ_DEFS -o vfs.o
        $CC -O2 -c miniz.c          -D_GNU_SOURCE -w $MINIZ_DEFS -o miniz.o
        $CC -O2 -c unpin_zstd.c     -D_GNU_SOURCE -w $MINIZ_DEFS -DUNPIN_ZSTD_VENDORED -o unpin_zstd.o
        $CC -O2 -c unpins_zsh_init.c -D_GNU_SOURCE -o unpins_zsh_init.o
      )
      echo 'EXTRAZSHOBJS += vfs.o miniz.o unpin_zstd.o unpins_zsh_init.o' >> Src/Makefile
      export NIX_LDFLAGS="$NIX_LDFLAGS --wrap=open --wrap=stat --wrap=lstat --wrap=access --wrap=opendir --wrap=readdir --wrap=closedir --wrap=fopen"
    '';

    # zsh's configure bakes `-s` into EXELDFLAGS, stripping the executable at
    # LINK time — so the .symtab cosmo's apelink reads to convert ELF -> PE32+ is
    # gone before install even runs. Blank EXELDFLAGS/LIBLDFLAGS (their only
    # content here is `-s`) and STRIPFLAGS so the binary keeps its symbol table;
    # the cosmo stdenv's fixup strips the final .exe after apelink.
    makeFlags = (oa.makeFlags or [ ]) ++ [ "EXELDFLAGS=" "LIBLDFLAGS=" ];
    installFlags = (oa.installFlags or [ ]) ++ [ "STRIPFLAGS=" ];

    # gcc-14 under -std=gnu23 (cosmocc default) makes an implicit function
    # declaration a hard error. zsh's configure probes report several libc
    # functions present (cosmo HAS them) but cosmo's headers don't always
    # declare them on the path zsh includes — e.g. prctl(PR_SET_NAME) in jobs.c.
    # Downgrade to a warning so the implicit decl links against cosmo's real
    # symbol (same fix dash's cosmo.nix uses).
    env = (oa.env or { }) // {
      NIX_CFLAGS_COMPILE = builtins.concatStringsSep " " [
        (oa.env.NIX_CFLAGS_COMPILE or "")
        "-Wno-implicit-function-declaration"
      ];
    };
  });
in
# The PRISTINE cosmo zsh base + the embed spec consumed by mkStandaloneFlake's
# runtimeEmbed.windows → unpinEmbedWrap (the single embed path; it appends the
# container at EOF after apelink and handles the `.exe` suffix): stage the
# function+script trees at the ZIP root (the mount-relative paths
# $fpath/UNPIN_VFS_ROOT use) and embed the cosmo build's own man.
{
  base = cosmoZsh;
  embed = {
    man = true;
    manRoot = "${cosmoZsh.man or cosmoZsh}";
    runtimeStage = ''
      mkdir -p "$__unpin_stage/functions" "$__unpin_stage/scripts"
      cp -a ${cosmoZsh}/share/zsh/*/functions/. "$__unpin_stage/functions/"
      cp -a ${cosmoZsh}/share/zsh/*/scripts/.   "$__unpin_stage/scripts/" 2>/dev/null || true
      chmod -R u+w "$__unpin_stage"
    '';
  };
}
