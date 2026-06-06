# Release & Deployment Dashboard

A self-contained GitHub Pages dashboard that shows **Jira tickets grouped by release tag and
release branch**, driven entirely by one structured data file. It is built for a
**numbered-hotfix-over-a-release-window** model: you cut a release branch, then cut a series of
incrementing tags (hotfixes), and the dashboard accumulates every tag under its release line.

```
26.7.x  ─┬─ 26.7.0   (initial cut)
         ├─ 26.7.1   (hotfix)
         ├─ 26.7.2   (hotfix)
         └─ 26.7.3   (hotfix)
26.8.x  ─┬─ 26.8.0
         └─ …
```

Tickets are associated with a tag through a **Jira custom field, `customfield_10104`** (a
free-form, multi-value "labels" field). A ticket carrying `["26.7.0", "26.7.1"]` belongs to
both tags — that is how *carry-over* across hotfixes is represented.

---

## Repository layout

| Path | Purpose |
|------|---------|
| `.github/workflows/jira-loading.yml` | **The pipeline.** Fetches Jira data for one tag, builds `releases.json`, commits it, deploys Pages. |
| `scripts/build-release-data.sh` | The generator the workflow runs. Also runnable locally. Fetches `customfield_10104` tickets, enriches them, merges into `releases.json`. |
| `scripts/seed-test-data.sh` | One-off helper to seed demo epics/stories into the POC Jira (sandbox only). |
| `docs/index.html` | The dashboard. Static HTML/JS, no build step. Reads `data/releases.json`. |
| `docs/data/releases.json` | The single source of truth the dashboard renders. Generated; accumulates one block per tag. |

> **`docs/data/releases.json` and `docs/index.html` are owned exclusively by `jira-loading.yml`.**
> No other workflow writes them (the previous `Auto Tag from Sprint Branch.yml` steps that did
> were removed). Keeping a single writer prevents conflicting/overwriting commits.

---

## How `jira-loading.yml` works

### Trigger
Manual — **`workflow_dispatch`** with a single input:

| Input | Example | Meaning |
|-------|---------|---------|
| `fix_version` | `26.7.1` | The release **tag** to fetch. The release branch (`26.7.x`) is derived from it. |

The model is **per-tag, accumulating**: you run it once per tag you cut. Running `26.7.0`,
then later `26.7.1`, then `26.7.2` adds/refreshes each block in `releases.json` without losing
the others. Re-running the same tag replaces only that tag's block (idempotent).

### Job: `build-and-deploy` (one job, runs on `ubuntu-latest`)

1. **Checkout** the repository.
2. **Build structured release data** — runs `scripts/build-release-data.sh "$fix_version"`,
   which writes/updates `docs/data/releases.json` (see the generator section below).
3. **Commit** `docs/data/releases.json` and `docs/index.html` back to the branch (only if
   something changed). Committed by `github-actions[bot]`.
4. **Configure / Upload / Deploy Pages** — publishes the entire `docs/` folder to GitHub Pages
   via the official `configure-pages` → `upload-pages-artifact` → `deploy-pages` actions.

So **one dispatch = fetch → structured data → commit → deploy.**

### Credentials
Pulled from repository **secrets**, with a **fallback baked into the script** for the POC:

```yaml
env:
  JIRA_BASE_URL:  ${{ secrets.JIRA_BASE_URL }}
  JIRA_EMAIL:     ${{ secrets.JIRA_EMAIL }}
  JIRA_API_TOKEN: ${{ secrets.JIRA_API_TOKEN }}
```

If a secret is unset/empty, `build-release-data.sh` falls back to its hardcoded POC values
(`${VAR:-default}`), so the workflow runs out-of-the-box against the sandbox and silently
switches to secrets once they are configured. **For any real instance, set the three secrets
and rotate the hardcoded POC token out.**

### Permissions & concurrency
```yaml
permissions:
  contents: write   # commit releases.json
  pages: write      # deploy Pages
  id-token: write   # required by deploy-pages
concurrency:
  group: jira-release-dashboard   # prevents overlapping deploys
```

---

