# Building Eloq Products

There are two ways to build, depending on your role:

| Workflow | Who | Entry point |
|---|---|---|
| **Single product** | Community / third-party contributors | Clone a product repo, run `./build.sh` |
| **Full suite** | eloqdata developers | Clone this repo (`eloq_build_env`), run `scripts/build.sh` |

Both workflows share the same build environment and produce artifacts in the same `install/`
prefix — there is exactly **one copy of every dependency**, regardless of how many products you build.

---

## Workflow A — Single product (community users)

Clone the product you want to work on and run its `build.sh`. That's it.

```bash
git clone https://github.com/eloqdata/eloqkv.git
cd eloqkv
chmod +x build.sh && ./build.sh
```

`build.sh` handles everything on first run:

1. Clones [eloq_build_env](https://github.com/ltzhang/eloq_build_env) as a sibling (`../eloq_build_env`)
2. Builds all shared dependencies into `../eloq_build_env/install/` (~30–60 min; cached afterwards)
3. Builds the shared core (`data_substrate`)
4. Builds the product

Subsequent `./build.sh` runs skip the cached steps and only rebuild the product itself.

### Available products

| Product | Clone URL | Binary |
|---|---|---|
| eloqkv | `https://github.com/eloqdata/eloqkv.git` | `eloqkv` |
| eloqsql | `https://github.com/eloqdata/eloqsql.git` | `mariadbd` |
| eloqdoc | `https://github.com/eloqdata/eloqdoc.git` | `eloqdoc`, `eloqdoc-cli` |
| eloquentdb | `https://github.com/eloqdata/eloquentdb.git` | `eloqdb` (unified kv+sql binary) |

Binaries land in `../eloq_build_env/install/bin/`.

> **eloquentdb note:** the unified binary links eloqkv and eloqsql as engines. `build.sh` looks
> for those repos as siblings of the eloquentdb checkout (e.g. `../eloqkv`, `../eloqsql`) and
> auto-clones them there if absent — it does **not** pull separate copies inside the eloquentdb
> tree. If you already have eloqkv and eloqsql cloned alongside, they are reused as-is.

### System prerequisites (Ubuntu 24.04)

```bash
sudo apt install -y \
    git build-essential cmake ninja-build pkg-config python3 python3-venv \
    bison flex libssl-dev zlib1g-dev libgflags-dev libleveldb-dev \
    libsnappy-dev liblz4-dev libzstd-dev libbz2-dev libcurl4-openssl-dev \
    libjsoncpp-dev liburing-dev
```

### Non-sibling layouts

If you cannot place repos as siblings, use one of these alternatives:

```bash
# Option 1: env var
export ELOQ_BUILD_ENV=/path/to/eloq_build_env
./build.sh

# Option 2: symlink (add eloq_env to .gitignore)
ln -s /path/to/eloq_build_env eloq_env
./build.sh
```

---

## Workflow B — Full suite (eloqdata developers)

```bash
git clone git@github.com:ltzhang/eloq_build_env.git eloq_build_env
cd eloq_build_env
source env.sh
./scripts/build.sh                      # deps -> substrate -> all enabled products
```

Useful flags:

```bash
./scripts/build.sh --deps-only          # layer 1: shared deps only
./scripts/build.sh --data-substrate     # layer 2: shared core only (requires layer 1)
./scripts/build.sh --product eloqkv     # full stack scoped to one product
```

Products are cloned into `projects/` automatically from the manifest. Artifacts land in `install/`.

---

## Committing build.sh to eloqsql / eloquentdb

`build.sh` for eloqkv and eloqdoc already lives in their repo roots (on `lintao-mod`).
For **eloqsql** and **eloquentdb**, copy the template from this repo and commit it:

```bash
# eloqsql
cp eloq_build_env/scripts/standalone/eloqsql-build.sh eloqsql/build.sh
chmod +x eloqsql/build.sh
cd eloqsql && git checkout -b lintao-mod && git add build.sh && git commit -m "build: add standalone build.sh"

# eloquentdb
cp eloq_build_env/scripts/standalone/eloquentdb-build.sh eloquentdb/build.sh
chmod +x eloquentdb/build.sh
cd eloquentdb && git checkout -b lintao-mod && git add build.sh && git commit -m "build: add standalone build.sh"
```

---

## Tuning the build

| Variable | Default | Effect |
|---|---|---|
| `ELOQDB_JOBS` | `min(nproc, ½·RAM_GB)` | Parallel compile jobs; lower to 4 if OOM |
| `ELOQDB_WITH_CLOUD` | `0` | Set to `1` to build AWS/GCP cloud backends |
| `ELOQDB_WITH_DATA_STORE` | `ELOQDSS_ELOQSTORE` | Storage backend |
| `ELOQDB_WITH_LOG_STATE` | `ROCKSDB` | Log-state backend |

Export overrides before running `build.sh`:

```bash
export ELOQDB_JOBS=4
export ELOQDB_WITH_CLOUD=1
./build.sh
```
