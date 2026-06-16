# zsh

[Zsh](https://www.zsh.org/) — the Z shell, a powerful interactive shell and scripting language (the default login shell on macOS). A single self-contained binary, built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/zsh/actions/workflows/zsh.yml/badge.svg)](https://github.com/unpins/zsh/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install zsh`.

## Usage

Run `zsh` with [unpin](https://github.com/unpins/unpin):

```bash
unpin zsh                       # start an interactive shell
unpin zsh script.zsh            # run a script
unpin zsh -c 'echo $ZSH_VERSION'
```

To install it onto your PATH:

```bash
unpin install zsh
```

Completions and autoloadable functions work out of the box — `compinit` finds
the full completion set (1723 functions) because the entire
`share/zsh/<ver>/functions` tree is embedded in the binary:

```zsh
autoload -Uz compinit && compinit   # tab-completion, served from the binary
autoload -Uz zmv                    # any shipped function autoloads
```

## Man pages

The full zsh manual set (`zshall`, `zshbuiltins`, `zshcompsys`, …) is embedded,
so `unpin man zsh` and `unpin man zsh zshbuiltins` work offline.

## Build locally

```bash
nix build github:unpins/zsh
./result/bin/zsh -c 'echo $ZSH_VERSION'
```

Or run directly:

```bash
nix run github:unpins/zsh -- -c 'print -l hi'
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/zsh/releases) page has standalone binaries for manual download.

## Build notes

- **Every module linked in.** A static build of zsh normally drops every module
  whose `.mdd` says `link=dynamic` (mathfunc, pcre, regex, system, stat, zpty,
  the `zsh/net/*` family, …). We force the whole set back into the static link
  (`config.modules` `link=no` → `link=static`, the upstream-supported knob) and
  turn on `--enable-gdbm` and Linux `--enable-cap`, so all 38 modules
  `zmodload`-load and work. On macOS/Windows the handful with no backing
  library/header (cap, db/*, attr, net/tcp, zftp, zpty) stay out — configure
  detection handles that — leaving 30+ live modules there.

- **Completion/function tree embedded (unpin-vfs).** zsh resolves `$fpath`
  functions with `open()` and globs the directory with `opendir`/`readdir`
  (that's how `compinit` discovers completions), so a single binary with no
  files on disk would have empty completion. The whole
  `share/zsh/<ver>/functions` + `scripts` tree is packed into a ZIP appended at
  the binary's EOF and served by the shared
  [unpin-vfs](https://github.com/unpins/unpin) core; `$fpath` is pointed at the
  in-binary mount. On Linux the libc file calls are routed through the VFS with
  `ld --wrap`; on macOS (no `--wrap` for Mach-O) zsh's own objects are rewritten
  with `llvm-objcopy --redefine-sym` and relinked. `strace` shows zero
  `/nix/store` reads during `compinit`.

- **Static linking, every target.** Linux is static-musl (every arch); the
  binary carries a curated ncurses terminfo fallback so `zle`/`terminfo` work
  with no `/usr/share/terminfo` on the host and the binary keeps no
  `/nix/store` reference. macOS links only `libSystem` (everything else —
  ncurses, pcre2, gdbm, iconv — is static; `otool -L` confirms).

- **Windows via Cosmopolitan.** mingw can't host zsh (no `fork`, job control, or
  POSIX signals), so the Windows binary goes through cosmo. The same VFS core
  serves the embedded function tree; `fork`, job-control, and the full
  `compinit` (all 1723 completions) are verified on a real Windows install. See
  `cosmo.nix`.
