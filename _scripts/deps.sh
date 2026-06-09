#!/usr/bin/env bash
# Layer 1 of the eloq_build_env build: third-party + eloqdata-fork dependencies.
# Internal script — invoked automatically by build.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Guard: this is an internal layer script. Direct invocation is unsupported.
if [ -z "${ELOQDB_ORCHESTRATED:-}" ]; then
    cat <<'EOF'

================================================================
  eloq_build_env
  https://github.com/ltzhang/eloq_build_env
================================================================

  deps.sh is an internal build layer — use build.sh instead:

    build.sh [--deps-only] [--fetch-only] [OPTIONS]
    build.sh --help

  Advanced: to bypass this check (e.g. for debugging):
    ELOQDB_ORCHESTRATED=1 _scripts/deps.sh [OPTIONS]

================================================================

EOF
    exit 1
fi

_usage() {
    cat <<'EOF'
Usage: scripts/deps.sh [OPTIONS]   (internal — prefer build.sh)

  --with-cloud          Build full cloud stack (aws-sdk-cpp, google-cloud-cpp, rocksdb-cloud)
  --with-tests          Also build test deps (Catch2, FakeIt)
  --fetch-only          Clone/download sources only; skip compilation
  --help                Show this help
EOF
}

source "$HERE/../env.sh"
source "$HERE/common.sh"

WITH_AWS=0; WITH_GCP=0; WITH_ROCKSDB_CLOUD=0; WITH_TESTS=0
FETCH_ONLY="${ELOQDB_FETCH_ONLY:-0}"   # inherited from build.sh or set via --fetch-only
for a in "$@"; do
    case "$a" in
        --with-aws)           WITH_AWS=1 ;;
        --with-gcp)           WITH_GCP=1 ;;
        --with-rocksdb-cloud) WITH_ROCKSDB_CLOUD=1; WITH_AWS=1; WITH_GCP=1 ;;  # builds aws+gcp variants
        --with-cloud)         WITH_AWS=1; WITH_GCP=1; WITH_ROCKSDB_CLOUD=1 ;;   # shorthand: all cloud deps
        --with-tests)         WITH_TESTS=1 ;;
        --fetch-only)         FETCH_ONLY=1 ;;
        --help|-h)            _usage; exit 0 ;;
        *) eloqdb_die "unknown arg: $a (try --help)" ;;
    esac
done

# ---- pinned third-party versions -------------------------------------------
PIN_LUA="https://www.lua.org/ftp/lua-5.4.6.tar.gz"
PIN_PROTOBUF="https://github.com/protocolbuffers/protobuf/archive/refs/tags/v21.12.tar.gz"
# Abseil is pinned to the EXACT commit that data_substrate (tx_service) vendors, so the prefix
# headers are identical to the vendored ones. Required because data_substrate's CMake -I's the
# prefix (install/include) BEFORE its own vendored abseil, so a header mismatch (e.g. the cordz
# SamplingState change absent from the 20230802.0 release tag) breaks the vendored abseil build.
# Same lts_20230802 inline namespace => ABI-compatible with protobuf/grpc/brpc (no rebuild needed).
# NOTE: if data_substrate bumps its vendored abseil, update this commit to match.
PIN_ABSEIL_REF="69195d5bd2416a7224416887c78353ee8edf67ee"
PIN_RE2="https://github.com/google/re2/archive/2023-08-01.tar.gz"
PIN_CRC32C="https://github.com/google/crc32c/archive/1.1.2.tar.gz"
PIN_GRPC="https://codeload.github.com/grpc/grpc/tar.gz/refs/tags/v1.51.1"
PIN_JSON="https://github.com/nlohmann/json/archive/v3.11.2.tar.gz"
PIN_ROCKSDB_TAG="v9.1.0"
PIN_PROMETHEUS_TAG="v1.1.0"
PIN_CATCH2_TAG="v3.3.2"
PIN_LIBURING_TAG="liburing-2.6"
PIN_AWS_TAG="1.11.446"
PIN_GOOGLE_CLOUD="https://codeload.github.com/googleapis/google-cloud-cpp/tar.gz/refs/tags/v2.24.0"
PIN_FAKEIT_TAG="2.4.0"   # third-party: pinned (legacy floated on HEAD)

