# eloq_build_env

## Goal

eloq_build_env is the umbrella that gives the Eloq product family a **clean, fast, reproducible,
sudo-free build** from one directory. It replaces the original per-product
`install_dependency_ubuntu2404.sh` scripts (which used `sudo` and installed into system root
locations) with a single shared build into a local prefix.

Products built under this umbrella:

| Product     | Compatibility | Build system | Notable per-product deps |
|-------------|---------------|--------------|--------------------------|
| eloqkv      | Redis         | CMake        | `crcspeed` |
| eloqsql     | MariaDB       | CMake        | `libmariadb`, **vendored `rocksdb`**, `wsrep-lib`, `wolfssl`, `libmarias3`, `columnstore` |
| eloqdoc     | MongoDB 4.0.3 | SCons + Py3  | vendored MongoDB `src/third_party/*` |
| eloquentdb  | unified `eloqdb` binary | CMake | links **eloqkv + eloqsql** + the shared core into one executable |

All products share the same core (**`eloqdata/tx_service`**, a.k.a. *data_substrate*) and overlap
heavily on the heavy libraries (brpc, braft, protobuf, abseil, glog, mimalloc, rocksdb, …).

## Build architecture

1. **One checkout per dependency, all under `dependencies/`.** Every common submodule /
   third-party library is checked out exactly once into `dependencies/` (classified by origin —
   see below) and built once into the shared prefix `install/`. No dependency is buried as a
   nested submodule under a product or under another dependency.
2. **Avoid directory symlinks as build wiring.** The build should not *routinely* stitch the
   source tree together with symbolic links to directories — products and the core find the
   shared sources in `dependencies/` and the shared libraries in `install/` **directly**, via
   `CMAKE_PREFIX_PATH`, explicit source paths, or build-script variables, not through a
   symlinked submodule path. The judicious exception: when upstream *hardcodes* an in-tree path
   (e.g. eloqdoc's vendored MongoDB `#include`s ~76 references to
   `mongo/db/modules/eloq/data_substrate/...`, baked into both Eloq and core mongo sources, with
   no override hook), a single targeted symlink from that path to the shared `dependencies/`
   checkout is the pragmatic fix — see `_link_data_substrate_into_eloq_module` in
   `projects/eloqdoc/build.sh`. Reach for this only when a real path/flag override isn't
   possible; default to the direct-reference approach everywhere else.