## The generator: `scripts/build-release-data.sh`

```bash
./scripts/build-release-data.sh 26.7.1     # defaults to 26.7.0 if omitted
```

Step by step:

1. **Resolve config** — base URL / email / token from env or POC fallback. Build a Basic-auth
   header (`base64 | tr -d '\n'` — portable across macOS/Linux; the Linux-only `base64 -w0`
   is avoided).
2. **Derive the branch** from the tag: `26.7.1` → strip the last numeric segment → `26.7.x`.
3. **Query Jira** at `POST /rest/api/3/search/jql` with
   `jql = cf[10104] = "<tag>"`, requesting these fields:
   `key, summary, status, issuetype, priority, assignee, parent, labels, components, reporter,
   created, updated, resolutiondate, customfield_10104`.
   Pagination uses **`nextPageToken`** (the current Jira Cloud search API; `startAt` is gone),
   100 issues per page.
4. **Empty-result guard** — if the tag matches **0 tickets**, it prints a diagnostic sample of
   recent `cf[10104]` values and **exits without touching `releases.json`** (so a typo'd tag
   never writes a bogus empty block).
5. **Transform** each issue into the per-ticket shape (below). Epic = the Jira **`parent`**,
   but only when the parent is itself an `Epic` issue type.
6. **Roll up** the per-release `summary` (status breakdown, unassigned/carry-over counts,
   distinct assignees, epic count) and `tickets_done`.
7. **Merge idempotently** into `docs/data/releases.json`:
   - drop any existing entry with the **same tag** (so re-runs refresh, not duplicate);
   - **drop malformed legacy entries** whose `tickets` isn't an array (self-heal);
   - add the new entry; sort all releases by version **descending**;
   - recompute the top-level rollups.

---

## Data model: `docs/data/releases.json`

```jsonc
{
  "generatedAt": "2026-06-06T04:47:47Z",   // UTC, when the file was last written
  "totalReleases": 5,                       // number of tag blocks across all lines
  "totalTickets": 31,                       // sum of ticket_count over all blocks
  "totalDone": 7,                           // sum of tickets_done over all blocks
  "totalEpics": 5,                          // distinct epics across all blocks
  "branches": ["26.7.x", "26.8.x"],         // distinct release lines
  "releases": [
    {
      "tag": "26.7.0",                      // the release tag (the cf[10104] value)
      "branch": "26.7.x",                   // release line, derived from the tag
      "date": "2026-06-06T04:47:47Z",       // when this block was last generated
      "ticket_count": 12,                   // tickets carrying this tag
      "tickets_done": 4,                    // of those, in a "done" status category
      "summary": {
        "byStatus":   { "To Do": 7, "In Progress": 1, "Done": 4 },
        "unassigned": 3,                    // tickets with no assignee
        "carriedOver":2,                    // tickets that also carry another tag
        "assignees":  ["Nikitha KN"],       // distinct named assignees
        "epicCount":  2                     // distinct epics in this tag
      },
      "tickets": [ /* see per-ticket shape */ ],
      "epics":   [ { "epic": "KAN-4", "title": "Test Epic" } ]   // deduped epics in this tag
    }
  ]
}
```

**Per-ticket shape:**

```jsonc
{
  "id":         "KAN-1",                 // issue key
  "summary":    "TEST-123",              // title
  "status":     "Done",                  // human status name
  "statusCategory": "done",              // new | indeterminate | done (drives colors/segments)
  "type":       "Story",                 // issue type
  "priority":   "Medium",                // Highest..Lowest
  "assignee":   "Nikitha KN",            // or "Unassigned"
  "reporter":   "Nikitha KN",
  "epic":       "KAN-4",                 // parent epic key, or null
  "epicTitle":  "Test Epic",             // parent epic summary, or null
  "labels":     ["backend"],
  "components": [],
  "created":    "2026-04-18T11:24:15.679+0530",
  "updated":    "2026-05-30T20:58:19.861+0530",
  "resolved":   "2026-04-23T15:20:26.566+0530",   // or null
  "tags":       ["26.7.0", "26.7.1"],    // ALL cf[10104] values on the ticket
  "carriedOver": true,                   // tags.length > 1
  "link":       "https://…/browse/KAN-1"
}
```