TP="$ELOQDB_THIRD_PARTY"
SM="$ELOQDB_SUBMODULES"

# Build then copy a brpc/braft-style ./output tree into the prefix (no install target).
copy_output_tree() {
    local bld=$1
    cp -rf "$bld/output/include/." "$ELOQDB_PREFIX/include/"
    cp -rf "$bld/output/lib/."     "$ELOQDB_PREFIX/lib/"
}

# ===== Tier 0: leaf deps =====================================================
build_abseil() { dep_done abseil && return 0
    clone_pinned https://github.com/abseil/abseil-cpp.git "$TP/abseil-cpp" "$PIN_ABSEIL_REF"
    [ "${FETCH_ONLY:-0}" = 1 ] && return 0
    # Do NOT patch ABSL_OPTION_USE_STD_* to 0 (the legacy install_dependency did this, forcing
    # absl::string_view/optional/variant/any). data_substrate's vendored abseil keeps the default
    # =2 (std types), and tx_service uses std::string_view heterogeneous lookup — so the prefix
    # abseil MUST match (=2). With absl types as distinct mangled symbols, all abseil consumers
    # (protobuf/grpc/brpc/braft) must build against the SAME option set, hence the unpatched default.
    cmake_install "$TP/abseil-cpp" -DABSL_BUILD_TESTING=OFF -DABSL_PROPAGATE_CXX_STD=ON
    dep_mark_done abseil; }

build_lua() { dep_done lua && return 0
    fetch_tarball "$PIN_LUA" "$TP/lua"
    [ "${FETCH_ONLY:-0}" = 1 ] && return 0
    make -C "$TP/lua" all -j "$ELOQDB_JOBS"
    make -C "$TP/lua" install INSTALL_TOP="$ELOQDB_PREFIX"
    dep_mark_done lua; }

build_liburing() { dep_done liburing && return 0
    clone_pinned https://github.com/axboe/liburing.git "$TP/liburing" "$PIN_LIBURING_TAG"
    [ "${FETCH_ONLY:-0}" = 1 ] && return 0
    ( cd "$TP/liburing" && ./configure --prefix="$ELOQDB_PREFIX" --cc=gcc --cxx=g++ \
        && make -j "$ELOQDB_JOBS" && make install )
    dep_mark_done liburing; }

build_json() { dep_done json && return 0
    fetch_tarball "$PIN_JSON" "$TP/json"
    [ "${FETCH_ONLY:-0}" = 1 ] && return 0
    cmake_install "$TP/json" -DJSON_BuildTests=OFF -DBUILD_TESTING=OFF
    dep_mark_done json; }

build_crc32c() { dep_done crc32c && return 0
    fetch_tarball "$PIN_CRC32C" "$TP/crc32c"
    [ "${FETCH_ONLY:-0}" = 1 ] && return 0
    cmake_install "$TP/crc32c" -DCRC32C_BUILD_TESTS=OFF -DCRC32C_BUILD_BENCHMARKS=OFF -DCRC32C_USE_GLOG=OFF
    dep_mark_done crc32c; }

build_re2() { dep_done re2 && return 0
    fetch_tarball "$PIN_RE2" "$TP/re2"
    [ "${FETCH_ONLY:-0}" = 1 ] && return 0
    cmake_install "$TP/re2" -DRE2_BUILD_TESTING=OFF
    dep_mark_done re2; }

build_glog() { dep_done glog && return 0
    clone_latest https://github.com/eloqdata/glog.git "$SM/glog"
    [ "${FETCH_ONLY:-0}" = 1 ] && return 0
    cmake_install "$SM/glog"
    dep_mark_done glog; }

build_mimalloc() { dep_done mimalloc && return 0
    clone_latest https://github.com/eloqdata/mimalloc.git "$SM/mimalloc"
    [ "${FETCH_ONLY:-0}" = 1 ] && return 0
    cmake_install "$SM/mimalloc"
    dep_mark_done mimalloc; }

build_cuckoofilter() { dep_done cuckoofilter && return 0
    clone_latest https://github.com/eloqdata/cuckoofilter.git "$SM/cuckoofilter"
    [ "${FETCH_ONLY:-0}" = 1 ] && return 0
    make -C "$SM/cuckoofilter" install PREFIX="$ELOQDB_PREFIX"
    dep_mark_done cuckoofilter; }

