# Schema Changes Reporting

Compares JSON schemas between two `platform-lsp` releases and produces a
combined HTML report showing structural changes across FOLIO module
repositories — including changes inside git submodules (e.g. `acq-models`).

---

## How it works

```
platform-lsp tag (e.g. R1-2025-csp-5)
  └─ install-applications.json        (≤ R1-2025-csp-7)
     platform-descriptor.json         (≥ R1-2025-csp-8, "applications")
       └─ app-platform-minimal-2.0.49
            └─ app-platform-minimal.template.json   (legacy)
               application.lock.json                (current, pinned versions)
                 └─ modules: [ { "name": "mod-users", "version": "19.5.4" } ]
                                         ↓
                              tag v19.5.4 in folio-org/mod-users
                                         ↓
                              diff ramls/**/*.json between base and head tags
                              + diff schemas inside submodules (filtered per module)
```

The workflow:

1. **resolve_tags** — clones `platform-lsp`, reads two release tags,
   walks `install-applications.json` (≤ csp-7) or `platform-descriptor.json`
   (≥ csp-8) → app templates / lock files → module versions.
2. **schema-diff** — calls `reusable-schema-changes.yml` for each module
   in parallel (dynamic matrix from `modules.json`).
3. **collect-reports** — downloads per-module Markdown reports, combines
   them into a single timestamped HTML artifact, then cleans up
   intermediate artifacts.

### Submodule filtering

Some modules share submodules (e.g. `ramls/acq-models`) that contain
schemas for many different modules. The report builder traces `$ref` and
`!include` references from the parent repo's schemas into the submodule,
then performs a BFS to find all transitively referenced files. Only
changes relevant to the current module appear in its report section.

---

## Tracked modules

The module list is defined in a single config file —
`.github/config/modules.json`:

```json
{
  "modules": [
    "mod-inventory-storage",
    "mod-users",
    "mod-inventory",
    "mod-orders-storage",
    "mod-invoice-storage",
    "mod-finance-storage",
    "mod-organizations-storage",
    "mod-circulation-storage",
    "mod-source-record-storage"
  ]
}
```

Adding or removing a module is a one-line edit in this file — no YAML or
script changes required.

### Selection criterion

A module is tracked only if it **owns a database that persists the entities
its JSON schemas describe**, and those schemas are diffable JSON. Concretely:

- **RMB modules** — `ramls/**/*.json` mapped to DB tables via
  `src/main/resources/templates/db_scripts/schema.json`.
- **Spring modules** — Liquibase/Flyway-managed tables plus JSON schemas
  under `src/main/resources/**`.

## Out of scope

The following module classes are intentionally **excluded** — a schema change
in them does not represent a change to persisted data this tool is meant to
track:

| Category | Why excluded | Examples |
|---|---|---|
| BL / proxy / BFF | No own DB; entities persist in the paired `*-storage` module | `mod-circulation-bff`, `mod-rtac`, `mod-user-import`, `mod-inventory-import` |
| Edge / gateway | Stateless; expose external APIs | `mod-ebsconet`, `mod-okapi-facade` |
| Search / reporting / external-DB | Index (ES) or query external stores; don't own the schema entities | `mod-search`, `mod-reporting`, `mod-ldp`, `mod-reservoir`, `mod-meta-storage` |
| OpenAPI-YAML-only / data-only | Persist data but define APIs as YAML, or ship only reference/sample/DB-changelog JSON — nothing for the JSON differ | `mod-locations`, `mod-notes`, `mod-tags`, `mod-consortia`, `mod-quick-marc`, `mod-licenses`, `mod-serials-management`, `mod-marc-migrations`, `mod-record-specifications`, `mod-linked-data-import` |
| YAML + root submodule | Reference a root-level shared submodule (`folio-export-common`) from OpenAPI YAML; the submodule BFS (seeded from `ramls/`) cannot scope changes to the module | `mod-data-export-spring`, `mod-data-export-worker` |
| Stateless / config / orchestration | No persisted schema entities | `mod-authtoken`, `mod-settings`, `mod-sender`, `mod-camunda`, `mod-workflow`, `mod-calendar` |

> Modules that persist data but publish their API as **OpenAPI YAML** (not
> JSON Schema) are excluded only because the differ is JSON-based. They could
> be re-included if YAML diffing is added.

---

## Usage

### Auto-detect latest releases

1. Go to **Actions** → **Run Schema Changes Reporting** → **Run workflow**.
2. Leave both fields empty.
3. Click **Run workflow**.