---

## What the dashboard shows (`docs/index.html`)

The dashboard is **scoped to one release line at a time**, chosen from a dropdown, and defaults
to the **latest** line on load.

### Release-line selector
- A dropdown lists every release line (`26.8.x`, `26.7.x`, …), newest first.
- **Defaults to the latest line.** Selecting a line re-scopes *everything* — KPIs, charts,
  filters, and the release list — and resets the filters.
- The selection is stored in the URL hash (`#26.7.x`) so a line is shareable/deep-linkable.

### KPI cards (scoped to the selected line, except the first)
| Card | Meaning |
|------|---------|
| **Release Lines** | Total number of release lines in the data (global — answers "how many releases exist"). |
| **Hotfix Tags** | Tags in the selected line. |
| **Tickets** | Tickets in the selected line. |
| **% Done** | Share of those tickets in a "done" status category. |
| **In Progress** | Tickets in an "indeterminate" status category. |
| **Unassigned** | Tickets with no assignee. |
| **Epics** | Distinct epics touched in the selected line. |
| **High-Prio Open** | High/Highest-priority tickets **not** done (red — a risk signal). |

### Charts (Chart.js, scoped to the selected line)
1. **Tickets by status** — doughnut (Done / In Progress / To Do), counts in the legend.
2. **Tickets by priority** — doughnut, Highest→Lowest.
3. **Tickets by hotfix tag** — stacked bar across the line's tags, segmented by status.
4. **Tickets by epic** — horizontal stacked bar (epic load + completion).
5. **Cumulative delivery across hotfix tags** — burn-up line of **distinct** tickets vs.
   distinct done, oldest→newest (de-duplicates carry-over so multi-tag tickets aren't
   double-counted).

### Release-line group & per-tag cards
- A parent **"Release 26.7"** group header shows the line-level rollup (tags, total tickets,
  % done) and an aggregate status bar.
- Nested under it, **one card per hotfix tag** (newest first), each with:
  - readiness badge (`done/total · %`), the tag's date, and **cadence** ("+Nd since 26.7.1",
    or "initial cut" for the first tag in the line);
  - a status bar and a meta row (to-do / in-progress / done / unassigned / **carried over** /
    high-prio open / contributors);
  - **epic chips** (link to Jira);
  - a **ticket table**: Key → Jira, Title (+ "carried over" flag + label chips), Type,
    Priority (high in red), color-coded Status, Assignee, Epic → Jira, Updated date.
    High-priority-open rows get a **red risk border**.

### Filters & actions
- **Search** (key/title/assignee/epic/label), and dropdowns for **status / assignee / epic /
  priority**, plus a **"Carried-over only"** toggle and **Reset**. A live "showing X of Y"
  count reflects the active filter.
- Per release: **Copy release notes (Markdown)** (for Confluence/Slack) and **Export CSV**
  (full ticket fields including labels, dates, carry-over, links).

### Resilience
- The page **fetches `data/releases.json` over HTTP** — opening `index.html` from `file://`
  blocks `fetch` (an explanatory message is shown). Use `python3 -m http.server` locally.
- On load it **normalizes** each release so missing/legacy `tickets`/`epics` are treated as
  empty arrays — a malformed legacy entry renders harmlessly instead of crashing the page.
- If the **Chart.js CDN** can't load, the charts section hides itself; KPIs and tables still work.

---

## Assumptions & considerations

**Jira / data model**
- `customfield_10104` ("fixVersions") is a **multi-value labels-type field**. A ticket may carry
  multiple tags; that is the mechanism for representing carry-over across hotfixes.
- **Epic = the Jira `parent`** (this is a *team-managed* project; there is no separate
  epic-link field). Only parents whose issue type is `Epic` are counted as epics.
- Tags are expected to be dotted numeric versions (`26.7.1`). Sorting/branch-derivation assume
  the form `<line>.<n>` where the trailing numeric segment is the hotfix number and the branch
  is `<line>.x`.
