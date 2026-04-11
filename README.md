# Central Reporting — Schema Changes Across Releases

Compares JSON schemas between two `platform-lsp` releases and produces
a combined HTML report showing structural changes in module schemas.

---

## How it works

```
platform-lsp tag (e.g. R1-2025-csp-5)
  └─ install-applications.json
       └─ app-platform-minimal-2.0.49
            └─ app-platform-minimal.template.json
                 └─ modules: [ { "name": "mod-users", "version": "19.5.4" } ]
                                         ↓
                              tag v19.5.4 in folio-org/mod-users
                                         ↓
                              diff ramls/**/*.json between base and head tags
```

The workflow:

1. **resolve_tags** — clones `platform-lsp`, determines two release tags,
   walks `install-applications.json` → app templates → module versions.
2. **mod-\*** — calls the reusable `reusable-schema-changes.yml` (hosted in
   **this** repo) for each module with resolved `base`/`head` tags (runs in
   parallel).
3. **collect-reports** — downloads individual HTML reports, merges them
   into a single `combined-report.html` artifact.

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
| --- | --- | --- |
| **base** | `R1-2025-csp-4` | Earlier release (before) |
| **head** | `R1-2025-csp-5` | Later release (after) |

3. Click **Run workflow**.

> **Both fields must be filled or both left empty.**
> Partial input (only one field) will fail with an error.

### Download the report

1. Open the completed workflow run.
2. Scroll to **Artifacts**.
3. Download **combined-report** (single HTML file).

Individual module reports are also available as `report-mod-*` artifacts.

---

## Module-level usage

Each module's caller workflow also triggers independently — without going
through central reporting. This is useful for reviewing schema changes
during day-to-day development.

### On push / pull request

The workflow runs automatically when `ramls/**/*.json` (or other configured paths in `/.github/workflows/schema-changes-reporting.yml`) files change.
On a pull request a sticky comment with the diff report is posted.
On push the report is available in the **Actions** summary and as an artifact.

### On release

Triggered automatically when a release is published. Compares the new
release tag against the previous one.

### Manual run (workflow_dispatch)

1. Go to the module repo → **Actions** → **Schema changes** → **Run workflow**.
2. Optionally fill in **base** and **head** (any tag, branch, or commit SHA).
3. Leave both empty to compare the two most recent tags automatically.
4. Click **Run workflow**.

### Artifacts

Each run uploads two files:

| File | Description |
| --- | --- |
| `report.md` | Raw Markdown diff |
| `report.html` | Self-contained HTML report (open in browser) |

Download them from the **Artifacts** section of the completed run.

---

## Inputs

| Input | Required | Default | Description |
| --- | --- | --- | --- |
| `base` | No | *(auto: previous tag)* | BASE release tag in `platform-lsp` |
| `head` | No | *(auto: latest tag)* | HEAD release tag in `platform-lsp` |

---

## Outputs / Artifacts

| Artifact | Contents |
| --- | --- |
| `combined-report` | Merged HTML report for all modules |
| `report-mod-inventory-storage` | Individual report (MD + HTML) |
| `report-mod-users` | Individual report (MD + HTML) |
| `report-mod-inventory` | Individual report (MD + HTML) |

---

## Architecture

```
central-reporting.yml
│
├─ resolve_tags (ubuntu-latest)
│   ├─ clone platform-lsp
│   ├─ list tags sorted by creation date
│   ├─ select HEAD/BASE releases (manual or auto)
│   ├─ parse install-applications.json for each release
│   ├─ fetch app-*.template.json for each application
│   ├─ extract module versions (e.g. mod-users v19.5.4 → tag v19.5.4)
│   └─ output: mod_*_base, mod_*_head
│
├─ mod-inventory-storage ──┐
│   (parallel)              ├─ collect-reports
├─ mod-users ───────────────┤
├─ mod-inventory ───────────┘
│
└─ collect-reports (ubuntu-latest)
    ├─ download report-* artifacts
    ├─ merge HTML files
    └─ upload combined-report
```

### Reusable workflow

All diff logic lives in a single place —
`.github/workflows/reusable-schema-changes.yml` in **this repository**.

`central-reporting.yml` calls it directly — **no workflow file is required
in the module repo** for central reporting to work.

Module repos contain only a thin caller workflow that is used for **local
triggers** (push, pull request, release, manual dispatch):