The two most recent `platform-lsp` tags (by creation date) are used
automatically.

### Specify releases manually

1. Go to **Actions** → **Run Schema Changes Reporting** → **Run workflow**.
2. Fill in both fields:

| Field | Example | Description |
|---|---|---|
| **base** | `R1-2025-csp-4` | Earlier release (before) |
| **head** | `R1-2025-csp-5` | Later release (after) |

3. Click **Run workflow**.

> **Both fields must be filled or both left empty.**
> Partial input (only one field) will fail with an error.

### Download the report

1. Open the completed workflow run.
2. Scroll to **Artifacts**.
3. Download `report_<timestamp>` — contains a self-contained HTML file
   and the raw Markdown source.

---

## Module-level usage

The reusable workflow can also be triggered independently from a module
repo, without going through central reporting.

### On push / pull request

The workflow runs automatically when `ramls/**/*.json` (or other
configured paths) change. On a pull request a sticky comment with the
diff report is posted. On push the report is available in the **Actions**
summary and as an artifact.

### On release

Triggered automatically when a release is published. Compares the new
release tag against the previous one.

### Manual run (workflow_dispatch)

1. Go to the module repo → **Actions** → **Schema changes** → **Run workflow**.
2. Optionally fill in **base** and **head** (any tag, branch, or commit SHA).
3. Leave both empty to compare the two most recent tags automatically.
4. Click **Run workflow**.

---

## Architecture

```
central-reporting.yml
│
├─ resolve_tags (ubuntu-latest)
│   ├─ clone platform-lsp (blob-less)
│   ├─ list tags sorted by creation date
│   ├─ select HEAD/BASE releases (manual or auto)
│   ├─ parse install-applications.json / platform-descriptor.json per release
│   ├─ fetch app manifests (<app>.template.json or application.lock.json)
│   ├─ extract module versions (e.g. mod-users v19.5.4 → tag v19.5.4)
│   └─ output: modules JSON matrix [{name, base, head, base_app, head_app}]
│
├─ schema-diff (matrix: each module in parallel)
│   ├─ checkout target module repo (full history + submodules, blob:none)
│   ├─ checkout workflow scripts (.schema-changes-reporting/)
│   ├─ refs-resolver.sh → determine BASE/HEAD refs
│   ├─ report-builder.sh → diff schemas + submodule schemas (filtered)
│   └─ upload report.md artifact
│
└─ collect-reports (ubuntu-latest)
    ├─ download report-* artifacts
    ├─ reports-combiner.sh → merge into MD + HTML (pandoc)
    ├─ artifacts-cleaner.sh → delete per-module artifacts
    └─ upload report_<timestamp>.{md,html}
```

### Repository layout

```
folio-org/schema-changes-reporting
├─ .github/
│  ├─ config/
│  │  └─ modules.json                      ← module list (one-line edits)
│  ├─ scripts/
│  │  ├─ lib/
│  │  │  └─ helpers.sh                     ← shared functions
│  │  ├─ releases-resolver.sh              ← resolve module versions from platform-lsp
│  │  ├─ refs-resolver.sh                  ← determine BASE/HEAD git refs
│  │  ├─ report-builder.sh                 ← build schema diff report (main logic)
│  │  ├─ reports-combiner.sh               ← merge per-module reports into HTML
│  │  └─ artifacts-cleaner.sh              ← delete intermediate artifacts
│  ├─ tests/
│  │  ├─ helpers.bats                      ← unit tests for helpers.sh
│  │  ├─ refs-resolver.bats                ← unit tests for refs-resolver.sh
│  │  ├─ report-builder.bats               ← unit tests for report-builder.sh
│  │  └─ reports-combiner.bats             ← unit tests for reports-combiner.sh
│  └─ workflows/
│     ├─ central-reporting.yml             ← orchestrator workflow
│     └─ reusable-schema-changes.yml       ← reusable diff workflow
├─ run-tests.sh                            ← local test runner
└─ README.md
```

### Reusable workflow

All diff logic lives in `reusable-schema-changes.yml` in **this
repository**. `central-reporting.yml` calls it via a dynamic matrix —
**no workflow file is required in the module repo** for central reporting.

Module repos only need a thin caller workflow for **local triggers**
(push, pull request, release, manual dispatch):

```
folio-org/mod-users
  └─ .github/workflows/schema-changes-reporting.yml  ← thin caller
```

---

## Adding a new module

