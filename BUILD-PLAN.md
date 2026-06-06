# EloqDB Build Plan

Execution-detail layer for the refactor. Strategy and decisions live in `CLAUDE.md`; this file
is the concrete inventory: what to build, which version, from where, in what order, and how each
dep is made sudo-free. Derived from the three products' `scripts/install_dependency_ubuntu2404.sh`.

## System prerequisites (assumed present, NOT built — document in README)

Toolchain: `gcc/g++`, `make`, `cmake`, `ninja-build`, `pkg-config`, `m4`, `git`, `patchelf`, `ccache`.
System libs: `libssl-dev`, `zlib1g-dev`, `libgflags-dev`, `libleveldb-dev`, `libsnappy-dev`,
`liblz4-dev`, `libzstd-dev`, `libbz2-dev`, `libcurl4-openssl-dev`, `libc-ares-dev`,
`libuv1-dev`, `libboost-context-dev`, `libreadline-dev`, `libncurses5-dev`, `bison`.
(JDK/redis/tcl are only needed for some test suites.)

## Dependency matrix

**Version policy by owner:**
- **`eloqdata/` and `ltzhang/` repos → latest** (default-branch HEAD), ignoring any pinned
  commit/tag. The "Version" column for these shows `latest`.
- **All other third-party repos → pinned** to the version shown (a real target, not just a
  reference), so upstream releases can't break the build.

Versions are identical across eloqkv / eloqsql / eloqdoc unless noted.

