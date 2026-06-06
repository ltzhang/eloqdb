#!/usr/bin/env bash
# Layer 2 of the EloqDB build: the shared Eloq core (data_substrate).
#
# Layering:  deps (layer 1)  ->  data_substrate (layer 2)  ->  projects (layer 3)
# This layer depends on layer 1 (the shared deps in the prefix) and is depended on by the
# products. It is built ONCE, standalone, and shared by every product.
#
# data_substrate (eloqdata/tx_service) is a meta-repo. Its submodules are flattened to depth-2
# under dependencies/ (one checkout each, shared where duplicated) and symlinked into place.
#
# Usage:  scripts/substrate.sh
# Env:
#   ELOQDB_WITH_DATA_STORE   backend (default ELOQDSS_ELOQSTORE)
#   ELOQDB_ELOQ_MODULE       product identity baked in (e.g. ELOQ_MODULE_ELOQKV)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../env.sh"
source "$HERE/lib/common.sh"

DS_DATA_STORE="${ELOQDB_WITH_DATA_STORE:-ELOQDSS_ELOQSTORE}"
DS_MODULE="${ELOQDB_ELOQ_MODULE:-}"

# data_substrate's (recursive) submodules are FLATTENED to depth-2 under dependencies/ — each is
# cloned ONCE to a flat location and symlinked into the deep path the build expects. This keeps all
# checkouts shallow (no submodules buried under other repos) and de-duplicates shared ones (e.g.
# tx-log-protos, used by both tx_service and log_service, becomes a single checkout).
# Versioning: eloqdata/ltzhang -> latest; upstream third-party -> pinned.
ELOQSTORE_REPO="https://github.com/eloqdata/eloqstore.git"
ELOQSTORE_BRANCH=""   # empty => remote default (unless ELOQDB_MOD_BRANCH exists)
PIN_ABSEIL_REF="69195d5bd2416a7224416887c78353ee8edf67ee"   # must match deps.sh (the shared abseil)
PIN_CONCURRENTQUEUE="c68072129c8a5b4025122ca5a0c82ab14b30cb03"
PIN_INIH="8e06f6b77b5d4471bdc6d85ada81b67d37354a5c"

