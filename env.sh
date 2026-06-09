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
export ELOQDB_SUBMODULES="$ELOQDB_DEPS/sub_modules"  # eloqdata forks of upstream (latest)
export ELOQDB_DATA_SUBSTRATE="$ELOQDB_DEPS/data_substrate"  # the shared core (its own top-level checkout)
export ELOQDB_DATA_SUBSTRATE_REPO="${ELOQDB_DATA_SUBSTRATE_REPO:-https://github.com/eloqdata/tx_service.git}"
export ELOQDB_DATA_SUBSTRATE_BRANCH="${ELOQDB_DATA_SUBSTRATE_BRANCH:-}"   # empty => remote default (unless ELOQDB_MOD_BRANCH exists)

# SSH keepalive for git: this host's connections to github.com occasionally go silent mid-transfer
# (TCP stays ESTABLISHED, zero throughput, no FIN/RST) — plain `ssh`/`git fetch` then hangs forever.
# ServerAlive* makes ssh probe and give up on a dead connection within ~30s so git fails fast and
# can be retried, instead of blocking the build indefinitely.
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o ConnectTimeout=15 -o ServerAliveInterval=10 -o ServerAliveCountMax=3}"

# Modifications branch: our changes to Eloq-owned repos live on this branch IN the eloqdata repos
# (no separate forks). The build prefers it when the remote has it, else falls back to the default
# branch. This keeps eloqdata default branches pristine while isolating our changes.
export ELOQDB_MOD_BRANCH="${ELOQDB_MOD_BRANCH:-lintao-mod}"

# Cloud opt-in — single all-or-nothing switch, no separate aws/gcp/rocksdb-cloud flags:
#   0 (default) = local-only build. Pulls none of aws-sdk-cpp / google-cloud-cpp / rocksdb-cloud,
#                 and EloqStore's cloud (S3/GCS) object-storage backend compiles out to a stub
#                 (ELOQSTORE_WITH_CLOUD off, via -DWITH_CLOUD_STORAGE=OFF on lintao-mod).
#   1            = pulls the whole cloud stack (deps.sh --with-cloud) and enables EloqStore's
#                 cloud-backed storage. Also required for DynamoDB / Bigtable / cloud-RocksDB
#                 backends — they have no local-only fallback. Override by exporting
#                 ELOQDB_WITH_CLOUD before sourcing.
export ELOQDB_WITH_CLOUD="${ELOQDB_WITH_CLOUD:-0}"

export ELOQDB_BUILD="${ELOQDB_BUILD:-$ELOQDB_ROOT/build}"          # all build trees (pre-settable)
export ELOQDB_PROJECTS="${ELOQDB_PROJECTS:-$ELOQDB_ROOT/projects}" # product checkouts (pre-settable)

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
# Capped for memory: the heavy C++ TUs (MariaDB sql/, abseil, tx_service) can use multiple GB
# each, so a full-core -j OOM-kills the build on modest-RAM hosts. Default to min(nproc, mem/2GB);
# lower ELOQDB_JOBS to 4 if a build still dies suddenly.
if [ -z "${ELOQDB_JOBS:-}" ]; then
    _eloqdb_nproc="$(nproc)"
    _eloqdb_memgb="$(awk '/MemTotal/{printf "%d", $2/1024/1024/2}' /proc/meminfo 2>/dev/null || echo "$_eloqdb_nproc")"
    ELOQDB_JOBS=$_eloqdb_nproc
    [ "$_eloqdb_memgb" -gt 0 ] && [ "$_eloqdb_memgb" -lt "$ELOQDB_JOBS" ] && ELOQDB_JOBS=$_eloqdb_memgb
    unset _eloqdb_nproc _eloqdb_memgb
fi
export ELOQDB_JOBS

# Common CMake flags every dependency uses to install into the shared prefix, no sudo.
export ELOQDB_CMAKE_ARGS="-DCMAKE_INSTALL_PREFIX=$ELOQDB_PREFIX -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_SHARED_LIBS=ON"
