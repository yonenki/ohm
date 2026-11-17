# Windows (x86_64-pc-windows-msvc) development builds

Ohm publishes releases only for Apple Silicon macOS and x86_64 Linux. This fork
adds a local, unoptimized build for `x86_64-pc-windows-msvc` so that a Windows
project can measure Ohm against its pinned upstream toolchain. It is not a
release: it has no PGO, BOLT, or bundled Wild, and `build-optimized-dist.sh`
still rejects the target.

## Sources

`release/windows-msvc/sources.json` names the base manifest and the toolchain
name. Rust, Clippy, and rustfmt come from the base manifest. Cargo comes from a
branch that must descend from the base manifest's Cargo revision; it carries the
Windows defaults described below.
LLVM comes from a branch that must descend from the Rust tree's
`src/llvm-project` gitlink; it carries the MSVC compile fixes.

## LLVM

The build compiles the pinned Ohm LLVM (the Rust tree's `src/llvm-project`
gitlink) from source with the local MSVC toolset, limited to the `X86` and
`WebAssembly` targets.

- Rust's CI LLVM for `x86_64-pc-windows-msvc` cannot be used with an MSVC 14.44
  (Visual Studio 2022) toolset: its static libraries reference vectorized STL
  helpers such as `__std_unique_4` and `__std_max_element_4i`, which first ship
  with MSVC 14.50, so linking `rustc_driver` fails.
- Ohm LLVM's platform-specific additions (the checked-object cache, source
  snapshots) are guarded by `__linux__`; the Rust wrapper detects each Ohm LLVM
  interface through `__has_include` or an `LLVM_OHM_*` macro.
- Run the script from a Visual Studio developer environment (`vcvars64.bat`) so
  CMake and Ninja find `cl.exe`, its headers, and its libraries.

## Cargo defaults on Windows

On Windows hosts Cargo keeps these Ohm defaults off unless the matching flag
enables them explicitly:

| Default | Why | Explicit opt-in |
|---|---|---|
| Cached relinking (`-Zlink-only`), plus the unchanged-test reuse, deferred dev-dependency planning, and doctest link checks that read its cache | COFF/`lld-link` inputs are unvalidated (ohm-cargo#51) | `-Zrelink-only=yes` |
| Inline doctest cache | Depends on the relink cache and Windows lock lifetimes | `-Zohm-cached-doctests=yes` |
| Worktree seed preparation | Windows has no file-cloning implementation, so seeds are never imported; preparation still changes paths and fingerprints | `-Zohm-worktree-seeds=yes` |
| Automatic shared build directory from `CARGO_BUILD_BUILD_DIR` | Child lock inheritance is Unix-only (ohm-cargo#100) | `-Zohm-shared-registry-cache` |

Every other Ohm default is unchanged, including public API hashes, check/build
stage sharing, Headstart, early integration tests, and the compiler-side
optimizations.

The branch also treats an empty `RUSTC_WRAPPER` or `RUSTC_WORKSPACE_WRAPPER`
(environment or `build.rustc-*wrapper` config) as absent. Cargo already runs
rustc directly in that case, but Ohm's wrapper checks saw a wrapper and turned
off stage sharing and built-dependency reuse for workspace members. A non-empty
wrapper (for example a compiler cache) still disables the Ohm paths that keep
ordinary compilation under a wrapper.

## Build

From Git Bash, with rustup, Git, Python 3, and the Visual Studio C++ build tools:

```bash
scripts/build-windows-msvc-dist.sh --prepare-only WORK_DIRECTORY  # sources + dry-run plan
scripts/build-windows-msvc-dist.sh WORK_DIRECTORY                 # build, install, rustup link
```

The script runs `x.py dist` for `rustc`, `rust-std` (host and
`wasm32-unknown-unknown`), `cargo`, `clippy`, `rustfmt`, and `rust-src`,
installs the archives into `WORK_DIRECTORY/toolchains/<name>`, and registers that
directory with `rustup toolchain link`. `OHM_BUILD_JOBS` limits parallelism.
`WORK_DIRECTORY` doubles as `CARGO_HOME` for bootstrap: Cargo stops its
workspace search there, so the build works inside another Cargo workspace.