# Sanity: layer 2 needs layer 1. Spot-check a couple of representative deps.
check_deps_layer() {
    local missing=()
    [ -e "$ELOQDB_PREFIX/include/mimalloc.h" ] || [ -e "$ELOQDB_PREFIX/include/mimalloc-2.1/mimalloc.h" ] || missing+=(mimalloc)
    [ -n "$(ls "$ELOQDB_PREFIX"/lib/libbrpc* 2>/dev/null)" ] || missing+=(brpc)
    [ -n "$(ls "$ELOQDB_PREFIX"/lib/librocksdb* 2>/dev/null)" ] || missing+=(rocksdb)
    # eloqstore (EloqStore backend) hard-requires the AWS S3 SDK.
    case "$DS_DATA_STORE" in
        *ELOQSTORE*|*DYNAMODB*|*S3*)
            [ -n "$(ls "$ELOQDB_PREFIX"/lib/libaws-cpp-sdk-s3* 2>/dev/null)" ] || missing+=("aws-sdk(s3)") ;;
    esac
    if [ ${#missing[@]} -gt 0 ]; then
        eloqdb_die "deps layer incomplete (missing: ${missing[*]}). Run: scripts/build.sh --deps-only"
    fi
}

# --- flat-checkout + symlink helpers (no recursion: each repo's own submodules are flattened too) ---
# Remove a stale path at <dest> (a symlink, or a non-git directory) so a fresh clone can land there.
_clear_stale() { local d=$1; { [ -L "$d" ] || { [ -e "$d" ] && [ ! -d "$d/.git" ]; }; } && rm -rf "$d"; return 0; }
_flat_latest() {  # url dest [branch]   eloqdata -> latest (prefers ELOQDB_MOD_BRANCH if present)
    local url=$1 dest=$2 branch=${3:-}
    branch="$(eloq_pick_branch "$url" "$branch")"
    _clear_stale "$dest"
    if [ -d "$dest/.git" ]; then
        git -C "$dest" fetch origin
        [ -n "$branch" ] && git -C "$dest" checkout "$branch" 2>/dev/null || true
        git -C "$dest" pull --ff-only 2>/dev/null || true
    else
        local args=(clone); [ -n "$branch" ] && args+=(-b "$branch")
        run_with_retry git "${args[@]}" "$url" "$dest"
    fi
}
_flat_pinned() {  # url dest ref        upstream third-party -> pinned
    local url=$1 dest=$2 ref=$3
    _clear_stale "$dest"
    [ -d "$dest/.git" ] || run_with_retry git clone "$url" "$dest"
    git -C "$dest" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || git -C "$dest" fetch origin --tags
    git -C "$dest" checkout --force "$ref"
}
_link() {  # deep-path  flat-checkout   (idempotent symlink)
    local deep=$1 flat=$2
    [ -L "$deep" ] && [ "$(readlink "$deep")" = "$flat" ] && return 0
    rm -rf "$deep"; mkdir -p "$(dirname "$deep")"; ln -s "$flat" "$deep"
}

# Clone data_substrate top-level only (submodules are flattened separately, not inited here).
clone_data_substrate() {
    local ds="$ELOQDB_DATA_SUBSTRATE"
    if [ -d "$ds/.git" ] && ! git -C "$ds" remote get-url origin 2>/dev/null | grep -q "$ELOQDB_DATA_SUBSTRATE_REPO"; then
        eloqdb_warn "data_substrate origin differs from $ELOQDB_DATA_SUBSTRATE_REPO — re-cloning"
        rm -rf "$ds"
    fi
    _flat_latest "$ELOQDB_DATA_SUBSTRATE_REPO" "$ds" "$ELOQDB_DATA_SUBSTRATE_BRANCH"
    # We manage submodules as flat checkouts + symlinks, NOT via git. Drop git's submodule object
    # stores so they don't accumulate duplicate copies (e.g. tx-log-protos under both tx_service
    # and log_service). The build reads the symlinked working tree, not .git/modules.
    rm -rf "$ds/.git/modules"
}

# Flatten every (recursive) data_substrate submodule to depth-2, categorized by origin:
#   third_party/     = upstream used as-is (abseil, concurrentqueue, inih)
#   sub_modules/     = eloqdata forks of upstream (brpc, braft, ... — handled in deps.sh)
#   data_substrate/  = original Eloq projects (log_service, tx-log-protos, eloqstore)
# Each is one checkout, symlinked into the deep path the build expects; shared ones (tx-log-protos)
# get a single checkout.
flatten_submodules() {
    local ds="$ELOQDB_DATA_SUBSTRATE" sm="$ELOQDB_SUBMODULES" tp="$ELOQDB_THIRD_PARTY"
    eloqdb_log "flattening data_substrate submodules to depth-2 (Eloq-original under data_substrate/)"
    rm -rf "$sm/tx-log-protos" "$sm/log_service" "$sm/eloqstore"   # clean old (mis-categorized) locations
    # upstream third-party (used as-is) -> third_party/  (pinned)
    _flat_pinned https://github.com/abseil/abseil-cpp.git          "$tp/abseil-cpp"      "$PIN_ABSEIL_REF"
    _flat_pinned https://github.com/cameron314/concurrentqueue.git "$tp/concurrentqueue" "$PIN_CONCURRENTQUEUE"
    _flat_pinned https://github.com/benhoyt/inih.git               "$tp/inih"            "$PIN_INIH"
    # original Eloq projects -> data_substrate/  (latest; prefers ELOQDB_MOD_BRANCH)
    _flat_latest https://github.com/eloqdata/tx-log-protos.git     "$ds/tx-log-protos"
    _flat_latest https://github.com/eloqdata/log_service.git       "$ds/log_service"
    _flat_latest "$ELOQSTORE_REPO"                                 "$ds/eloqstore" "$ELOQSTORE_BRANCH"
    # symlink flat checkouts into the deep paths the build expects
    _link "$ds/tx_service/abseil-cpp"                           "$tp/abseil-cpp"
    _link "$ds/tx_service/tx-log-protos"                        "$ds/tx-log-protos"
    _link "$ds/store_handler/eloq_data_store_service/eloqstore" "$ds/eloqstore"
    _link "$ds/log_service/tx-log-protos"                       "$ds/tx-log-protos"   # de-dup: one tx-log-protos
    _link "$ds/eloqstore/external/concurrentqueue"              "$tp/concurrentqueue"
    _link "$ds/eloqstore/external/inih"                         "$tp/inih"
    # log_service is a real checkout at its natural path ($ds/log_service) — no symlink needed.
    # eloqstore/external/abseil intentionally NOT created — eloqstore links tx_service's abseil.
}

build_data_substrate() {
    if dep_done data_substrate; then eloqdb_log "data_substrate already built"; return 0; fi
    clone_data_substrate
    flatten_submodules
    local bld="$ELOQDB_BUILD/substrate/data_substrate"
    # One shared lib bakes in ONE product identity (metrics/branches gated on ELOQ_MODULE_*).
    local module_def=""
    [ -n "$DS_MODULE" ] && module_def="-DCMAKE_CXX_FLAGS=-D${DS_MODULE}"
    eloqdb_log "building data_substrate (data_store=$DS_DATA_STORE, module=${DS_MODULE:-none})"
    # -DGIT_SUBMODULE=OFF stops eloqstore's CMake from force re-initing external/abseil.
    cmake -S "$ELOQDB_DATA_SUBSTRATE" -B "$bld" \
        -DCMAKE_PREFIX_PATH="$ELOQDB_PREFIX" -DCMAKE_INSTALL_PREFIX="$ELOQDB_PREFIX" \
        -DCMAKE_BUILD_TYPE=RelWithDebInfo -DGIT_SUBMODULE=OFF \
        -DWITH_DATA_STORE="$DS_DATA_STORE" $module_def
    cmake --build "$bld" -j "$ELOQDB_JOBS"
    cmake --install "$bld"
    dep_mark_done data_substrate
    eloqdb_log "data_substrate layer complete."
}

check_deps_layer
build_data_substrate
