#!/usr/bin/env bash
# EloqDB umbrella build orchestrator — a 3-layer build:
#
#   layer 1: deps           (third-party + eloqdata forks)   scripts/deps.sh
#   layer 2: data_substrate (the shared Eloq core)           scripts/substrate.sh
#   layer 3: projects        (eloqkv / eloqsql / eloqdoc)     scripts/projects/*.sh
#
# Each layer depends on the one below it. Invoke a single layer or the whole stack:
#
#   ./scripts/build.sh                  # all layers: deps -> substrate -> projects
#   ./scripts/build.sh --deps-only      # layer 1 only
#   ./scripts/build.sh --data-substrate # layer 2 only (requires layer 1 already built)
#   ./scripts/build.sh --product eloqkv # all layers, projects scoped to eloqkv
#   ./scripts/build.sh --with-tests     # (layer 1) also build test deps
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$ROOT/env.sh"
source "$HERE/lib/common.sh"

MANIFEST="$ROOT/manifest.toml"
[ -f "$MANIFEST" ] || eloqdb_die "manifest not found: $MANIFEST"

LAYER="all"; ONLY_PRODUCT=""; WITH_TESTS=0
while [ $# -gt 0 ]; do
    case "$1" in
        --deps-only)      LAYER="deps" ;;
        --data-substrate) LAYER="substrate" ;;
        --product)        ONLY_PRODUCT="${2:-}"; shift ;;
        --with-tests)     WITH_TESTS=1 ;;
        *) eloqdb_die "unknown arg: $1" ;;
    esac
    shift
done

