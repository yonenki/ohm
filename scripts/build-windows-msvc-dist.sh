#!/usr/bin/env bash
# Build, install, and register an Ohm toolchain for x86_64-pc-windows-msvc.
#
# Run from Git Bash on a Windows host with rustup, Git, Python 3, and the Visual
# Studio C++ build tools. The sources come from release/windows-msvc/sources.json:
# Rust, Clippy, and rustfmt at the base manifest's revisions, and Cargo at the
# Windows branch that descends from the base manifest's Cargo revision. LLVM is
# the pinned Ohm LLVM, built from source (see docs/windows-msvc.md).
#
#   build-windows-msvc-dist.sh [--prepare-only] WORK_DIRECTORY
#
# --prepare-only checks out the sources, writes the bootstrap configuration, and
# plans the distribution with `x.py dist --dry-run` without compiling the toolchain.
#
# Environment:
#   OHM_BUILD_JOBS          bootstrap job count (default: every logical CPU)
#   OHM_REPLACE_TOOLCHAIN=1 unlink and replace an existing installation
#   OHM_BUILD_DIRECTORY     x.py build directory (default: WORK_DIRECTORY/build)
#   PYTHON                  Python 3 interpreter (default: python)
set -euo pipefail
unset CDPATH
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH

target=x86_64-pc-windows-msvc
targets="$target,wasm32-unknown-unknown"
dist_paths=(rustc rust-std cargo clippy rustfmt rust-src)

prepare_only=false
if [[ "${1:-}" == --prepare-only ]]; then
  prepare_only=true
  shift
fi
if [[ $# -ne 1 ]]; then
  echo 'usage: build-windows-msvc-dist.sh [--prepare-only] WORK_DIRECTORY' >&2
  exit 2
fi

case "$(uname -s)" in
  MINGW* | MSYS*) ;;
  *)
    echo 'build-windows-msvc-dist.sh must run in Git Bash on Windows' >&2
    exit 1
    ;;
esac

python="${PYTHON:-python}"
# CMake builds LLVM with the MSVC toolset from a Visual Studio developer
# environment (vcvars64.bat), which also provides cl.exe on PATH.
for tool in git rustup cmake ninja cl "$python"; do
  command -v "$tool" >/dev/null || {
    echo "required tool not found: $tool" >&2
    exit 1
  }
done

mkdir -p -- "$1"
work="$(cd -P -- "$1" && pwd)"
coordinator="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
overlay="$coordinator/release/windows-msvc/sources.json"
bootstrap_template="$coordinator/release/windows-msvc/bootstrap.toml"

json() {
  "$python" -c 'import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for key in sys.argv[2].split("."):
    value = value[key]
print(value)' "$1" "$2"
}

manifest="$coordinator/$(json "$overlay" base_manifest)"
toolchain="$(json "$overlay" toolchain_name)"
rust_repository="$(json "$manifest" sources.rust.repository)"
rust_revision="$(json "$manifest" sources.rust.revision)"
clippy_repository="$(json "$manifest" sources.clippy.repository)"
clippy_revision="$(json "$manifest" sources.clippy.revision)"
rustfmt_repository="$(json "$manifest" sources.rustfmt.repository)"
rustfmt_revision="$(json "$manifest" sources.rustfmt.revision)"
cargo_repository="$(json "$overlay" cargo.repository)"
cargo_revision="$(json "$overlay" cargo.revision)"
cargo_base_revision="$(json "$overlay" cargo.base_revision)"
if [[ "$cargo_base_revision" != "$(json "$manifest" sources.cargo.revision)" ]]; then
  echo "the Windows Cargo branch must descend from the base manifest's Cargo revision" >&2
  exit 1
fi
llvm_repository="$(json "$overlay" llvm.repository)"
llvm_revision="$(json "$overlay" llvm.revision)"
llvm_base_revision="$(json "$overlay" llvm.base_revision)"

rust="$work/src/rust"
mkdir -p -- "${OHM_BUILD_DIRECTORY:-$work/build}"
build="$(cd -P -- "${OHM_BUILD_DIRECTORY:-$work/build}" && pwd)"
prefix="$work/toolchains/$toolchain"