3. **No submodule pulling during the build.** The build never runs `git submodule update --init`
   and never clones with `--recurse-submodules`. Each repo is cloned **top-level only**; the
   submodule content it expects is supplied from `dependencies/`. Any CMake/SCons logic that would
   `git submodule update` is patched (on the repo's `lintao-mod` branch) to consume the shared
   checkout instead — e.g. eloqstore's `GIT_SUBMODULE` now defaults **OFF**.
4. **No pulls into random places.** The build must not deposit a freshly-cloned dependency
   somewhere inside a product/dependency tree (the classic failure: `eloqstore/external/abseil`
   appearing mid-configure). Sources live in `dependencies/`, build trees in `build/`, installed
   artifacts in `install/` — nowhere else.

Everything is **sudo-free**: nothing is written outside this repo.

## Directory Layout

```
eloqdb/
  manifest.toml      # which products to build, their refs/build-system, feature flags
  env.sh             # `source` it -> exports the shared-prefix contract (ELOQDB_*)
  build.sh           # umbrella orchestrator — the single user-facing entry point
  projects/          # product checkouts, cloned by the build (gitignored; empty until run)
    eloqkv/          #   each product repo has a build.sh at its root (see below)
    eloqsql/
    eloqdoc/
    eloquentdb/
  dependencies/      # ALL common deps, one checkout each, classified by origin:
    third_party/     #   upstream used as-is (unmodified)
    sub_modules/     #   upstream forked & modified by eloqdata
    data_substrate/  #   original Eloq projects (Eloq's own code, not a fork)
  _scripts/          # internal scripts (invoked only by build.sh — not user-facing):
    deps.sh          #   builds the shared third-party + eloqdata-fork deps
    substrate.sh     #   builds the shared core (data_substrate)
    clean.sh         #   removes build trees / install / individual deps
    common.sh        #   shared helpers (clone, build, link policy, banner)
  build/             # all build trees: build/deps/<dep>, build/<product>
  install/           # shared local prefix (include/ lib/ bin/) — replaces /usr/local, no sudo
```

Each product repo (`eloqdata/{eloqkv,eloqsql,eloqdoc,eloquentdb}`, on `lintao-mod`) ships a
`build.sh` at its root that serves dual purpose:
- **Orchestrated** (called by umbrella `build.sh` with `ELOQDB_ROOT` already exported): detects
  the environment is set up and runs only the cmake/scons product build — no env setup, no
  dep/substrate check.
- **Standalone** (run directly by a community user): resolves `eloq_build_env`, builds deps +
  substrate if not cached, then builds the product.

### Dependency classification (by origin)

Every external dependency goes in exactly one bucket under `dependencies/`, decided by **who owns
it and whether it was modified**:

| Bucket | Rule | Examples |
|--------|------|----------|
| `third_party/` | **Original upstream, used as-is.** | abseil, concurrentqueue, inih, protobuf, rocksdb, lua, re2, crc32c, grpc, prometheus-cpp, json, liburing, Catch2, FakeIt, aws-sdk-cpp, google-cloud-cpp |
| `sub_modules/` | **Upstream forked _and modified_ by eloqdata.** | brpc, braft, glog, mimalloc, cuckoofilter, rocksdb-cloud |
| `data_substrate/` | **Original Eloq projects** — Eloq's own code, not a fork. | data_substrate (tx_service core), log_service, tx-log-protos, eloqstore |

### Repo ownership & the `lintao-mod` branch

**Everything Eloq comes from `eloqdata/`; the only `ltzhang/` repo is this umbrella.** All
products, the core, and the Eloq forks are pulled from `eloqdata/`. Our modifications — patches
that make each repo consume `dependencies/` and stop pulling submodules — live on the
**`lintao-mod` branch** inside each eloqdata repo, keeping the default branches pristine. The
build prefers `ELOQDB_MOD_BRANCH` (`lintao-mod`) when the remote has it, falling back to the
default branch (`eloq_pick_branch` in `_scripts/common.sh`). The umbrella itself
(`ltzhang/eloq_build_env`) lives on `main`.

## Versioning policy

- **`eloqdata/` repos → always latest** (default-branch HEAD, preferring `lintao-mod` where it
  exists), **even when a submodule gitlink or dependency script pins an older commit/tag** —
  those pins are informational and we deliberately follow HEAD. Covers the products
  (`eloqdata/{eloqkv,eloqsql,eloqdoc,eloquentdb}`) and the forks + core (`eloqdata/{brpc, braft,
  glog, mimalloc, cuckoofilter, rocksdb-cloud, tx_service, eloqstore, log_service,
  tx-log-protos}`). The `ltzhang/eloq_build_env` umbrella follows the same rule.
- **All other third-party repos → pinned** to known-good versions (versions listed inline in
  `_scripts/deps.sh`), so an upstream release can't break the build.

## System vs. built dependencies (boundary)

We do **not** rebuild the base toolchain or common system libraries — the build **assumes the
system prerequisites are present** (installed via `apt`, outside this repo's scope): `gcc/g++`,
`make`, `cmake`, `ninja`, `pkg-config`, plus libs like `libssl-dev`, `zlib1g-dev`,
`libgflags-dev`, `libleveldb-dev`, `libsnappy/lz4/zstd/bz2-dev`. These live in the README's
prerequisite list. Only the heavy / pinned / forked dependencies are built locally into `install/`.
The full inventory, versions, sources, and build order live in `_scripts/deps.sh`.

## Minimal default build (feature-gated cloud deps)

The default config is `WITH_DATA_STORE=ELOQDSS_ELOQSTORE` + `WITH_LOG_STATE=ROCKSDB`. Heavy cloud
libraries are an all-or-nothing bundle gated by a single top-level switch, **`ELOQDB_WITH_CLOUD`**
in `env.sh` (default `0` — local-only build, no AWS/GCP at all):

| Dependency           | `ELOQDB_WITH_CLOUD=0` (default) | `ELOQDB_WITH_CLOUD=1` |
|----------------------|---------------------------------|------------------------|
| rocksdb              | Keep (always — `WITH_LOG_STATE=ROCKSDB` default) | Keep |
| aws-sdk-cpp (s3)     | Drop | Built — components scoped via `ELOQDB_AWS_COMPONENTS` (default `s3`, widens for DynamoDB) |
| google-cloud-cpp     | Drop | Built |
| rocksdb-cloud        | Drop | Built |

`build.sh` turns the single switch into `_scripts/deps.sh --with-cloud` (its existing shorthand
for `--with-aws --with-gcp --with-rocksdb-cloud`) — no separate per-backend granularity; **on**
pulls the whole stack, **off** pulls none of it.

### `ELOQDB_WITH_CLOUD` — local-only vs. cloud build

`env.sh` exports `ELOQDB_WITH_CLOUD` (default `0`). Setting it to `1` before sourcing `env.sh`:
- pulls the full cloud dep stack via `_scripts/deps.sh --with-cloud`
- compiles EloqStore's S3/GCS backend (`-DWITH_CLOUD_STORAGE=ON`, gated via `ELOQSTORE_WITH_CLOUD` on `lintao-mod`; defaults to a no-op stub when `OFF`)

**Caveat:** manifest entries that select `DYNAMODB` / `BIGTABLE` / `ELOQDSS_ROCKSDB_CLOUD_*` have
no local-only fallback — they require `ELOQDB_WITH_CLOUD=1`.

Backend options: `WITH_DATA_STORE` ∈ {`ELOQDSS_ELOQSTORE`, `ELOQDSS_ROCKSDB`,
`ELOQDSS_ROCKSDB_CLOUD_S3/_GCS`, `DYNAMODB`, `BIGTABLE`}; `WITH_LOG_STATE` ∈ {`MEMORY`, `ROCKSDB`,
`ROCKSDB_CLOUD_S3/_GCS`}.

## Build flow (`build.sh`)

1. Read `manifest.toml`; clone enabled products into `projects/` (**top-level only**, no submodule
   recursion).
2. Build the **union of dependencies** across enabled products+backends **once** into `install/`
   via `_scripts/deps.sh` (cloud stack only if a backend needs it).
3. Build the shared core (`data_substrate`) once via `_scripts/substrate.sh`.
4. Build each enabled product by calling its `build.sh` (at the repo root, under `projects/<name>/`):
   CMake products get `-DCMAKE_PREFIX_PATH=$ELOQDB_PREFIX`; eloqdoc's SCons gets the same prefix.
   Pinned project-local deps (e.g. eloqsql's vendored rocksdb) are searched ahead of the shared
   prefix. Since `ELOQDB_ROOT` is already exported, each product `build.sh` takes the orchestrated
   path — skipping env setup and dep/substrate steps.

### eloquentdb specifics

eloquentdb is itself an umbrella whose CMake links eloqkv + eloqsql + the core into one `eloqdb`
binary. Upstream it declares each engine as a pinned git submodule; here those are **not** pulled —
its `build.sh` points each engine at the umbrella's own `projects/<engine>` checkout and the shared
core, driven by eloquentdb's `.gitmodules`, following latest.

