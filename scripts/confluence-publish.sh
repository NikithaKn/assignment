#!/usr/bin/env bash
#
# Publish a release section to the per-line Confluence page "Release Notes - <line>"
# in the constant REL space. Mirrors the "Update Confluence" step of
#   .github/workflows/Auto Tag from Sprint Branch.yml
#
# Per release section it renders:
#   • a readiness summary line (tickets / % done / high-prio open)
#   • an "Action items" callout (tagged-not-merged, merged-untagged)
#   • tickets grouped by epic, with Title / Status & Source lozenges / Assignee / Priority
#   • a link to the GitHub Pages dashboard, and a provenance footer (UTC)
# Re-running the SAME tag replaces that tag's section (idempotent).
#
# Usage:  ./scripts/confluence-publish.sh [TAG]      (TAG e.g. 26.7.0 / 26.7.1)
#         optional env: COMMIT_IDS, DASHBOARD_BASE, REPO_URL, PREV_TAG
#
set -euo pipefail

# ── Jira (POC) ─────────────────────────────────────────────────────────────
JIRA_BASE_URL="${JIRA_BASE_URL}"
JIRA_EMAIL="${JIRA_EMAIL}"
JIRA_API_TOKEN="${JIRA_API_TOKEN}"

# ── Confluence ─────────────────────────────────────────────────────────────
CONFLUENCE_BASE_URL="${CONFLUENCE_BASE_URL}"
CONFLUENCE_EMAIL="${CONFLUENCE_EMAIL}"
CONFLUENCE_API_TOKEN="${CONFLUENCE_API_TOKEN}"
SPACE_KEY="REL"   # constant: dedicated "Release Notes" Confluence space

TAG="${1:-26.7.0}"
LINE=$(echo "$TAG" | sed -E 's/\.[^.]*$//')          # 26.7.1 / 26.7.x -> 26.7
BRANCH="${LINE}.x"
PAGE_TITLE="Release Notes - $LINE"
DASHBOARD_BASE="${DASHBOARD_BASE:-https://nikithakn.github.io/assignment}"
DASH_LINK="${DASHBOARD_BASE}/#${BRANCH}"
DATE_UTC=$(date -u +"%Y-%m-%d %H:%MZ")
PROV="${PROV:-Generated $DATE_UTC by confluence-publish.sh}"

JAUTH=$(printf '%s' "$JIRA_EMAIL:$JIRA_API_TOKEN" | base64 | tr -d '\n')
JIRA_SEARCH="$JIRA_BASE_URL/rest/api/3/search/jql"
C_API="$CONFLUENCE_BASE_URL/wiki/rest/api/content"
cauth=(-u "$CONFLUENCE_EMAIL:$CONFLUENCE_API_TOKEN")

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

echo "=== Confluence release notes — $TAG → \"$PAGE_TITLE\" (space $SPACE_KEY) ==="

# ── 1. Tagged (cf[10104]) keys + optional commit keys → union ──────────────
curl -s -X POST -H "Authorization: Basic $JAUTH" -H "Content-Type: application/json" -H "Accept: application/json" \
  -d "$(jq -n --arg jql "cf[10104] = \"$TAG\"" '{jql:$jql, fields:["key"], maxResults:1000}')" \
  "$JIRA_SEARCH" | jq -r '.issues[].key' > "$WORK/cf.txt"
printf '%s\n' "${COMMIT_IDS:-}" | grep -oiE '[A-Za-z]+-[0-9]+' | tr 'a-z' 'A-Z' | sort -u > "$WORK/commit.txt" || true
cat "$WORK/cf.txt" "$WORK/commit.txt" | sed '/^$/d' | sort -u > "$WORK/union.txt"
echo "Tagged: $(paste -sd' ' "$WORK/cf.txt")"
echo "Commits: $(paste -sd' ' "$WORK/commit.txt")"

if [ ! -s "$WORK/union.txt" ]; then
  echo "⚠️  No tickets (tagged or committed) for $TAG — nothing to publish."; exit 0
fi

# ── 2. Bulk-fetch enriched fields for the union ─────────────────────────────
KEYS_CSV=$(paste -sd, "$WORK/union.txt")
curl -s -X POST -H "Authorization: Basic $JAUTH" -H "Content-Type: application/json" -H "Accept: application/json" \
  -d "$(jq -n --arg jql "key in ($KEYS_CSV)" '{jql:$jql, fields:["summary","status","assignee","priority","issuetype","parent"], maxResults:1000}')" \
  "$JIRA_SEARCH" > "$WORK/raw.json"