# Check out REVISION into DIRECTORY, reusing an existing clean checkout. The
# Rust tree's tool checkouts (nested repositories) are verified on their own.
checkout() {
  local directory="$1" repository="$2" revision="$3"
  shift 3
  if [[ -e "$directory/.git" ]]; then
    if [[ -n "$(git -C "$directory" status --porcelain --untracked-files=no --ignore-submodules=all \
      -- . ':(exclude)src/tools/clippy' ':(exclude)src/tools/rustfmt')" ]]; then
      echo "source checkout has local changes: $directory" >&2
      exit 1
    fi
  else
    mkdir -p -- "$directory"
    git -C "$directory" init --quiet
    git -C "$directory" config core.longpaths true
    git -C "$directory" config core.autocrlf false
    git -C "$directory" remote add origin "$repository"
  fi
  if [[ "$(git -C "$directory" rev-parse --verify --quiet HEAD || true)" != "$revision" ]]; then
    if ! git -C "$directory" cat-file -e "$revision^{commit}" 2>/dev/null; then
      git -C "$directory" fetch --quiet --no-tags "$@" "$repository" "$revision"
    fi
    git -C "$directory" -c advice.detachedHead=false checkout --quiet "$revision"
  fi
  echo "$directory: $(git -C "$directory" rev-parse HEAD)"
}

# The Rust checkout keeps full history (without blobs) like the release build.
checkout "$rust" "$rust_repository" "$rust_revision" --filter=blob:none
git -C "$rust" -c core.longpaths=true submodule update --init --depth 1 -- library/backtrace \
  src/doc/book src/doc/edition-guide src/doc/embedded-book src/doc/nomicon src/doc/reference \
  src/doc/rust-by-example
read -r _ _ pinned_llvm _ <<< "$(git -C "$rust" ls-tree HEAD -- src/llvm-project)"
if [[ "$pinned_llvm" != "$llvm_base_revision" ]]; then
  echo "the Windows LLVM branch must descend from the Rust tree's LLVM gitlink $pinned_llvm" >&2
  exit 1
fi
# The Windows LLVM branch carries MSVC fixes on top of the gitlink revision.
checkout "$rust/src/llvm-project" "$llvm_repository" "$llvm_revision" --depth=2
if ! git -C "$rust/src/llvm-project" merge-base --is-ancestor "$llvm_base_revision" HEAD; then
  echo "LLVM $llvm_revision does not descend from $llvm_base_revision" >&2
  exit 1
fi

# Clippy and rustfmt are subtrees of the Rust tree; replace them with the pinned
# Ohm repositories exactly as the release workflow does.
for tool in clippy rustfmt; do
  if [[ ! -e "$rust/src/tools/$tool/.git" ]]; then
    rm -rf -- "${rust:?}/src/tools/$tool"
  fi
done
checkout "$rust/src/tools/clippy" "$clippy_repository" "$clippy_revision" --depth=1
checkout "$rust/src/tools/rustfmt" "$rustfmt_repository" "$rustfmt_revision" --depth=1
# Cargo is an uninitialized gitlink (an empty directory) in the Rust tree.
checkout "$rust/src/tools/cargo" "$cargo_repository" "$cargo_revision" --filter=blob:none
if ! git -C "$rust/src/tools/cargo" merge-base --is-ancestor "$cargo_base_revision" HEAD; then
  echo "Cargo $cargo_revision does not descend from $cargo_base_revision" >&2
  exit 1
fi

mkdir -p -- "$build" "$work/logs"
config="$build/ohm-windows-bootstrap.toml"
if ! awk -v toolchain="$toolchain" '
  /^description[[:space:]]*=[[:space:]]*"Ohm"[[:space:]]*$/ {
    print "description = \"" toolchain "\""
    replacements++
    next
  }
  { print }
  END { if (replacements != 1) exit 1 }
' "$bootstrap_template" >"$config"; then
  echo 'Windows bootstrap configuration is missing its description' >&2
  exit 1
fi

# Keep the developer's Cargo, rustup, and compiler-cache settings out of bootstrap.
while IFS= read -r variable; do
  case "$variable" in
    CARGO_HOME | RUSTUP_HOME) ;;
    CARGO_* | RUSTC* | RUSTDOC* | RUSTFLAGS | RUSTUP_TOOLCHAIN | KACHE_* | SCCACHE_*)
      unset "$variable"
      ;;
  esac