build_rocksdb() { dep_done rocksdb && return 0
    clone_pinned https://github.com/facebook/rocksdb.git "$TP/rocksdb" "$PIN_ROCKSDB_TAG"
    [ "${FETCH_ONLY:-0}" = 1 ] && return 0
    # v9.1.0 install honors PREFIX (LIBDIR=$PREFIX/lib, DESTDIR empty); INSTALL_PATH is ignored.
    ( cd "$TP/rocksdb" && USE_RTTI=1 PORTABLE=1 ROCKSDB_DISABLE_TCMALLOC=1 ROCKSDB_DISABLE_JEMALLOC=1 \
        make -j "$ELOQDB_JOBS" shared_lib \
        && make install-shared PREFIX="$ELOQDB_PREFIX" DESTDIR= )
    dep_mark_done rocksdb; }

# ===== Tier 1: needs abseil =================================================
build_protobuf() { dep_done protobuf && return 0
    fetch_tarball "$PIN_PROTOBUF" "$TP/protobuf"
    [ "${FETCH_ONLY:-0}" = 1 ] && return 0
    cmake_install "$TP/protobuf" -Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_ABSL_PROVIDER=package
    dep_mark_done protobuf; }

# ===== Tier 2: needs protobuf/abseil/glog ===================================
build_grpc() { dep_done grpc && return 0
    fetch_tarball "$PIN_GRPC" "$TP/grpc"
    [ "${FETCH_ONLY:-0}" = 1 ] && return 0
    cmake_install "$TP/grpc" -DgRPC_INSTALL=ON -DgRPC_BUILD_TESTS=OFF \
        -DgRPC_ABSL_PROVIDER=package -DgRPC_CARES_PROVIDER=package \
        -DgRPC_PROTOBUF_PROVIDER=package -DgRPC_RE2_PROVIDER=package \
        -DgRPC_SSL_PROVIDER=package -DgRPC_ZLIB_PROVIDER=package
    dep_mark_done grpc; }

build_brpc() { dep_done brpc && return 0
    clone_latest https://github.com/eloqdata/brpc.git "$SM/brpc"
    [ "${FETCH_ONLY:-0}" = 1 ] && return 0
    local bld="$ELOQDB_BUILD/deps/brpc"
    cmake -S "$SM/brpc" -B "$bld" -DWITH_GLOG=ON -DIO_URING_ENABLED=ON -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_PREFIX_PATH="$ELOQDB_PREFIX"
    cmake --build "$bld" -j "$ELOQDB_JOBS"
    copy_output_tree "$bld"
    dep_mark_done brpc; }

build_prometheus() { dep_done prometheus && return 0
    clone_pinned https://github.com/jupp0r/prometheus-cpp.git "$TP/prometheus-cpp" "$PIN_PROMETHEUS_TAG"
    [ "${FETCH_ONLY:-0}" = 1 ] && return 0
    cmake_install "$TP/prometheus-cpp" -DENABLE_PUSH=OFF -DENABLE_TESTING=OFF
    dep_mark_done prometheus; }

# ===== Tier 3: needs brpc ===================================================
build_braft() { dep_done braft && return 0
    clone_latest https://github.com/eloqdata/braft.git "$SM/braft"
    [ "${FETCH_ONLY:-0}" = 1 ] && return 0
    sed -i 's/libbrpc.a//g' "$SM/braft/CMakeLists.txt"
    local bld="$ELOQDB_BUILD/deps/braft"
    cmake -S "$SM/braft" -B "$bld" -DBRPC_WITH_GLOG=ON -DCMAKE_PREFIX_PATH="$ELOQDB_PREFIX"
    cmake --build "$bld" -j "$ELOQDB_JOBS"
    copy_output_tree "$bld"
    dep_mark_done braft; }

# ===== Tier: tests (optional) ===============================================
build_catch2() { dep_done catch2 && return 0
    clone_pinned https://github.com/catchorg/Catch2.git "$TP/Catch2" "$PIN_CATCH2_TAG"
    [ "${FETCH_ONLY:-0}" = 1 ] && return 0
    cmake_install "$TP/Catch2" -DCATCH_BUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF
    dep_mark_done catch2; }

