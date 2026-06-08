# EloqDB

EloqDB is a single-directory, **sudo-free** umbrella build for the Eloq product family. From one
checkout it fetches each product and its shared dependencies, builds everything into a local
prefix (`install/`), and produces the product binaries — without touching system directories.

| Product | Compatible with | Produces |
|---------|-----------------|----------|
| **eloqkv** | Redis | `eloqkv` |
| **eloqsql** | MariaDB | `mariadbd` / `mysqld` |
| **eloqdoc** | MongoDB 4.0.3 | `mongod` *(SCons + a hermetic Python 3 venv — see notes)* |
| **eloquentdb** | unified engine | `eloqdb` (eloqkv + eloqsql in one binary) |

## 1. Prerequisites

Install the system toolchain and libraries once (EloqDB builds the heavy/pinned libraries itself,
but relies on these being present):

```bash
sudo apt-get install -y \
    build-essential g++ make cmake ninja-build pkg-config git curl m4 patchelf ccache bison flex \
    libssl-dev gnutls-dev zlib1g-dev libgflags-dev libleveldb-dev libsnappy-dev liblz4-dev \
    libzstd-dev libbz2-dev libcurl4-openssl-dev libc-ares-dev libuv1-dev libboost-context-dev \
    libjsoncpp-dev libreadline-dev libncurses-dev
```

You also need a **GitHub SSH key**: EloqDB clones the Eloq repositories (`eloqdata/*`) over SSH.
Third-party dependencies are fetched over https and need no credentials.

## 2. Build

```bash
source env.sh          # sets the local install prefix + build environment (run in each shell)
./scripts/build.sh     # builds the enabled products: deps -> shared core -> products
```

Product binaries land under `build/<product>/`; shared libraries install into `install/`. Keep
`env.sh` sourced when running a binary (it sets `LD_LIBRARY_PATH`):

```bash
./build/eloqkv/eloqkv --version
./build/eloqsql/sql/mariadbd --version
./build/eloquentdb/eloqdb --version
```

## 3. Choosing what to build

Edit [manifest.toml](manifest.toml): set `enabled = true` for the products you want, and adjust each
product's backend flags (`with_data_store`, `with_log_state`). The default
(`ELOQDSS_ELOQSTORE` + `ROCKSDB`) is a minimal stack with **no cloud dependencies** — the AWS,
Google Cloud, and RocksDB-Cloud SDKs are built only when a selected backend needs them.

Build subsets or iterate on one layer:

```bash
./scripts/build.sh --product eloqkv     # one product (plus its dependencies)
./scripts/build.sh --deps-only          # shared third-party + fork dependencies only
./scripts/build.sh --data-substrate     # the shared Eloq core only
./scripts/build.sh --with-tests         # also build test deps (Catch2, FakeIt)
```

## 4. Layout

| Path | Contents |
|------|----------|
| `manifest.toml` | which products to build + their feature flags |
| `env.sh` | the shared-prefix build environment (`source` it) |
| `projects/` | product checkouts (created by the build; empty until selected) |
| `dependencies/` | all shared dependency checkouts (`third_party/`, `sub_modules/`, `data_substrate/`) |
| `scripts/build.sh` | top-level orchestrator |
| `scripts/projects/*.sh` | per-product build adapters |
| `build/` | all build trees |
| `install/` | the local prefix (`include/ lib/ bin/`) — replaces `/usr/local`, no sudo |

## Notes

- **Build parallelism / memory.** `env.sh` caps `ELOQDB_JOBS` to `min(nproc, ½·RAM_GB, 8)` because
  the heavy C++ translation units (MariaDB `sql/`, abseil, the core) can each use multiple GB and
  OOM-kill a full-core build. Lower it further if a build still dies suddenly:
  `ELOQDB_JOBS=4 ./scripts/build.sh`.

- **Versioning.** Eloq repositories (`eloqdata/*`) are built from the latest of their default
  branch; all other third-party dependencies are pinned to known-good versions.

- **eloqdoc / Python 3 build venv.** eloqdoc is a MongoDB 4.0.3 fork (the last AGPL release) built
  with SCons. Its upstream build scripts targeted Python 2.7 (now gone from Ubuntu 24.04), so on
  `lintao-mod` they were ported to Python 3 (str/bytes, `dict` iterators, the removed `'rU'` file
  mode, …) and the vendored SCons 2.5.0 engine was swapped for a modern, pip-installed SCons. The
  adapter (`scripts/projects/eloqdoc.sh`) provisions a hermetic venv at `.venv-eloqdoc/`
  automatically — no system Python changes — installing `scons`, `Cheetah3` (the maintained Python
  3 fork of the `Cheetah` templating engine `generate_error_codes.py` needs), and the IDL
  compiler's other deps (`pyyaml`, `jinja2`, `packaging`). No extra system packages are required
  for it (the old pyenv-based Python 2.7 path needed `libsqlite3-dev`/`libbz2-dev`/`libffi-dev` —
  no longer necessary). `scons install-core` builds the MongoDB server end-to-end into
  `install/bin/{eloqdoc,eloqdoc-cli}`.

For design rationale, the full dependency inventory, and build internals, see
[CLAUDE.md](CLAUDE.md) and [BUILD-PLAN.md](BUILD-PLAN.md).