done < <(compgen -e)
export RUST_BOOTSTRAP_CONFIG="$config"

jobs="${OHM_BUILD_JOBS:-$(nproc)}"
# Cargo stops its workspace search at CARGO_HOME. Bootstrap and other packages
# that the Rust workspace excludes would otherwise join any Cargo workspace that
# contains WORK_DIRECTORY. This also keeps the user's Cargo configuration out.
dist=(env "CARGO_HOME=$(cygpath -w "$work")" "$python" "$rust/x.py" dist
  --config "$config"
  --build-dir "$build"
  --host "$target"
  --target "$targets"
  --jobs "$jobs"
  "${dist_paths[@]}")

cd -- "$rust"
if [[ "$prepare_only" == true ]]; then
  "${dist[@]}" --dry-run
  echo "prepared $toolchain; build with: $0 $work"
  exit 0
fi

log="$work/logs/dist-$(date +%Y%m%dT%H%M%S).log"
echo "building $toolchain with $jobs jobs; log: $log"
SECONDS=0
"${dist[@]}" 2>&1 | tee "$log"
echo "x.py dist finished in ${SECONDS}s" | tee -a "$log"

if rustup toolchain list | grep -qx -- "$toolchain"; then
  if [[ "${OHM_REPLACE_TOOLCHAIN:-}" != 1 ]]; then
    echo "rustup toolchain $toolchain already exists; set OHM_REPLACE_TOOLCHAIN=1 to replace it" >&2
    exit 1
  fi
  rustup toolchain uninstall "$toolchain"
fi
if [[ -e "$prefix" ]]; then
  if [[ "${OHM_REPLACE_TOOLCHAIN:-}" != 1 ]]; then
    echo "installation already exists: $prefix" >&2
    exit 1
  fi
  rm -rf -- "$prefix"
fi

staging="$(mktemp -d "$work/toolchains/.install.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
install_component() {
  local pattern="$1" archives
  shopt -s nullglob
  archives=("$build"/dist/$pattern.tar.gz)
  shopt -u nullglob
  if [[ ${#archives[@]} -ne 1 ]]; then
    echo "expected one distribution archive matching $pattern, found ${#archives[@]}" >&2
    exit 1
  fi
  tar -xzf "${archives[0]}" -C "$staging"
  local name
  name="$(basename -- "${archives[0]}" .tar.gz)"
  bash "$staging/$name/install.sh" --prefix="$staging/prefix" --disable-ldconfig
  rm -rf -- "${staging:?}/$name"
}
for component in "rustc-*-$target" "rust-std-*-$target" 'rust-std-*-wasm32-unknown-unknown' \
  "cargo-*-$target" "clippy-*-$target" "rustfmt-*-$target" 'rust-src-*[0-9a-z]'; do
  install_component "$component"
done

"$python" - "$staging/prefix/ohm-provenance.json" <<PROVENANCE
import json, sys
json.dump({
    "toolchain": "$toolchain",
    "target": "$target",
    "manifest": "$(json "$overlay" base_manifest)",
    "coordinator_revision": "$(git -C "$coordinator" rev-parse HEAD)",
    "sources": {
        "rust": "$rust_revision",
        "cargo": "$cargo_revision",
        "clippy": "$clippy_revision",
        "rustfmt": "$rustfmt_revision",
        "llvm": "$(git -C "$rust/src/llvm-project" rev-parse HEAD)",
    },
}, open(sys.argv[1], "w", encoding="utf-8"), indent=2)
PROVENANCE

mkdir -p -- "$(dirname -- "$prefix")"
mv -- "$staging/prefix" "$prefix"
rustup toolchain link "$toolchain" "$(cygpath -w "$prefix")"

for required in "lib/rustlib/$target/bin/rust-lld.exe" lib/rustlib/wasm32-unknown-unknown/lib \
  lib/rustlib/src/rust/library; do
  if [[ ! -e "$prefix/$required" ]]; then
    echo "installed toolchain is missing $required" >&2
    exit 1
  fi
done
rustc "+$toolchain" -vV
cargo "+$toolchain" -V
cargo "+$toolchain" clippy -V
rustfmt "+$toolchain" -V
echo "registered $toolchain at $prefix"
