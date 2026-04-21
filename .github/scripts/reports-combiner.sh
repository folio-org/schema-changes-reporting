#!/usr/bin/env bash
# Combines per-module report.md artifacts into a single HTML + MD.
#
# Inputs (env):
#   REPORTS_DIR          - dir containing per-module report.md (default: reports)
#   TIMESTAMP            - timestamp string used in output filenames (required)
#
# Output files:
#   report_<TIMESTAMP>.md
#   report_<TIMESTAMP>.html

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPORTS_DIR="${REPORTS_DIR:-reports}"
TIMESTAMP="${TIMESTAMP:?TIMESTAMP is required}"

MD_OUT="report_${TIMESTAMP}.md"
HTML_OUT="report_${TIMESTAMP}.html"

# ── Build combined Markdown (flat, for artifact) ─────────────────────────
{
  echo "# Schema Changes Report"
  echo ""
  while IFS= read -r md; do
    section_title="$(basename "$(dirname "$md")")"
    echo "---"
    echo "## ${section_title}"
    echo ""
    cat "$md"
    echo ""
  done < <(find "$REPORTS_DIR" -type f -name 'report.md' | sort)
} > "$MD_OUT"

# ── Build HTML with collapsible sections ─────────────────────────────────
CSS_FILE="$SCRIPT_DIR/css/report-style.css"
[[ -f "$CSS_FILE" ]] || { echo "::error::Missing $CSS_FILE"; exit 1; }

cat > "$HTML_OUT" <<HTML_HEAD
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Schema Changes Report</title>
<style>
$(cat "$CSS_FILE")
</style>
</head>
<body>
<h1>Schema Changes Report</h1>
<div class="controls">
  <button onclick="document.querySelectorAll('details').forEach(d=>d.open=true)">Expand all</button>
  <button onclick="document.querySelectorAll('details').forEach(d=>d.open=false)">Collapse all</button>
</div>
HTML_HEAD

# wrap_schema_details: wraps <h3>Schema changes…</h3> sections in <details>
wrap_schema_details() {
  python3 -c '
import sys, re

html = sys.stdin.read()
# Split on <h3> tags that start with "Schema changes"
parts = re.split(r"(<h3[^>]*>Schema changes)", html)
result = []
for i, part in enumerate(parts):
    if re.match(r"<h3[^>]*>Schema changes", part):
        # Find the title text up to </h3>
        rest = parts[i + 1] if i + 1 < len(parts) else ""
        m = re.match(r"(.*?</h3>)(.*)", rest, re.DOTALL)
        if m:
            title_rest, body = m.group(1), m.group(2)
            full_title = re.sub(r"<[^>]+>", "", part + title_rest).strip()
            result.append(f"<details><summary>{full_title}</summary><div class=\"section-body\">{body}</div></details>")
            parts[i + 1] = ""  # consumed
        else:
            result.append(part)
    else:
        result.append(part)
print("".join(result))
'
}

# Convert each module section separately and wrap in <details>
while IFS= read -r md; do
  section_title="$(basename "$(dirname "$md")")"
  section_html="$(pandoc --from=gfm --to=html5 < "$md" | wrap_schema_details)"

  cat >> "$HTML_OUT" <<SECTION
<details open>
  <summary>${section_title}</summary>
  <div class="section-body">
${section_html}
  </div>
</details>
SECTION
done < <(find "$REPORTS_DIR" -type f -name 'report.md' | sort)

cat >> "$HTML_OUT" <<'HTML_TAIL'
</body>
</html>
HTML_TAIL

echo "✓ Built $HTML_OUT"