```
folio-org/schema-changes-reporting
  ├─ .github/workflows/reusable-schema-changes.yml  ← all diff logic (reusable)
  └─ .github/workflows/central-reporting.yml        ← orchestrator

folio-org/mod-users
  └─ .github/workflows/schema-changes-reporting.yml ← thin caller (local triggers only)

folio-org/mod-inventory-storage
  └─ .github/workflows/schema-changes-reporting.yml ← thin caller (local triggers only)

folio-org/mod-inventory
  └─ .github/workflows/schema-changes-reporting.yml ← thin caller (local triggers only)
```

> **Central reporting vs local actions:**
>
> - **Central reporting** (`central-reporting.yml`) resolves module versions
>   from `platform-lsp` and calls `reusable-schema-changes.yml` directly —
>   no changes needed in the module repo.
> - **Local actions** (push diffs, PR comments, release comparisons, manual
>   dispatch from the module repo) require a thin caller workflow to be
>   present in that module repo.

---

## Adding a new module

Adding a module to central reporting **does not require any changes in the
module repo**. Editing `central-reporting.yml` alone is sufficient for the
module to appear in combined reports.

A caller workflow in the module repo is only needed if you also want
**local actions** (per-commit diffs, PR comments, release comparisons,
manual runs from that repo).

### Step 1 — Edit `central-reporting.yml` (required for central reporting)

**a.** Add outputs in `resolve_tags`:

```yaml
outputs:
  # ... existing outputs ...
  mod_new_module_base: ${{ steps.resolve.outputs.mod_new_module_base }}
  mod_new_module_head: ${{ steps.resolve.outputs.mod_new_module_head }}
  mod_new_module_base_app: ${{ steps.resolve.outputs.mod_new_module_base_app }}
  mod_new_module_head_app: ${{ steps.resolve.outputs.mod_new_module_head_app }}
```

**b.** Add module name to `TARGET_MODULES` array:

```bash
TARGET_MODULES=("mod-inventory-storage" "mod-users" "mod-inventory" "mod-new-module")
```

**c.** Add a job that calls the reusable workflow:

```yaml
mod-new-module:
  needs: [resolve_tags]
  uses: ./.github/workflows/reusable-schema-changes.yml
  with:
    base: ${{ needs.resolve_tags.outputs.mod_new_module_base }}
    head: ${{ needs.resolve_tags.outputs.mod_new_module_head }}
    repository: folio-org/mod-new-module
    artifact_name: report-mod-new-module
  secrets: inherit
```

**d.** Add the new job to `collect-reports` needs:

```yaml
collect-reports:
  needs: [mod-inventory-storage, mod-users, mod-inventory, mod-new-module]
```

That's it — after merging, the next central reporting run will include
`mod-new-module` automatically.

---

### Step 2 — Add a caller workflow in the module repo (optional, for local actions)

Skip this step if you only need the module in combined reports.

Create `.github/workflows/schema-changes-reporting.yml` in the module repo
(adjust `name` and `paths` if schemas are not in `ramls/`):

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

> The caller references `reusable-schema-changes.yml` (not
> `schema-changes-reporting.yml`).  All diff logic is maintained in this
> single file — all modules pick up fixes automatically.

---

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Module uses its own latest tags instead of passed ones | Module reads `github.event.inputs` instead of `inputs` | Ensure caller passes `base`/`head` via `with:`, reusable reads `inputs.*` |
| `Release tag 'X' not found` | Typo in manual input | Check available tags in `platform-lsp` |
| `Specify both base and head` | Only one field filled | Fill both or leave both empty |
| `No report artifacts found` | Module workflow failed | Check individual module job logs |
| Wrong PREV_TAG with same-date tags | Sorting by date doesn't differentiate | Reusable workflow uses `--sort=-version:refname` |
| Module not found in any application | Module not listed in `platform-lsp` install manifests | Verify module name matches exactly what appears in app templates |

---

## Permissions

Permissions are already declared in the workflow files — no manual configuration needed.

**`central-reporting.yml`** declares at the top level:

```yaml
permissions:
  contents: read   # clone platform-lsp, fetch app templates
  pull-requests: write
```

Each module job passes `secrets: inherit` so that `GITHUB_TOKEN` is
forwarded to `reusable-schema-changes.yml` for repository checkout and
artifact upload.

**`reusable-schema-changes.yml`** declares:

```yaml
permissions:
  contents: read        # checkout module repo, read tags
  pull-requests: write  # post sticky PR comment with diff report
```

**Module caller workflows** (thin callers in module repos) should declare
the same permissions so that local triggers (push, PR, release) work
correctly:

```yaml
permissions:
  contents: read
  pull-requests: write
```