CF_JSON=$(jq -R . "$WORK/cf.txt" | jq -s 'map(select(length>0))')
COMMIT_JSON=$(jq -R . "$WORK/commit.txt" | jq -s 'map(select(length>0))')

jq --arg base "$JIRA_BASE_URL" --argjson cf "$CF_JSON" --argjson commits "$COMMIT_JSON" '
  [ .issues[]? | .key as $k
    | ($cf | index($k) != null) as $inCf
    | ($commits | index($k) != null) as $inC
    | {
        id: $k,
        summary:  (.fields.summary // "—"),
        status:   (.fields.status.name // "Unknown"),
        statusCat:(.fields.status.statusCategory.key // "new"),
        assignee: (.fields.assignee.displayName // "Unassigned"),
        priority: (.fields.priority.name // "Medium"),
        epic:      (if (.fields.parent.fields.issuetype.name // "")=="Epic" then .fields.parent.key else null end),
        epicTitle: (if (.fields.parent.fields.issuetype.name // "")=="Epic" then .fields.parent.fields.summary else "No epic" end),
        source: (if $inCf and $inC then "both" elif $inCf then "tagged_only" elif $inC then "commit_only" else "tagged_only" end),
        link: ($base + "/browse/" + $k)
      } ]' "$WORK/raw.json" > "$WORK/tickets.json"

# ── 3. Render the section inner HTML (Confluence storage format) ────────────
jq -r --arg dash "$DASH_LINK" --arg prov "$PROV" '
  def esc: gsub("&";"&amp;") | gsub("<";"&lt;") | gsub(">";"&gt;");
  def loz($colour;$title): "<ac:structured-macro ac:name=\"status\" ac:schema-version=\"1\">"
      + "<ac:parameter ac:name=\"colour\">" + $colour + "</ac:parameter>"
      + "<ac:parameter ac:name=\"title\">" + ($title|esc) + "</ac:parameter></ac:structured-macro>";
  def statusLoz: loz((if .statusCat=="done" then "Green" elif .statusCat=="indeterminate" then "Yellow" else "Grey" end); .status);
  def sourceLoz: (if .source=="both" then ["Green","tagged + merged"]
                  elif .source=="tagged_only" then ["Yellow","not merged"]
                  elif .source=="commit_only" then ["Blue","untagged"]
                  else ["Grey","tagged"] end) as $s | loz($s[0]; $s[1]);
  . as $t
  | ($t|length) as $total
  | ([$t[]|select(.statusCat=="done")]|length) as $done
  | ([$t[]|select((.priority|ascii_downcase|test("high")) and .statusCat!="done")]|length) as $hi
  | [$t[]|select(.source=="tagged_only")] as $pending
  | [$t[]|select(.source=="commit_only")] as $missing
  | (if $total>0 then (($done*100/$total)|floor) else 0 end) as $pct
  | ("<p><b>" + ($total|tostring) + " tickets</b> · " + ($done|tostring) + " done (" + ($pct|tostring) + "%) · "
      + ($hi|tostring) + " high-priority open</p>")
  + (if ($pending|length)>0 or ($missing|length)>0 then
      "<ac:structured-macro ac:name=\"info\"><ac:rich-text-body><p><strong>Action items</strong></p>"
      + (if ($pending|length)>0 then "<p>⏳ <b>Tagged but not merged</b> (work pending): " + ([$pending[].id]|join(", ")) + "</p>" else "" end)
      + (if ($missing|length)>0 then "<p>⚠️ <b>Merged but fix version missing</b> (please set cf[10104]): " + ([$missing[].id]|join(", ")) + "</p>" else "" end)
      + "</ac:rich-text-body></ac:structured-macro>"
     else "" end)
  + "<p>📊 <a href=\"" + $dash + "\">Open in release dashboard</a></p>"
  + ( [ $t | group_by(.epicTitle) | .[]
        | "<h4>" + (.[0].epicTitle|esc) + (if .[0].epic then " (" + .[0].epic + ")" else "" end) + " — " + (length|tostring) + " ticket(s)</h4>"
        + "<table><tbody><tr><th>Ticket</th><th>Title</th><th>Status</th><th>Assignee</th><th>Priority</th><th>Source</th></tr>"
        + ( [ .[] | "<tr><td><a href=\"" + .link + "\">" + .id + "</a></td>"
              + "<td>" + (.summary|esc) + "</td>"
              + "<td>" + statusLoz + "</td>"
              + "<td>" + (.assignee|esc) + "</td>"
              + "<td>" + (.priority|esc) + "</td>"
              + "<td>" + sourceLoz + "</td></tr>" ] | join("") )
        + "</tbody></table>"
      ] | join("") )
  + "<p><em>" + ($prov|esc) + "</em></p>"
' "$WORK/tickets.json" > "$WORK/inner.html"

{ printf '<hr/><h2>Release %s</h2><p><b>Date:</b> %s</p>' "$TAG" "$DATE_UTC"; cat "$WORK/inner.html"; } > "$WORK/section.html"

# ── 4. Find the per-line page, then update (idempotent per tag) or create ──
TITLE_JSON=$(printf '%s' "$PAGE_TITLE" | jq -Rs .)
FOUND=$(curl -s -G "${cauth[@]}" \
  --data-urlencode "title=$PAGE_TITLE" --data-urlencode "spaceKey=$SPACE_KEY" \
  --data-urlencode "type=page" --data-urlencode "expand=version,body.storage" "$C_API")
PAGE_ID=$(echo "$FOUND" | jq -r '.results[0].id // empty')

if [ -n "$PAGE_ID" ]; then
  VERSION=$(echo "$FOUND" | jq -r '.results[0].version.number')
  echo "$FOUND" | jq -r '.results[0].body.storage.value' > "$WORK/existing.html"
  # Idempotency: drop any existing section for THIS tag before prepending the fresh one.
  TAG="$TAG" python3 - "$WORK/existing.html" > "$WORK/cleaned.html" <<'PY'
import os, re, sys
body = open(sys.argv[1]).read()
tag = re.escape(os.environ["TAG"])
pat = re.compile(r'<hr\s*/?>\s*<h2>Release ' + tag + r'</h2>.*?(?=<hr\s*/?>|$)', re.DOTALL)
sys.stdout.write(pat.sub('', body))
PY
  NEW_VERSION=$((VERSION + 1))
  cat "$WORK/section.html" "$WORK/cleaned.html" > "$WORK/final.html"
  ESCAPED=$(jq -Rs . < "$WORK/final.html")
  echo "Found \"$PAGE_TITLE\" (id=$PAGE_ID, v$VERSION) — replacing/prepending Release $TAG → v$NEW_VERSION"
  RESULT=$(curl -s "${cauth[@]}" -X PUT "$C_API/$PAGE_ID" -H "Content-Type: application/json" \
    -d "{\"id\":\"$PAGE_ID\",\"type\":\"page\",\"title\":$TITLE_JSON,\"version\":{\"number\":$NEW_VERSION},\"body\":{\"storage\":{\"value\":$ESCAPED,\"representation\":\"storage\"}}}")
else
  echo "No page titled \"$PAGE_TITLE\" — creating and populating it"
  ESCAPED=$(jq -Rs . < "$WORK/section.html")
  RESULT=$(curl -s "${cauth[@]}" -X POST -H "Content-Type: application/json" \
    -d "{\"type\":\"page\",\"title\":$TITLE_JSON,\"space\":{\"key\":\"$SPACE_KEY\"},\"body\":{\"storage\":{\"value\":$ESCAPED,\"representation\":\"storage\"}}}" "$C_API")
  PAGE_ID=$(echo "$RESULT" | jq -r '.id // empty')
fi

if [ -z "$PAGE_ID" ] || [ "$(echo "$RESULT" | jq -r '.id // empty')" = "" ]; then
  echo "❌ Confluence operation failed:"; echo "$RESULT" | jq '.' 2>/dev/null || echo "$RESULT"; exit 1
fi
echo "✅ \"$PAGE_TITLE\" id=$PAGE_ID is now v$(echo "$RESULT" | jq -r '.version.number')"
echo "🔗 $(echo "$RESULT" | jq -r '(._links.base // "") + (._links.webui // "")')"