build_fakeit() { dep_done fakeit && return 0
    clone_pinned https://github.com/eranpeer/FakeIt.git "$TP/FakeIt" "$PIN_FAKEIT_TAG"
    [ "${FETCH_ONLY:-0}" = 1 ] && return 0
    mkdir -p "$ELOQDB_PREFIX/include/catch2"
    cp "$TP/FakeIt/single_header/catch/fakeit.hpp" "$ELOQDB_PREFIX/include/catch2/fakeit.hpp"
    dep_mark_done fakeit; }

# ===== Tier 4: optional cloud stack =========================================
build_aws() { dep_done aws && return 0
    clone_pinned https://github.com/aws/aws-sdk-cpp.git "$TP/aws" "$PIN_AWS_TAG"
    [ "${FETCH_ONLY:-0}" = 1 ] && return 0
    # eloqstore needs only s3; DynamoDB/cloud backends widen this via ELOQDB_AWS_COMPONENTS.
    local comps="${ELOQDB_AWS_COMPONENTS:-s3}"
    eloqdb_log "building aws-sdk-cpp (components: $comps)"
    cmake_install "$TP/aws" -DENABLE_TESTING=OFF -DFORCE_SHARED_CRT=OFF \
        -DBUILD_ONLY="$comps"
    dep_mark_done aws; }

build_google_cloud() { dep_done google_cloud && return 0
    fetch_tarball "$PIN_GOOGLE_CLOUD" "$TP/google-cloud-cpp"
    [ "${FETCH_ONLY:-0}" = 1 ] && return 0
    cmake_install "$TP/google-cloud-cpp" -DBUILD_TESTING=OFF \
        -DGOOGLE_CLOUD_CPP_ENABLE_EXAMPLES=OFF -DGOOGLE_CLOUD_CPP_ENABLE="bigtable;storage"
    dep_mark_done google_cloud; }

build_rocksdb_cloud() { dep_done rocksdb_cloud && return 0
    clone_latest https://github.com/eloqdata/rocksdb-cloud.git "$SM/rocksdb-cloud"
    [ "${FETCH_ONLY:-0}" = 1 ] && return 0
    ( cd "$SM/rocksdb-cloud"
      LIBNAME=librocksdb-cloud-aws USE_RTTI=1 USE_AWS=1 ROCKSDB_DISABLE_TCMALLOC=1 ROCKSDB_DISABLE_JEMALLOC=1 \
        make shared_lib -j "$ELOQDB_JOBS"
      LIBNAME=librocksdb-cloud-aws PREFIX="$ELOQDB_PREFIX" make install-shared )
    dep_mark_done rocksdb_cloud; }

# ===== Driver ===============================================================
main() {
    eloqdb_log "Building shared deps into $ELOQDB_PREFIX (jobs=$ELOQDB_JOBS, aws=$WITH_AWS, gcp=$WITH_GCP, rocksdb-cloud=$WITH_ROCKSDB_CLOUD, tests=$WITH_TESTS)"
    # Tier 0 (independent)
    build_abseil; build_lua; build_liburing; build_json
    build_glog; build_mimalloc; build_cuckoofilter; build_rocksdb
    # Tier 1
    build_protobuf
    # Tier 2
    build_brpc; build_prometheus
    # Tier 3
    build_braft
    # Optional tests
    if [ "$WITH_TESTS" = 1 ]; then build_catch2; build_fakeit; fi
    # Cloud deps, granular. NOTE: AWS S3 is REQUIRED by eloqstore (the default EloqStore
    # backend), so --with-aws is on for ELOQSTORE — not just cloud backends. GCP and
    # rocksdb-cloud remain truly optional (only their specific backends need them).
    if [ "$WITH_AWS" = 1 ];           then build_aws; fi
    if [ "$WITH_GCP" = 1 ]; then
        # grpc + re2 + crc32c are the google-cloud-cpp stack — nothing else in the build links
        # them. grpc v1.51.1 also won't compile against abseil 20230802 (USE_*=2), so keep it
        # scoped to GCP builds only.
        build_crc32c; build_re2; build_grpc; build_google_cloud
    fi
    if [ "$WITH_ROCKSDB_CLOUD" = 1 ]; then build_rocksdb_cloud; fi
    eloqdb_log "Deps layer complete. Next layer: scripts/substrate.sh"
}

main