# --- tiny TOML reader: value of <key> within section [<section>] -------------
toml_get() {
    local section=$1 key=$2
    awk -v sec="[$section]" -v k="$key" '
        $0==sec {ins=1; next}
        /^\[/   {ins=0}
        ins && $1==k {
            line=$0
            sub(/^[^=]*=[ \t]*/,"",line)
            if (line ~ /^"/)      { sub(/^"/,"",line); sub(/".*$/,"",line) }
            else if (line ~ /^'"'"'/) { sub(/^'"'"'/,"",line); sub(/'"'"'.*$/,"",line) }
            else                  { sub(/[ \t]*#.*$/,"",line); sub(/[ \t]+$/,"",line) }
            print line; exit
        }' "$MANIFEST"
}
list_products() { grep -oE '^\[products\.[a-zA-Z0-9_-]+\]' "$MANIFEST" | sed -E 's/^\[products\.(.*)\]/\1/'; }

DEF_DS="$(toml_get defaults with_data_store)"; DEF_DS="${DEF_DS:-ELOQDSS_ELOQSTORE}"
DEF_LS="$(toml_get defaults with_log_state)"; DEF_LS="${DEF_LS:-ROCKSDB}"

# --- determine enabled products ---------------------------------------------
ENABLED=()
for p in $(list_products); do
    if [ -n "$ONLY_PRODUCT" ]; then
        [ "$p" = "$ONLY_PRODUCT" ] && ENABLED+=("$p")
    else
        [ "$(toml_get "products.$p" enabled)" = "true" ] && ENABLED+=("$p")
    fi
done
[ "$LAYER" = "all" ] && [ ${#ENABLED[@]} -eq 0 ] && eloqdb_die "no enabled products in manifest (or --product not found)"
eloqdb_log "enabled products: ${ENABLED[*]:-<none>}  (layer: $LAYER)"

# --- backend/module derived from the first enabled product (for the substrate layer) ---
DEPS_DS="$DEF_DS"; DEPS_MODULE=""
if [ ${#ENABLED[@]} -gt 0 ]; then
    _p0="${ENABLED[0]}"; _ds0="$(toml_get "products.$_p0" with_data_store)"
    DEPS_DS="${_ds0:-$DEF_DS}"
    case "$_p0" in
        eloqkv)  DEPS_MODULE="ELOQ_MODULE_ELOQKV" ;;
        eloqsql) DEPS_MODULE="ELOQ_MODULE_ELOQSQL" ;;
        eloqdoc) DEPS_MODULE="ELOQ_MODULE_ELOQDOC" ;;
    esac
    [ ${#ENABLED[@]} -gt 1 ] && eloqdb_warn "multiple products enabled; shared data_substrate baked with $_p0's module ($DEPS_MODULE) — others get its metric labels"
fi

# --- which cloud deps do the enabled products need? (granular) --------------
# AWS S3 is required by eloqstore (ELOQSTORE backend) AND DynamoDB/S3 backends.
# GCP only for Bigtable/GCS. rocksdb-cloud only for cloud-rocksdb backends.
CLOUD_FLAGS=()
_need_aws=0; _need_gcp=0; _need_rc=0
for p in "${ENABLED[@]}"; do
    ds="$(toml_get "products.$p" with_data_store)"; ds="${ds:-$DEF_DS}"
    ls="$(toml_get "products.$p" with_log_state)"; ls="${ls:-$DEF_LS}"
    case "$ds$ls" in *ELOQSTORE*|*DYNAMODB*|*S3*) _need_aws=1 ;; esac
    case "$ds$ls" in *BIGTABLE*|*GCS*) _need_gcp=1 ;; esac
    case "$ds$ls" in *ROCKSDB_CLOUD*) _need_rc=1 ;; esac
done
[ "$_need_aws" = 1 ] && CLOUD_FLAGS+=(--with-aws)
[ "$_need_gcp" = 1 ] && CLOUD_FLAGS+=(--with-gcp)
[ "$_need_rc"  = 1 ] && CLOUD_FLAGS+=(--with-rocksdb-cloud)
TEST_FLAG=""; [ "$WITH_TESTS" = 1 ] && TEST_FLAG="--with-tests"

# AWS components: eloqstore needs s3; widen for DynamoDB.
AWS_COMPONENTS="s3"
for p in "${ENABLED[@]}"; do
    ds="$(toml_get "products.$p" with_data_store)"; ds="${ds:-$DEF_DS}"
    case "$ds" in *DYNAMODB*) AWS_COMPONENTS="dynamodb;s3;kinesis" ;; esac
done
export ELOQDB_AWS_COMPONENTS="$AWS_COMPONENTS"

# ===== layer functions ======================================================
layer_deps() {
    eloqdb_log "=== LAYER 1: deps ${CLOUD_FLAGS[*]:+(${CLOUD_FLAGS[*]})} ==="
    bash "$HERE/deps.sh" "${CLOUD_FLAGS[@]}" $TEST_FLAG
}
layer_substrate() {
    eloqdb_log "=== LAYER 2: data_substrate (backend=$DEPS_DS, module=${DEPS_MODULE:-none}) ==="
    ELOQDB_WITH_DATA_STORE="$DEPS_DS" ELOQDB_ELOQ_MODULE="$DEPS_MODULE" bash "$HERE/substrate.sh"
}
layer_projects() {
    [ ${#ENABLED[@]} -eq 0 ] && eloqdb_die "no enabled products to build"
    for p in "${ENABLED[@]}"; do
        local repo branch adapter ds ls
        repo="$(toml_get "products.$p" repo)"; branch="$(toml_get "products.$p" branch)"
        adapter="$(toml_get "products.$p" adapter)"
        [ -n "$repo" ] || eloqdb_die "no repo for product $p"
        clone_latest "$repo" "$ELOQDB_PROJECTS/$p" "$branch"
        ds="$(toml_get "products.$p" with_data_store)"; export ELOQDB_WITH_DATA_STORE="${ds:-$DEF_DS}"
        ls="$(toml_get "products.$p" with_log_state)"; export ELOQDB_WITH_LOG_STATE="${ls:-$DEF_LS}"
        eloqdb_log "=== LAYER 3: product $p ==="
        bash "$ROOT/$adapter"
    done
}

# ===== dispatch =============================================================
case "$LAYER" in
    deps)      layer_deps ;;
    substrate) layer_substrate ;;
    all)       layer_deps; layer_substrate; layer_projects ;;
esac
eloqdb_log "Done (layer: $LAYER). Artifacts under $ELOQDB_BUILD and $ELOQDB_PREFIX."
