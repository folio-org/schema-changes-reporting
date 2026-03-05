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
                              diff ramls/*.json between base and head tags
```

The workflow:

1. **resolve_tags** — clones `platform-lsp`, determines two release tags,
   walks `install-applications.json` → app templates → module versions.
2. **call-mod-**\* — calls each module's `schema-changes-reporting.yml`
   with resolved `base`/`head` tags (runs in parallel).
3. **collect-reports** — downloads individual HTML reports, merges them
   into a single `combined-report.html` artifact.

---

## Usage

### Auto-detect latest releases

1. Go to **Actions** → **Run Remote Reporting** → **Run workflow**.
2. Leave both fields empty.
3. Click **Run workflow**.

The two most recent `platform-lsp` tags (by creation date) are used
automatically.

### Specify releases manually

1. Go to **Actions** → **Run Remote Reporting** → **Run workflow**.
2. Fill in both fields:

| Field    | Example          | Description              |
| -------- | ---------------- | ------------------------ |
| **base** | `R1-2025-csp-4`  | Earlier release (before) |
| **head** | `R1-2025-csp-5`  | Later release (after)    |

3. Click **Run workflow**.

> **Both fields must be filled or both left empty.**
> Partial input (only one) will fail with an error.

### Download the report

1. Open the completed workflow run.
2. Scroll to **Artifacts**.
3. Download **combined-report** (single HTML file).

Individual module reports are also available as `report-mod-*` artifacts.

---

## Inputs

| Input  | Required | Default                | Description                        |
| ------ | -------- | ---------------------- | ---------------------------------- |
| `base` | No       | *(auto: previous tag)* | BASE release tag in `platform-lsp` |
| `head` | No       | *(auto: latest tag)*   | HEAD release tag in `platform-lsp` |

---

## Outputs / Artifacts

| Artifact                       | Contents                           |
| ------------------------------ | ---------------------------------- |
| `combined-report`              | Merged HTML report for all modules |
| `report-mod-inventory-storage` | Individual report (MD + HTML)      |
| `report-mod-users`             | Individual report (MD + HTML)      |

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
├─ call-mod-inventory-storage ──┐
│   (parallel)                  ├─ collect-reports
├─ call-mod-users ──────────────┘
│
└─ collect-reports (ubuntu-latest)
    ├─ download report-* artifacts
    ├─ merge HTML files
    └─ upload combined-report
```

---

## Adding a new module

1. **Create** `schema-changes-reporting.yml` in the new module repo
   (copy from `mod-users` or `mod-inventory-storage`).

2. **Edit `central-reporting.yml`:**

   a. Add outputs in `resolve_tags`:

   ```yaml
   outputs:
     # ... existing outputs ...
     mod_new_module_base: ${{ steps.resolve.outputs.mod_new_module_base }}
     mod_new_module_head: ${{ steps.resolve.outputs.mod_new_module_head }}
   ```

   b. Add module name to `TARGET_MODULES` array:

   ```bash
   TARGET_MODULES=("mod-inventory-storage" "mod-users" "mod-new-module")
   ```

   c. Add a call job:

   ```yaml
   call-mod-new-module:
     needs: [resolve_tags]
     uses: folio-org/mod-new-module/.github/workflows/schema-changes-reporting.yml@master
     with:
       base: ${{ needs.resolve_tags.outputs.mod_new_module_base }}
       head: ${{ needs.resolve_tags.outputs.mod_new_module_head }}
       repository: folio-org/mod-new-module
       artifact_name: report-mod-new-module
     secrets: inherit
   ```

   d. Add the new job to `collect-reports` needs:

   ```yaml
   collect-reports:
     needs: [call-mod-inventory-storage, call-mod-users, call-mod-new-module]
   ```

---

## Module workflow requirements

Each module's `schema-changes-reporting.yml` must accept these
`workflow_call` inputs:

```yaml
on:
  workflow_call:
    inputs:
      base:
        required: false
        type: string
      head:
        required: false
        type: string
      repository:
        required: false
        type: string
      artifact_name:
        required: false
        type: string
```

The module workflow must read inputs using the `inputs` context directly
(not `github.event.inputs`) to work correctly when called from a
`workflow_dispatch` caller:

```bash
BASE_IN="${{ inputs.base || '' }}"
HEAD_IN="${{ inputs.head || '' }}"
```

---

## Troubleshooting

| Symptom                                                | Cause                                                  | Fix                                                        |
| ------------------------------------------------------ | ------------------------------------------------------ | ---------------------------------------------------------- |
| Module uses its own latest tags instead of passed ones | Module reads `github.event.inputs` instead of `inputs` | Change to `inputs.base` / `inputs.head` in module workflow |
| `Release tag 'X' not found`                            | Typo in manual input                                   | Check available tags in `platform-lsp`                     |
| `Specify both base and head`                           | Only one field filled                                  | Fill both or leave both empty                              |
| `No report artifacts found`                            | Module workflow failed                                 | Check individual module job logs                           |
| Wrong PREV_TAG with same-date tags                     | Sorting by date doesn't differentiate                  | Module workflows use `--sort=-version:refname`             |

---

## Permissions

```yaml
permissions:
  contents: read        # clone repos, fetch templates
  pull-requests: write  # PR comments (module workflows)
```

`secrets: inherit` passes `GITHUB_TOKEN` to module workflows for
repository access and artifact upload.