### Step 1 — Edit `modules.json` (required for central reporting)

Add the module name to `.github/config/modules.json`:

```json
{
  "modules": [
    "mod-inventory-storage",
    "mod-users",
    ...
    "mod-new-module"
  ]
}
```

That's it — after merging, the next central reporting run will include
the new module automatically.

### Step 2 — Add a caller workflow in the module repo (optional)

Skip this step if you only need the module in combined reports.

Create `.github/workflows/schema-changes-reporting.yml` in the module repo:

```yaml
name: Schema changes (mod-new-module)

on:
  push:
    branches: ["**"]
    paths:
      - "ramls/**/*.json"
      - "!ramls/examples/**"
      - "!ramls/raml-util/**"
  pull_request:
    branches: ["**"]
    paths:
      - "ramls/**/*.json"
      - "!ramls/examples/**"
      - "!ramls/raml-util/**"
  release:
    types: [published]
  workflow_dispatch:
    inputs:
      base:
        description: "Optional base ref (tag/commit)"
        required: false
      head:
        description: "Optional head ref (tag/commit)"
        required: false

permissions:
  contents: read
  pull-requests: write

jobs:
  schema-changes:
    uses: folio-org/schema-changes-reporting/.github/workflows/reusable-schema-changes.yml@master
    with:
      repository: ${{ github.repository }}
      base: ${{ github.event.inputs.base || '' }}
      head: ${{ github.event.inputs.head || '' }}
    permissions:
      contents: read
      pull-requests: write
```

---

## Scripts

| Script | Purpose |
|---|---|
| `releases-resolver.sh` | Clones `platform-lsp`, resolves module versions for two releases, outputs a JSON matrix |
| `refs-resolver.sh` | Determines BASE/HEAD git refs based on event type (push, PR, release, dispatch) |
| `report-builder.sh` | Diffs `ramls/**/*.json` between two refs, handles submodules with per-module filtering |
| `reports-combiner.sh` | Merges per-module `report.md` files into a single MD + self-contained HTML via pandoc |
| `artifacts-cleaner.sh` | Deletes intermediate `report-*` artifacts after the combined report is built |
| `lib/helpers.sh` | Shared functions: `truncate_or_all`, `status_label`, `resolve_path`, `extract_json_refs`, `extract_raml_includes`, `is_path_in_submodule`, `strip_sm_prefix` |

---

## Testing

Unit tests use [bats-core](https://github.com/bats-core/bats-core). Each
script has a corresponding `.bats` file in `.github/tests/`.

### Prerequisites

```bash
brew install bats-core bash jq python3
```

### Running tests

```bash
# Run all tests
./run-tests.sh

# Run tests for a specific script
./run-tests.sh helpers
./run-tests.sh refs-resolver
./run-tests.sh report-builder
./run-tests.sh reports-combiner
```

> **Note:** bash 4+ is required (for `mapfile`). On macOS the runner
> auto-detects Homebrew bash if the system bash is too old.

---

## Inputs (reusable workflow)

| Input | Required | Default | Description |
|---|---|---|---|
| `base` | No | *(auto-detected)* | Base ref (tag, branch, or SHA) |
| `head` | No | *(auto-detected)* | Head ref (tag, branch, or SHA) |
| `repository` | No | `github.repository` | Target module repo (e.g. `folio-org/mod-users`) |
| `artifact_name` | No | auto-generated | Name for the uploaded report artifact |
| `schema_paths` | No | *(empty)* | Extra pathspec globs for JSON schemas (space-separated) |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Release tag 'X' not found` | Typo in manual input | Check available tags in `platform-lsp` |
| `Specify both base and head` | Only one field filled | Fill both or leave both empty |
| `No report artifacts found` | All module workflows failed | Check individual module job logs |
| Module not in report | Module not in any `platform-lsp` app template | Verify module name matches what appears in app templates |
| Submodule shows unrelated schemas | `$ref` tracing didn't find references | Check that parent schemas properly reference submodule files |
| `bash 4+ required` | macOS ships bash 3.x | `brew install bash` |

---

## Permissions

Declared in workflow files — no manual configuration needed.

| Workflow | `contents` | `pull-requests` | `actions` |
|---|---|---|---|
| `central-reporting.yml` | read | write | write |
| `reusable-schema-changes.yml` | read | write | — |

Module jobs receive `secrets: inherit` so that `GITHUB_TOKEN` is
forwarded for repository checkout, artifact upload, and PR comments.
