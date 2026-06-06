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
# eloq_ssh_url <url>
# Rewrite an Eloq-owned GitHub repo URL (eloqdata/ or ltzhang/) to SSH form so clone/pull/push use
# the user's SSH key (needed to reach the lintao-mod branches). Third-party repos are left as-is
# (https, read-only, no auth). No-op on URLs that are already SSH or not eloqdata/ltzhang.
eloq_ssh_url() {
    local url=$1
    case "$url" in
        https://github.com/eloqdata/*|https://github.com/ltzhang/*)
            url="git@github.com:${url#https://github.com/}" ;;
    esac
    printf '%s' "$url"
}

# For eloqdata repos: clone (or fast-forward) to the latest HEAD of the
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
# 4th arg (skip_submodules=1): clone the top-level repo ONLY — don't recurse/init submodules.
# Used for umbrella repos (e.g. eloquentdb) whose submodules we override with our own checkouts.
clone_latest() {
    local url=$1 dest=$2 branch=${3:-} skip_submodules=${4:-0}
    url="$(eloq_ssh_url "$url")"
    branch="$(eloq_pick_branch "$url" "$branch")"
    local recurse=(--recurse-submodules)
    [ "$skip_submodules" = 1 ] && recurse=()
    if [ -d "$dest/.git" ]; then
        eloqdb_log "update (latest): $dest"
        git -C "$dest" remote set-url origin "$url"   # migrate existing https origin -> SSH
        git -C "$dest" fetch "${recurse[@]}" origin
        if [ -n "$branch" ]; then git -C "$dest" checkout "$branch"; fi
        git -C "$dest" pull "${recurse[@]}" --ff-only
    else
        eloqdb_log "clone (latest): $url -> $dest"
        local args=(clone "${recurse[@]}")
        [ -n "$branch" ] && args+=(-b "$branch")
        run_with_retry git "${args[@]}" "$url" "$dest"
    fi
    [ "$skip_submodules" = 1 ] || git -C "$dest" submodule update --init --recursive
}

# clone_product <url> <dest> [branch]
# Clone/update a product top-level, then init its PROJECT-LOCAL submodules (e.g. eloqkv's
# crcspeed, eloqsql's vendored rocksdb/libmariadb) — but NOT data_substrate, the shared core,
# which every product consumes from dependencies/ via -DDATA_SUBSTRATE_DIR. This honors the
# no-stray-pulls rule: no recursive pull of the heavy core (and its eloqstore/abseil subtree)
# into the product tree.
clone_product() {
    local url=$1 dest=$2 branch=${3:-}
    url="$(eloq_ssh_url "$url")"
    branch="$(eloq_pick_branch "$url" "$branch")"
    if [ -d "$dest/.git" ]; then
        eloqdb_log "update product (latest): $dest"
        git -C "$dest" remote set-url origin "$url"   # migrate existing https origin -> SSH
        git -C "$dest" fetch origin
        [ -n "$branch" ] && git -C "$dest" checkout "$branch"
        git -C "$dest" pull --ff-only 2>/dev/null || true
    else
        eloqdb_log "clone product (latest, shallow): $url -> $dest"
        # Shallow: these products (MariaDB/MongoDB forks) are huge; depth-1 cuts transfer size and
        # survives flaky networks. We follow HEAD, so history isn't needed.
        local args=(clone --depth 1); [ -n "$branch" ] && args+=(-b "$branch")
        run_with_retry git "${args[@]}" "$url" "$dest"
    fi
    # Init every declared submodule EXCEPT data_substrate (recurse within the project-local ones).
    if [ -f "$dest/.gitmodules" ]; then
        local paths=() p
        while read -r p; do
            [ "$(basename "$p")" = "data_substrate" ] && continue
            paths+=("$p")
        done < <(git -C "$dest" config -f .gitmodules --get-regexp '\.path$' 2>/dev/null | awk '{print $2}')
        if [ ${#paths[@]} -gt 0 ]; then
            eloqdb_log "init project-local submodules (excluding data_substrate): ${paths[*]}"
            run_with_retry git -C "$dest" submodule update --init --recursive --depth 1 -- "${paths[@]}"
        fi
    fi
}

# eloq_link_path <link> <target> — idempotent symlink (replaces a stale dir/symlink at <link>).
# Generic form of the data_substrate linking used to point a repo's submodule path at one of our
# own shared/latest checkouts instead of the pinned submodule.
eloq_link_path() {
    local link=$1 target=$2
    [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ] && return 0
    rm -rf "$link"; mkdir -p "$(dirname "$link")"; ln -s "$target" "$link"
}

# clone_pinned <url> <dest> <ref>
# For third-party git deps: clone and check out an exact pinned tag/branch/commit. (Third-party
# stays https; eloq_ssh_url only rewrites eloqdata/ltzhang, so it's a no-op here unless a pinned
# eloqdata fork is ever added.)
clone_pinned() {
    local url=$1 dest=$2 ref=$3
    url="$(eloq_ssh_url "$url")"
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

# Ensure the ONE shared data_substrate checkout exists (latest of eloqdata/tx_service), cloned
# top-level only (no submodule recursion — substrate.sh places the sub-deps as real checkouts).
# Never re-fetch an existing checkout: it may be on a local lintao-mod with our build-script
# patches, and a pull could advance source past the already-built libraries.
eloq_ensure_data_substrate() {
    local shared="$ELOQDB_DATA_SUBSTRATE"
    if [ ! -d "$shared/.git" ]; then
        clone_latest "$ELOQDB_DATA_SUBSTRATE_REPO" "$shared" "$ELOQDB_DATA_SUBSTRATE_BRANCH" 1
    fi
}

# The dependency-directory contract (NO symlinks): every build that compiles data_substrate
# (the substrate layer and every product, which build it inline via add_subdirectory) passes
# these so the core finds each sub-dep at its single shared checkout under dependencies/ instead
# of an in-tree submodule path. Matches the overridable vars patched into the eloqdata CMake on
# their lintao-mod branches.
#   ELOQ_ABSEIL_DIR        -> the one abseil checkout (third_party)
#   ELOQ_TXLOG_PROTO_DIR   -> the one tx-log-protos checkout
#   ELOQSTORE_PARENT_DIR   -> parent of the one eloqstore checkout (eloqstore = $DIR/eloqstore)
#   DATA_SUBSTRATE_DIR     -> the shared data_substrate checkout (for products' add_subdirectory)
eloq_substrate_dir_flags() {
    printf '%s\n' \
        "-DELOQ_ABSEIL_DIR=$ELOQDB_THIRD_PARTY/abseil-cpp" \
        "-DELOQ_TXLOG_PROTO_DIR=$ELOQDB_DATA_SUBSTRATE/tx-log-protos" \
        "-DELOQSTORE_PARENT_DIR=$ELOQDB_DATA_SUBSTRATE" \
        "-DDATA_SUBSTRATE_DIR=$ELOQDB_DATA_SUBSTRATE"
}
