# EloqDB Build Plan

The concrete inventory behind `CLAUDE.md`: what to build, which version, from where, and in what
order. Strategy and the target architecture (one checkout per dep under `dependencies/`, **no
directory symlinks, no submodule recursion, no stray pulls**) live in `CLAUDE.md`.

## System prerequisites (assumed present, NOT built — see README)

Toolchain: `gcc/g++`, `make`, `cmake`, `ninja-build`, `pkg-config`, `m4`, `git`, `patchelf`,
`ccache`, `bison`.
System libs: `libssl-dev`, `zlib1g-dev`, `libgflags-dev`, `libleveldb-dev`, `libsnappy-dev`,
`liblz4-dev`, `libzstd-dev`, `libbz2-dev`, `libcurl4-openssl-dev`, `libc-ares-dev`, `libuv1-dev`,
`libboost-context-dev`, `libreadline-dev`, `libncurses5-dev`. (JDK/redis/tcl only for test suites.)

## Dependency matrix

**Version policy by owner:**
- **`eloqdata/` repos → latest** (default-branch HEAD, preferring `lintao-mod`), ignoring any
  pinned commit/tag. ("Version" shows `latest`.) The `ltzhang/eloqdb` umbrella follows the same rule.
- **All other third-party repos → pinned** to the version shown, so upstream releases can't break
  the build.

Each dependency is a **single checkout** in the bucket shown under `dependencies/`, built once into
`install/`, and consumed directly from there (CMake `find_package` / `CMAKE_PREFIX_PATH`) — **no
symlinks, no submodule recursion**.

