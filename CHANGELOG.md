# Changelog

## [Unreleased]

### Added

- First release of Zsh 5.9 as a single self-contained binary for Linux, macOS
  and Windows, on x86_64 and arm64 (plus i686, armv7l, ppc64le and riscv64 on
  Linux).

  Everything a normal zsh install spreads across a directory tree rides inside
  the one file: the complete function and completion set, so
  `autoload -Uz compinit && compinit` gives you the usual 1723 completions with
  nothing else installed, and the whole manual set, so `unpin man zsh` and
  `unpin man zsh zshbuiltins` work offline. Every module is built in — all 39
  of them on Linux, 33 on Windows, where the rest have no library to sit on —
  so `zmodload zsh/pcre`, `zsh/mathfunc`, `zsh/zpty` and the others work
  without a module directory to load from.

  Job control, `fork` and the completion system work on Windows as well; the
  binary there is built with Cosmopolitan, since mingw offers none of those.
