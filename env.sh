# EloqDB shared build environment.
# Usage:  source env.sh
# Defines the local, sudo-free install prefix that every dependency installs into
# and every product builds against. No system directories are touched.

# Resolve the repo root from this file's location (works when sourced from anywhere).
if [ -n "${BASH_SOURCE[0]:-}" ]; then
    _eloqdb_self="${BASH_SOURCE[0]}"
else
    _eloqdb_self="$0"
fi
export ELOQDB_ROOT="$(cd "$(dirname "$_eloqdb_self")" && pwd)"
unset _eloqdb_self

# Canonical locations.
export ELOQDB_PREFIX="$ELOQDB_ROOT/install"          # the shared local prefix (replaces /usr/local)
export ELOQDB_DEPS="$ELOQDB_ROOT/dependencies"       # dependency source checkouts
export ELOQDB_THIRD_PARTY="$ELOQDB_DEPS/third_party" # pinned upstream deps
export ELOQDB_SUBMODULES="$ELOQDB_DEPS/sub_modules"  # eloqdata/ltzhang forks (latest)
export ELOQDB_DATA_SUBSTRATE="$ELOQDB_DEPS/data_substrate"  # the shared core (its own top-level checkout)
export ELOQDB_DATA_SUBSTRATE_REPO="${ELOQDB_DATA_SUBSTRATE_REPO:-https://github.com/eloqdata/tx_service.git}"
export ELOQDB_DATA_SUBSTRATE_BRANCH="${ELOQDB_DATA_SUBSTRATE_BRANCH:-}"   # empty => remote default (unless ELOQDB_MOD_BRANCH exists)

# Modifications branch: our changes to Eloq-owned repos live on this branch IN the eloqdata repos
# (no separate forks). The build prefers it when the remote has it, else falls back to the default
# branch. This keeps eloqdata default branches pristine while isolating our changes.
export ELOQDB_MOD_BRANCH="${ELOQDB_MOD_BRANCH:-lintao-mod}"
export ELOQDB_BUILD="$ELOQDB_ROOT/build"             # all build trees
export ELOQDB_PROJECTS="$ELOQDB_ROOT/projects"       # product checkouts (optional)

mkdir -p "$ELOQDB_PREFIX" "$ELOQDB_THIRD_PARTY" "$ELOQDB_SUBMODULES" \
         "$ELOQDB_BUILD" "$ELOQDB_PROJECTS"

# The dependency contract: how every build finds the shared prefix instead of /usr.
# NOTE: we deliberately do NOT export CPATH / LIBRARY_PATH. CMake find_path/find_library
# (used throughout data_substrate and the products) search CMAKE_PREFIX_PATH, so the prefix
# is discoverable without globally injecting its headers into every compile. A global CPATH
# leaks the prefix's abseil into data_substrate's *vendored* (newer) abseil build, breaking it.
export CMAKE_PREFIX_PATH="$ELOQDB_PREFIX${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export PKG_CONFIG_PATH="$ELOQDB_PREFIX/lib/pkgconfig:$ELOQDB_PREFIX/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export LD_LIBRARY_PATH="$ELOQDB_PREFIX/lib:$ELOQDB_PREFIX/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export PATH="$ELOQDB_PREFIX/bin:$PATH"

# Parallelism for builds (override by exporting ELOQDB_JOBS before sourcing).
export ELOQDB_JOBS="${ELOQDB_JOBS:-$(nproc)}"

# Common CMake flags every dependency uses to install into the shared prefix, no sudo.
export ELOQDB_CMAKE_ARGS="-DCMAKE_INSTALL_PREFIX=$ELOQDB_PREFIX -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=ON"