- "Done" is determined by Jira's **status category** (`done`), not the status name — so custom
  status names still classify correctly.
- The API token's account must have **read access** to the project, or tickets are silently
  excluded.

**Pipeline**
- The workflow is **manually triggered per tag**; it does not auto-discover tags. Cut a tag →
  run it with that `fix_version`.
- It assumes the runner can reach the Jira Cloud REST API and that **GitHub Pages is enabled
  with "Source: GitHub Actions"** (required for `deploy-pages`).
- `jira-loading.yml` is the **only** writer of `releases.json`/`index.html`. If you re-introduce
  another workflow that writes `docs/`, you risk conflicting commits.
- `pages.yml` (if present) only *deploys* `docs/` and does not alter these files. Note that both
  `jira-loading.yml` and `pages.yml` can deploy Pages — harmless but redundant.

**Scope (intentionally not included)**
- No commit/deployment/CI data — the dashboard is **Jira-only** today (those cards from the
  reference layout are omitted). They can be layered in later if that data is fed into the JSON.
- Confluence publishing is handled by separate workflows, not by `jira-loading.yml`.

---

## Local development

```bash
# 1. Generate / refresh data for a tag (uses POC fallback creds, or export your own)
export JIRA_BASE_URL=…  JIRA_EMAIL=…  JIRA_API_TOKEN=…   # optional; omit to use POC
./scripts/build-release-data.sh 26.7.0
./scripts/build-release-data.sh 26.7.1                   # accumulates

# 2. Serve the dashboard (fetch needs HTTP, not file://)
cd docs && python3 -m http.server 8765
# open http://localhost:8765/
```

Requirements: `bash`, `curl`, `jq`, `base64` (all present on `ubuntu-latest` and macOS).

> ⚠️ **Security:** the POC Jira token is hardcoded as a fallback in `scripts/build-release-data.sh`
> for the sandbox. Before using a real instance, replace it with repository secrets and **revoke
> the POC token**. Committing a live token places it in git history permanently.



Additional details that needs to be document here later: 

 What was implemented

  Concept: every ticket for a tag is now classified by where it appears:
  - Tagged + merged — in cf[10104] and in commits → on track.
  - Tagged · not merged — in cf[10104] only → work pending (risk).
  - Merged · fix version missing — in commits only → the dev forgot to set the field (data gap).

  1. Generator — scripts/build-release-data.sh

  - Accepts optional COMMIT_IDS (the caller passes Jira keys from commit messages). Unions them with the cf[10104] set, fetching commit-only tickets
  by key so they're enriched too.
  - Each ticket now carries inFixVersion, inCommits, and source; each release gets summary.bySource {both, taggedOnly, commitOnly} and a
  commitsTracked flag.
  - When COMMIT_IDS is unset, inCommits is null and tickets are neutral "tagged" — so a cf-only/local run never falsely flags everything as "not
  merged."
  - Verified for 26.7.0 (commits KAN-1,5,8,22,26): 3 both · 9 tagged-not-merged · 2 merged-untagged (KAN-22/26 carry other tags).

  2. Dashboard — docs/index.html

  - New Source column (color pills) + a source filter + a "Tickets by source" doughnut.
  - Two new line-scoped KPIs — "Tagged · not merged" and "Merged · untagged" (shown only when the line has commit data, both red as risk signals),
  plus the same two stats in each release's meta row.
  - CSV export now includes Source/InFixVersion/InCommits. JS parses clean; live in the browser.

  3. Confluence workflow — .github/workflows/Auto Tag from Sprint Branch.yml

  - cf[10104] IDs kept in cf_ids.txt; commits now collected since the previous tag (prev_tag..HEAD, not a flat last-20) into commit_ids.txt; unioned
  into jira_ids.txt.
  - The Confluence Jira table gained a Source column with the same three-way classification. YAML valid (16 steps).
  - Verified live: re-ran scripts/confluence-publish.sh 26.7.0 19398657 with a commit list → page v4 now shows 3 / 9 / 2 correctly classified rows
  under a Source column.