| Dependency       | Version        | Source / bucket            | Tier            | Notes |
|------------------|----------------|----------------------------|-----------------|-------|
| abseil-cpp       | commit 69195d5 | upstream / third_party     | shared          | **pinned to the commit data_substrate vendors**; keep `options.h` USE_*=2 (std types — tx_service needs `std::string_view`). The core `-I`s the prefix before its own copy, so they must be byte-identical |
| protobuf         | v21.12         | upstream / third_party     | shared          | needs abseil (`ABSL_PROVIDER=package`), USE_*=2 |
| re2              | 2023-08-01     | upstream / third_party     | **GCP-only**    | grpc dep — gated behind `--with-gcp` |
| crc32c           | 1.1.2          | upstream / third_party     | **GCP-only**    | grpc dep — gated behind `--with-gcp` |
| grpc             | v1.51.1        | upstream / third_party     | **GCP-only**    | only google-cloud-cpp links it; won't compile against abseil 20230802 (USE_*=2) — gated behind `--with-gcp` |
| liburing         | 2.6            | axboe / third_party        | shared          | `./configure` |
| lua              | 5.4.6          | lua.org / third_party      | shared          | `make` |
| json (nlohmann)  | 3.11.2         | upstream / third_party     | shared          | header-only |
| concurrentqueue  | c680721 (pin)  | cameron314 / third_party   | shared          | used by eloqstore |
| inih             | 8e06f6b (pin)  | benhoyt / third_party      | shared          | used by eloqstore |
| glog             | **latest**     | **eloqdata** / sub_modules | shared          | latest default branch |
| brpc             | **latest**     | **eloqdata** / sub_modules | shared          | needs glog, protobuf, leveldb, ssl, gflags; io_uring ON |
| braft            | **latest**     | **eloqdata** / sub_modules | shared          | needs brpc; strip `libbrpc.a` from CMakeLists |
| mimalloc         | **latest**     | **eloqdata** / sub_modules | shared          | ignore `eloq-v2.1.2` pin |
| cuckoofilter     | **latest**     | **eloqdata** / sub_modules | shared          | `make install` — needs PREFIX patch |
| rocksdb          | v9.1.0 (pin)   | facebook / third_party     | shared          | `make shared_lib`; RTTI=1, no tcmalloc/jemalloc |
| prometheus-cpp   | v1.1.0 (pin)   | jupp0r / third_party       | shared          | metrics |
| Catch2           | v3.3.2 (pin)   | upstream / third_party     | shared (test)   | only if tests enabled |
| FakeIt           | pin TBD        | upstream / third_party     | shared (test)   | floats on HEAD → pick a commit to pin; header copy needs prefix patch |
| aws-sdk-cpp      | 1.11.446       | upstream / third_party     | optional/cloud  | eloqstore's S3/GCS cloud-storage backend is compile-time gated behind `WITH_CLOUD_STORAGE` (lintao-mod, upstream default ON); the umbrella drives it from `ELOQDB_WITH_CLOUD` (default `0` => OFF, dropped — local-only build, no AWS SDK). When ON, build only needed components via `ELOQDB_AWS_COMPONENTS` (default `s3`) |
| google-cloud-cpp | v2.24.0        | upstream / third_party     | optional/cloud  | DROP by default; only BIGTABLE / cloud-GCS |
| rocksdb-cloud    | **latest**     | **eloqdata** / sub_modules | optional/cloud  | DROP by default; needs aws + gcp |
| data_substrate   | latest         | **eloqdata/tx_service** / data_substrate | core | meta-repo (named *tx_service*); cloned **top-level only** |
| ├ tx-log-protos  | latest         | **eloqdata** / data_substrate | core         | single checkout; consumed by both tx_service and log_service |
| ├ log_service    | latest         | **eloqdata** / data_substrate | core         | |
| ├ eloqstore      | latest         | **eloqdata** / data_substrate | core         | gets concurrentqueue/inih/abseil from `dependencies/`; built `-DGIT_SUBMODULE=OFF` (patched on `lintao-mod`) so it never pulls submodules; `external/abseil` unused inside the core (uses tx_service's abseil) |
| └ eloq_metrics   | latest         | (dir in data_substrate)    | core            | regular dir, not a submodule |

Project-local (NOT shared): eloqsql vendored submodules — `storage/rocksdb/rocksdb`, `libmariadb`,
`wsrep-lib`, `wolfssl`, `libmarias3`, `columnstore`; eloqdoc vendored MongoDB `src/third_party/*`.
These stay inside their product checkout (project-scoped prefix, searched before the shared one).

## Build order (topological, into the shared prefix)

```
# Tier 0 — no inter-dep (parallelizable)
abseil  liburing  lua  json  crc32c  re2  glog  mimalloc  cuckoofilter  rocksdb
concurrentqueue  inih  [Catch2 FakeIt]

# Tier 1
protobuf            (← abseil)

# Tier 2
grpc                (← protobuf, abseil, re2, crc32c)      [GCP-only]
brpc                (← glog, protobuf)
prometheus-cpp

# Tier 3
braft               (← brpc)

# Tier 4 — optional cloud (only if an enabled product+backend needs it)
aws-sdk-cpp (s3)    google-cloud-cpp    rocksdb-cloud (← aws, gcp, rocksdb)

# Tier 5 — the shared core (eloqdata/tx_service)
data_substrate      (← brpc, braft, protobuf, abseil, rocksdb, mimalloc, glog, prometheus)
  # cloned top-level only; tx-log-protos/log_service/eloqstore come from dependencies/.
  # find_package's the Tier 0–4 deps. Products also compile it inline (add_subdirectory)
  # with their own WITH_DATA_STORE, against this same shared checkout.

# Tier 6 — products
eloqkv (cmake) | eloqsql (cmake) | eloqdoc (scons+py2) | eloquentdb (cmake)
```

## Open items

1. ~~Eliminate symlinks + submodule recursion~~ — **done.** `substrate.sh` fetches real checkouts
   and passes `eloq_substrate_dir_flags`; `clone_product` does top-level + project-local submodules
   only (never data_substrate). eloqdata CMake patched on `lintao-mod` (tx_service, eloqkv, eloqsql,
   eloqdoc). Only intra-dependency symlinks remain (rocksdb `.so` links, etc.).
2. **eloqdoc Python 2.7 toolchain** — rebuild the pyenv 2.7 with `bz2`/`_sqlite3`/`ctypes` (after
   apt `libbz2-dev libsqlite3-dev libffi-dev`) and `pip2 install Cheetah` (+ other MongoDB-4.0.3
   build Python deps). The Eloq cmake module already builds.
3. **FakeIt pin** — choose a commit/tag to pin (currently floats on HEAD).
4. **eloquentdb** — build the unified binary (engines already wired to projects/<engine>).
5. **Definition of done** — each enabled product builds against the shared prefix + a smoke test.
   (eloqkv ✅, eloqsql ✅ end-to-end; eloqdoc cmake module ✅, server pending Python toolchain.)

## Extra system prerequisites surfaced during builds

Beyond the README list, the following were needed on the build host (apt, user-installed):
`bison` (eloqsql/MariaDB parser); `libbz2-dev`, `libsqlite3-dev`, `libffi-dev` (eloqdoc's
Python 2.7 modules). `flex` may also be required by MariaDB.