| Dependency       | Version       | Source (pin)        | Tier            | Notes |
|------------------|---------------|---------------------|-----------------|-------|
| abseil-cpp       | commit 69195d5 | upstream (git)     | shared          | **pinned to data_substrate's vendored commit**; do NOT patch `options.h` (keep USE_*=2 std types — tx_service needs std::string_view). data_substrate -I's the prefix before its vendored abseil, so they must be byte-identical |
| protobuf         | v21.12        | upstream tar        | shared          | needs abseil (`ABSL_PROVIDER=package`), built USE_*=2 |
| re2              | 2023-08-01    | upstream tar        | **GCP-only**    | grpc dep — gated behind `--with-gcp` |
| crc32c           | 1.1.2         | upstream tar        | **GCP-only**    | grpc dep — gated behind `--with-gcp` |
| grpc             | v1.51.1       | upstream tar        | **GCP-only**    | only google-cloud-cpp links it; nothing in the default build does. Also won't compile against abseil 20230802 (USE_*=2) — gated behind `--with-gcp` |
| liburing         | 2.6           | axboe (upstream)    | shared          | `./configure` |
| lua              | 5.4.6         | lua.org             | shared          | `make` |
| json (nlohmann)  | 3.11.2        | upstream tar        | shared          | header-ish |
| glog             | **latest**    | **eloqdata**        | shared          | latest default branch |
| brpc             | **latest**    | **eloqdata**        | shared          | latest; needs glog, protobuf, leveldb, ssl, gflags; io_uring ON |
| braft            | **latest**    | **eloqdata**        | shared          | latest; needs brpc; strip `libbrpc.a` from CMakeLists |
| mimalloc         | **latest**    | **eloqdata**        | shared          | latest (ignore `eloq-v2.1.2` pin) |
| cuckoofilter     | **latest**    | **eloqdata**        | shared          | latest; `make install` — needs PREFIX patch |
| rocksdb          | v9.1.0 (pin)  | facebook (upstream) | shared          | `make shared_lib`; RTTI=1, no tcmalloc/jemalloc |
| prometheus-cpp   | v1.1.0 (pin)  | jupp0r (upstream)   | shared          | metrics |
| Catch2           | v3.3.2 (pin)  | upstream            | shared (test)   | only if tests enabled |
| FakeIt           | pin TBD       | upstream            | shared (test)   | currently floats on HEAD → choose a commit/tag to pin; header copy needs prefix patch |
| data_substrate   | latest        | **ltzhang/data_substrate** | core     | meta-repo (ltzhang fork of eloqdata/tx_service); cloned top-level only — submodules are flattened (below) |
| ├ tx-log-protos  | latest        | **eloqdata/tx-log-protos** | core | flat at `sub_modules/tx-log-protos`; **single checkout** symlinked into BOTH `tx_service/` and `log_service/` (de-duplicated) |
| ├ log_service    | latest        | **eloqdata/log_service** | core   | flat at `sub_modules/log_service`; symlinked into `data_substrate/log_service` |
| ├ eloqstore      | latest        | **ltzhang/eloqstore** | core      | flat at `sub_modules/eloqstore`; symlinked into `store_handler/.../eloqstore`; its `concurrentqueue`/`inih` are flat under `third_party/`; `external/abseil` omitted (uses tx_service's abseil); built `-DGIT_SUBMODULE=OFF` |
| ├ concurrentqueue| c680721 (pin) | cameron314 (upstream) | core    | flat at `third_party/concurrentqueue`; symlinked into eloqstore |
| ├ inih           | 8e06f6b (pin) | benhoyt (upstream)  | core      | flat at `third_party/inih`; symlinked into eloqstore |
| └ eloq_metrics   | latest        | (dir in data_substrate) | core    | regular dir, not a submodule |

**Submodule flattening:** all of data_substrate's (recursive) submodules are checked out ONCE at
depth-2 under `dependencies/{third_party,sub_modules}/` and symlinked into the deep paths the build
expects — no submodules buried under other repos, and shared ones (abseil → `third_party/abseil-cpp`,
tx-log-protos → `sub_modules/tx-log-protos`) get a single checkout. Implemented in `substrate.sh`
(`flatten_submodules`).
| aws-sdk-cpp      | 1.11.446      | upstream            | **REQUIRED (s3)** | eloqstore hard-requires `find_package(AWSSDK COMPONENTS s3)` — needed for the default EloqStore backend, not droppable. Build only the needed components via ELOQDB_AWS_COMPONENTS (default `s3`) |
| google-cloud-cpp | v2.24.0       | upstream            | optional/cloud  | DROP by default; only BIGTABLE / cloud-GCS |
| rocksdb-cloud    | **latest**    | **eloqdata**        | optional/cloud  | DROP by default; latest; needs aws + gcp |

Product repos (manifest, `projects/`): **ltzhang/{eloqkv,eloqsql,eloqdoc}** (ltzhang forks exist;
switch to eloqdata later). Refs/tags TBD.

Project-local (NOT shared): eloqsql vendored submodules — `storage/rocksdb/rocksdb`, `libmariadb`,
`wsrep-lib`, `wolfssl`, `libmarias3`, `columnstore`; eloqdoc vendored MongoDB `src/third_party/*`.

## Build order (topological, into the shared prefix)

```
# Tier 0 — no inter-dep (parallelizable)
abseil  liburing  lua  json  crc32c  re2  glog  mimalloc  cuckoofilter  rocksdb  [Catch2 FakeIt]

# Tier 1 — needs Tier 0
protobuf            (← abseil)

# Tier 2
grpc                (← protobuf, abseil, re2, crc32c)
brpc                (← glog, protobuf)
prometheus-cpp

# Tier 3
braft               (← brpc)

# Tier 4 — optional cloud (only if an enabled product+backend needs it)
aws-sdk-cpp
google-cloud-cpp
rocksdb-cloud       (← aws-sdk-cpp, google-cloud-cpp, rocksdb)

# Tier 5 — the shared core (eloqdata/tx_service meta-repo)
data_substrate      (← brpc, braft, protobuf, abseil, rocksdb, mimalloc, glog, prometheus)
  # recursive clone pulls: tx_service(+tx-log-protos), log_service, eloqstore, eloq_metrics
  # find_package's the shared deps above => builds last. Has install() targets => installed
  # into the prefix here (default backend). Products ALSO compile it inline (add_subdirectory)
  # with their own WITH_DATA_STORE, against this same shared checkout.

# Tier 6 — products
eloqkv (cmake) | eloqsql (cmake) | eloqdoc (scons+py2)   (← everything above + data_substrate)
```

## Sudo-free conversion per dep

- **CMake deps** (abseil, protobuf, grpc, re2, crc32c, json, prometheus-cpp, braft via cmake,
  rocksdb-cloud, aws, google-cloud, Catch2): replace `sudo cmake --install` /
  `-DCMAKE_INSTALL_PREFIX=/usr*` with `-DCMAKE_INSTALL_PREFIX=$ELOQDB_PREFIX`; drop `ldconfig`.
- **Make deps** (lua, rocksdb, liburing): use `PREFIX=$ELOQDB_PREFIX` / `make install` into prefix.
- **`sudo cp … /usr/...` deps** (brpc, braft, cuckoofilter, FakeIt): redirect copies to
  `$ELOQDB_PREFIX/{include,lib}` — these need explicit script patches (no native prefix support).
- Set rpath / `LD_LIBRARY_PATH=$ELOQDB_PREFIX/lib` so products find the shared libs at runtime.

## Open items before/while executing

1. ~~data_substrate commit~~ — **resolved**: always-latest policy → build latest default-branch
   HEAD of `eloqdata/tx_service`; the divergent pins are ignored.
2. **Product/dep refs** — all sourced from each repo's **latest default branch** (always-latest
   policy). Only branch *names* need confirming if any repo's default isn't `main`/`master`.
3. **eloqsql / eloqdoc feature flags** — their backend-selection equivalents of eloqkv's
   `WITH_DATA_STORE`, to confirm what the cloud/optional tier gates for each.
4. **Definition of done** — each enabled product builds against the shared prefix + a smoke test.
