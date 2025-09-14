# Pro Multi‑Arch Release Builder (Go)

**Build professional, reproducible, multi‑platform releases from a single ZIP.**

[![Build](https://img.shields.io/github/actions/workflow/status/your-org/your-repo/release.yml?label=CI%2FCD&logo=github-actions)](https://github.com/your-org/your-repo/actions)
[![Latest Release](https://img.shields.io/github/v/release/your-org/your-repo?logo=github)](https://github.com/your-org/your-repo/releases)
[![Go](https://img.shields.io/badge/Go-%E2%89%A51.20-00ADD8?logo=go)](https://go.dev/)
[![License: MIT](https://img.shields.io/badge/License-MIT-informational.svg)](./LICENSE)
[![Conventional Commits](https://img.shields.io/badge/Conventional%20Commits-1.0.0-orange.svg)](https://www.conventionalcommits.org/en/v1.0.0/)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](./CONTRIBUTING.md)

> Drop `input/<name>.zip` in the repo, run one command, and get a full GitHub‑Release‑ready bundle: cross‑compiled archives, SHA256 checksums, a human‑readable **RELEASE.md**, and a machine‑readable **release.manifest.json**.

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Quick Start](#quick-start)
- [Naming (Your Request)](#naming-your-request)
- [How It Works](#how-it-works)
- [Outputs](#outputs)
- [Configuration & Environment Variables](#configuration--environment-variables)
- [Docker (Reproducible / Isolated)](#docker-reproducible--isolated)
- [CI/CD on GitHub Actions](#cicd-on-github-actions)
- [Versioning & Releases](#versioning--releases)
- [Extending the Platform Matrix](#extending-the-platform-matrix)
- [Troubleshooting](#troubleshooting)
- [Security Policy](#security-policy)
- [Contributing & Code Style](#contributing--code-style)
- [FAQ](#faq)
- [Repository Layout](#repository-layout)
- [License](#license)

## Features

- ✅ **Dynamic naming**: all asset filenames are **prefixed by your input ZIP name**. `input/myapp.zip` → `myapp-linux-amd64.tar.gz`, `myapp-windows-amd64.zip`, etc.
- 🧱 **Reproducible outputs**: fixed mtime (via `SOURCE_DATE_EPOCH`), numeric owners, sorted entries, and `zip -X` ensure stable SHA256 hashes across identical builds.
- ⚡ **Parallel compilation** with job throttling (`NUM_JOBS`).
- 🔎 **Auto‑detects the main package** (prefers `./cmd/*`; errors clearly if multiple mains are found).
- 🗂️ **Complete release surfaces**: human list (**RELEASE.md**) + JSON manifest (**release.manifest.json**), plus source exports (`-source.zip` & `-source.tar.gz`).
- 🐳 **Dockerfile** for deterministic, isolated builds.
- 🤖 **GitHub Actions** workflow for push‑button CI/CD and Release publishing.
- 🧪 **Makefile** for local developer ergonomics.
- 🧰 **Highly configurable**: binary name, artifact prefix, build path, CGO, linker flags, and more.

## Requirements

- OS: Linux/macOS with a POSIX shell (Bash)
- Tooling: `bash`, `unzip`, `zip`, `tar`, `sha256sum`, `python3`, `go` (Go ≥ 1.20)
- Optional: Docker (recommended for consistent toolchains)

> If your project requires CGO or native libraries, prefer running the build in a container or a CI runner with the proper cross‑toolchains installed.

## Quick Start

1. Create the files in this repository (notably `build.sh`, `tools/release_list.py`, `.github/workflows/release.yml`, `Dockerfile`, `Makefile`, and this `README.md`).
2. Place your source as `input/<name>.zip`, e.g. `input/myapp.zip`.
3. Run:

```bash
chmod +x build.sh
./build.sh input/myapp.zip
```

4. Inspect outputs under `./myapp/`:

   - `myapp-source.zip`, `myapp-source.tar.gz`
   - `./myapp/Assets/*`
   - `./myapp/RELEASE.md`
   - `./myapp/release.manifest.json`

## Naming (Your Request)

- Asset filenames use the **input ZIP name** as prefix:
  **`input/<NAME>.zip` → `<NAME>-linux-*.tar.gz`, `<NAME>-windows-amd64.zip`, …**
- Checksum sidecars are written **without the archive suffix**:
  `myapp-linux-amd64.sha256` (not `myapp-linux-amd64.tar.gz.sha256`).

> Want a different binary name only (inside the archives)?
>
> ```bash
> export OUTPUT_NAME=mybinary
> ```
>
> Want to override only the asset filename prefix?
>
> ```bash
> export ARTIFACT_PREFIX=myrelease
> ```

## How It Works

```mermaid
flowchart LR
  A[input/<name>.zip] --> B[build.sh]
  B --> C[Extract to ./<name>/src]
  C --> D[Auto-detect BUILD_PATH]
  D --> E[Parallel cross-compile (Go)]
  E --> F[Package archives + SHA256]
  F --> G[RELEASE.md + release.manifest.json]
  G --> H[./<name>/Assets + source archives]
```

### Default Target Matrix

- **Linux**: `386`, `amd64`, `arm64`, `armv5`, `armv6`, `armv7`, `s390x` → `tar.gz`
- **Windows**: `amd64` → `zip`

> Internally, builds are performed with `CGO_ENABLED=0` by default to keep artifacts portable. If you need CGO, set `CGO_ENABLED=1` and ensure toolchains exist for each target.

## Outputs

A generated `RELEASE.md` (GitHub‑Release‑style):

```markdown
# Release Assets

| File                     | Size   | SHA256 |
| ------------------------ | ------ | ------ |
| myapp-linux-amd64.tar.gz | 7.2 MB | 1b2f…  |
| myapp-linux-arm64.tar.gz | 7.1 MB | 8a91…  |
| myapp-windows-amd64.zip  | 8.0 MB | 3c44…  |
| …                        | …      | …      |

> Total assets: 8
```

And a machine‑readable `release.manifest.json`:

```json
{
  "generated_at": "2025-09-15T09:30:00Z",
  "assets": [
    {
      "name": "myapp-linux-amd64.tar.gz",
      "size": 7543210,
      "sha256": "1b2f..."
    },
    { "name": "myapp-windows-amd64.zip", "size": 8123456, "sha256": "3c44..." }
  ]
}
```

### Folder Layout After Build

```
/input
  └── myapp.zip
/myapp
  ├── myapp-source.zip
  ├── myapp-source.tar.gz
  ├── release.manifest.json
  ├── RELEASE.md
  └── Assets/
      ├── myapp-linux-386.tar.gz
      ├── myapp-linux-386.sha256
      ├── myapp-linux-amd64.tar.gz
      ├── myapp-linux-amd64.sha256
      ├── myapp-linux-arm64.tar.gz
      ├── myapp-linux-arm64.sha256
      ├── myapp-linux-armv5.tar.gz
      ├── myapp-linux-armv5.sha256
      ├── myapp-linux-armv6.tar.gz
      ├── myapp-linux-armv6.sha256
      ├── myapp-linux-armv7.tar.gz
      ├── myapp-linux-armv7.sha256
      ├── myapp-linux-s390x.tar.gz
      ├── myapp-linux-s390x.sha256
      ├── myapp-windows-amd64.zip
      └── myapp-windows-amd64.sha256
```

## Configuration & Environment Variables

| Variable            | Default                     | Purpose                                                                                       |
| ------------------- | --------------------------- | --------------------------------------------------------------------------------------------- |
| `BUILD_PATH`        | auto‑detected               | Relative path (from `./<name>/src`) to the directory containing `main.go`. Prefers `./cmd/*`. |
| `OUTPUT_NAME`       | `<name>`                    | Binary name inside archives.                                                                  |
| `ARTIFACT_PREFIX`   | `<name>`                    | Filename prefix for all assets.                                                               |
| `NUM_JOBS`          | CPU cores                   | Parallel build slots.                                                                         |
| `CGO_ENABLED`       | `0`                         | Set to `1` if your app needs CGO (cross toolchains required).                                 |
| `LDFLAGS`           | `-s -w`                     | Linker flags.                                                                                 |
| `GOFLAGS`           | `-buildvcs=false -trimpath` | Extra Go build flags for clean/reproducible outputs.                                          |
| `SOURCE_DATE_EPOCH` | `1577836800`                | Base mtime for deterministic archives (2020‑01‑01).                                           |

### Reproducibility Details

- **tar**: `--sort=name --owner=0 --group=0 --numeric-owner --mtime=@$SOURCE_DATE_EPOCH`
- **zip**: `-X` (strip extra file attributes)
- **TZ**: forced to `UTC`
- Checksums: SHA256 sidecars without archive suffix, simplifying copy‑into release notes.

## Docker (Reproducible / Isolated)

**Build image:**

```bash
docker build -t pro-release .
```

**Run build:**

```bash
docker run --rm -v "$PWD:/work" pro-release bash -lc './build.sh input/myapp.zip'
```

> This pins toolchain versions and avoids host‑specific differences.

## CI/CD on GitHub Actions

- Workflow file: `.github/workflows/release.yml`
- **Triggers**:

  - `workflow_dispatch` with `input_zip`
  - Tag push matching `v*` → publish a GitHub Release with assets attached

Update badges/links to your repo: replace `your-org/your-repo` in badge URLs.

### Permissions & Secrets

- Uses the built‑in `GITHUB_TOKEN` with `contents: write` to publish release assets on tag builds.
- Add extra secrets only if you need external uploads/signing.

### Artifacts

- Non‑tag builds: `actions/upload-artifact` attaches `Assets/*`.
- Tag builds: `softprops/action-gh-release` uploads assets to the Release page.

## Versioning & Releases

- **SemVer**: `MAJOR.MINOR.PATCH`
- **Conventional Commits** strongly recommended (e.g., `feat(builder): add mips64 targets`).

Suggested flow:

1. Merge PRs into `main`.
2. Tag a release: `git tag v1.2.3 && git push origin v1.2.3`.
3. CI builds and publishes assets. `RELEASE.md` and `release.manifest.json` can be included in notes or used downstream.

> Optionally add `CHANGELOG.md` generation using a conventional‑changelog action or `semantic-release` if desired.

## Extending the Platform Matrix

1. Edit target arrays in `build.sh` (`linux_targets` / `windows_targets`).
2. Update `build_one()` if you need different packaging (e.g., `rpm`, `deb`).
3. Reflect changes in this README.

> Architectures requiring CGO or special libc (e.g., musl) should be built inside a compatible container or runner. Consider a multi‑stage Dockerfile for musl.

## Troubleshooting

- **“Could not uniquely detect main”**
  Multiple mains found. Set `BUILD_PATH`, e.g. `export BUILD_PATH=./cmd/myapp`.
- **`go: no Go files`**
  The chosen `BUILD_PATH` doesn’t contain a `main.go`. Point to the correct directory.
- **CGO link errors**
  Use `CGO_ENABLED=1` and ensure cross toolchains for target OS/arch are installed (or build in a container).
- **Non‑GNU tar warning** (e.g., on macOS/BSD)
  Reproducibility may be slightly reduced; prefer Docker or install GNU tar.
- **Checksum mismatch**
  Any change to artifacts invalidates checksums. Re‑run `build.sh` after modifications.

## Security Policy

If you discover a security issue, please use responsible disclosure. You can open a private security advisory in GitHub or contact the maintainers via email.

> For enterprises, add a `SECURITY.md` with contact details and supported branches.

## Contributing & Code Style

- We welcome Pull Requests! Please open an Issue first to discuss significant changes.
- **Commit style**: [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).
- Before submitting:

  - Lint shell scripts with `shellcheck` (if available).
  - Run a local or containerized build and include `RELEASE.md` excerpts in the PR.

- Optional repository additions:

  - `CONTRIBUTING.md`, `CODEOWNERS`, Issue/PR templates, and automated changelog generation.

## FAQ

**Why are checksums stored without the archive extension?**
It simplifies copying into release notes and matches the requested naming style.

**What if my Go project has multiple modules?**
Set `BUILD_PATH` to the module/package containing your `main.go` or invoke the script per module.

**Can I set binary name and asset prefix independently?**
Yes. `OUTPUT_NAME` controls the binary name inside archives; `ARTIFACT_PREFIX` controls the filenames of the produced assets.

**How do I verify an asset?**

```bash
sha256sum -c myapp-linux-amd64.sha256 < myapp-linux-amd64.tar.gz
```

(Or compute and compare manually: `sha256sum myapp-linux-amd64.tar.gz`.)

## Repository Layout

```
.
├─ build.sh
├─ tools/
│  └─ release_list.py
├─ .github/
│  └─ workflows/
│     └─ release.yml
├─ Dockerfile
├─ Makefile
└─ README.md
```

## License

Released under the **MIT License**. See [`LICENSE`](./LICENSE) for details.
