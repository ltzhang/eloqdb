# Shared helpers for EloqDB build scripts. Source after env.sh.
# shellcheck shell=bash

set -euo pipefail

eloqdb_log()  { printf '\033[1;34m[eloqdb]\033[0m %s\n' "$*"; }
eloqdb_warn() { printf '\033[1;33m[eloqdb:warn]\033[0m %s\n' "$*" >&2; }
eloqdb_die()  { printf '\033[1;31m[eloqdb:error]\033[0m %s\n' "$*" >&2; exit 1; }

# Retry a command a few times (network resilience).
run_with_retry() {
    local n=0 max=3
    until "$@"; do
        n=$((n + 1))
        [ "$n" -ge "$max" ] && return 1
        eloqdb_warn "retry $n/$max: $*"
        sleep $((n * 3))
    done
}

# clone_latest <url> <dest> [branch]
# For eloqdata/ltzhang repos: clone (or fast-forward) to the latest HEAD of the
# eloq_pick_branch <url> [fallback]
# Echo ELOQDB_MOD_BRANCH if the remote has it (our changes live there), else the fallback
# (empty => the remote's default branch). Lets us keep eloqdata default branches pristine.
eloq_pick_branch() {
    local url=$1 fallback=${2:-}
    if [ -n "${ELOQDB_MOD_BRANCH:-}" ] && \
       git ls-remote --heads "$url" "$ELOQDB_MOD_BRANCH" 2>/dev/null | grep -q "refs/heads/$ELOQDB_MOD_BRANCH"; then
        echo "$ELOQDB_MOD_BRANCH"
    else
        echo "$fallback"
    fi
}

# default or named branch. Always tracks latest — ignores any pinned commit.
# Prefers ELOQDB_MOD_BRANCH (our modifications branch) when the remote has it.
clone_latest() {
    local url=$1 dest=$2 branch=${3:-}
    branch="$(eloq_pick_branch "$url" "$branch")"
    if [ -d "$dest/.git" ]; then
        eloqdb_log "update (latest): $dest"
        git -C "$dest" fetch --recurse-submodules origin
        if [ -n "$branch" ]; then git -C "$dest" checkout "$branch"; fi
        git -C "$dest" pull --recurse-submodules --ff-only
    else
        eloqdb_log "clone (latest): $url -> $dest"
        local args=(clone --recurse-submodules)
        [ -n "$branch" ] && args+=(-b "$branch")
        run_with_retry git "${args[@]}" "$url" "$dest"
    fi
    git -C "$dest" submodule update --init --recursive
}

# clone_pinned <url> <dest> <ref>
# For third-party git deps: clone and check out an exact pinned tag/branch/commit.
clone_pinned() {
    local url=$1 dest=$2 ref=$3
    if [ -d "$dest/.git" ]; then
        eloqdb_log "update (pinned $ref): $dest"
        git -C "$dest" fetch origin --tags
    else
        eloqdb_log "clone (pinned $ref): $url -> $dest"
        run_with_retry git clone "$url" "$dest"
    fi
    git -C "$dest" checkout --force "$ref"
    git -C "$dest" submodule update --init --recursive
}

# fetch_tarball <url> <dest>
# For pinned upstream tarball releases. Strips the top-level directory.
fetch_tarball() {
    local url=$1 dest=$2
    if [ -f "$dest/.eloqdb-fetched" ]; then
        eloqdb_log "already fetched: $dest"; return 0
    fi
    eloqdb_log "fetch (pinned): $url -> $dest"
    rm -rf "$dest"; mkdir -p "$dest"
    run_with_retry bash -c "curl -fsSL '$url' | tar -xzf - -C '$dest' --strip-components=1"
    touch "$dest/.eloqdb-fetched"
}

# cmake_install <srcdir> [extra cmake args...]
# Configure (out-of-tree under build/), build, and install into the shared prefix. No sudo.
cmake_install() {
    local src=$1; shift
    local name; name=$(basename "$src")
    local bld="$ELOQDB_BUILD/deps/$name"
    eloqdb_log "cmake build: $name"
    # shellcheck disable=SC2086
    cmake -S "$src" -B "$bld" $ELOQDB_CMAKE_ARGS "$@"
    cmake --build "$bld" -j "$ELOQDB_JOBS"
    cmake --install "$bld"
}

# Skip helper: returns 0 if the marker for <name> exists (dep already installed).
dep_done()      { [ -f "$ELOQDB_PREFIX/.eloqdb/$1.done" ]; }
dep_mark_done() { mkdir -p "$ELOQDB_PREFIX/.eloqdb"; touch "$ELOQDB_PREFIX/.eloqdb/$1.done"; }

# Ensure the ONE shared data_substrate checkout exists (latest of eloqdata/tx_service),
# then point a product's data_substrate submodule path at it via symlink. This gives every
# product the same data_substrate *version* without modifying its CMake (which builds it
# inline via add_subdirectory). <product_dir> <relpath-to-data_substrate>
link_shared_data_substrate() {
    local product_dir=$1 relpath=$2
    local shared="$ELOQDB_DATA_SUBSTRATE"
    clone_latest "$ELOQDB_DATA_SUBSTRATE_REPO" "$shared" "$ELOQDB_DATA_SUBSTRATE_BRANCH"
    local target="$product_dir/$relpath"
    if [ -L "$target" ]; then
        eloqdb_log "data_substrate already linked: $relpath"
    else
        eloqdb_log "linking shared data_substrate -> $relpath"
        rm -rf "$target"
        mkdir -p "$(dirname "$target")"
        ln -s "$shared" "$target"
    fi
}
