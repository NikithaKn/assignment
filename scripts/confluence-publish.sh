#!/usr/bin/env bash
#
# Local test of the "Update Confluence" logic from
#   .github/workflows/Auto Tag from Sprint Branch.yml
#
# Mirrors these workflow steps, runnable locally:
#   • Build Jira Table        (ticket + status HTML, from cf[10104] = TAG)
#   • Fetch Epic Summaries    (deduped epic highlights)
#   • Update Confluence       (GET version+body → prepend new section → PUT version+1)
#
# The page is resolved by RELEASE LINE: for any TAG (26.7.x / 26.7.0 / 26.7.1) the
# line is 26.7, so the target page is titled "Release Notes - 26.7". The job finds
# that page in the space and updates it; if absent, it creates and populates it.
#
# Usage:  ./scripts/confluence-publish.sh [TAG]
#
set -euo pipefail

# ── Jira (POC) — source of ticket/epic data ────────────────────────────────
JIRA_BASE_URL="${JIRA_BASE_URL:-https://writetonikithakn-1776491593410.atlassian.net}"
JIRA_EMAIL="${JIRA_EMAIL:-writetonikithakn@gmail.com}"
JIRA_API_TOKEN="${JIRA_API_TOKEN:-ATATT3xFfGF0oMb3NUbG0K6s9TfEowdqjxxzzbqsH4bqpUB1kZgXMUSjW9GwJ5xVafVM9TuOPLa23g1azr1jcpqj5XO-XCryKUIznAqAKg7cB4My8FqU6ucF2KEjW4cw_4FzGoYpb98J2lZwWCmMcLBUAUamnW6yUstcS84JKp0giFGBW3EZ8gk=EC5070A7}"

# ── Confluence — publish target (separate site) ────────────────────────────
CONFLUENCE_BASE_URL="${CONFLUENCE_BASE_URL:-https://writetonikithakn.atlassian.net}"
CONFLUENCE_EMAIL="${CONFLUENCE_EMAIL:-writetonikithakn@gmail.com}"
CONFLUENCE_API_TOKEN="${CONFLUENCE_API_TOKEN:-ATATT3xFfGF0TCDOH_JUttrcagMrYFeHv7nYDRCwsBHRsFBVIsoIM401Y8BqPeTtTP6lslVQ2GKRSyIW-tzQ19u4DiGmtsBHw7UJhA2J0aX9j1akMWlWy84JvS8aRQ1s66U2BOD2EoWADPXYGW9bUzDed6kjRKkUJZnx0XMuBlY2BNLzi3UZ-Jg=14C34AB6}"
SPACE_KEY="${SPACE_KEY:-MFS}"

TAG="${1:-26.7.0}"
# Release line: strip the trailing .x / .N  →  26.7.1 / 26.7.x  ->  26.7
LINE=$(echo "$TAG" | sed -E 's/\.[^.]*$//')
PAGE_TITLE="Release Notes - $LINE"

JAUTH=$(printf '%s' "$JIRA_EMAIL:$JIRA_API_TOKEN" | base64 | tr -d '\n')
cauth() { printf '%s' "$CONFLUENCE_EMAIL:$CONFLUENCE_API_TOKEN" | base64 | tr -d '\n'; }
CAUTH=$(cauth)

echo "================================================================"
echo "Confluence publish test — tag $TAG → $CONFLUENCE_BASE_URL (space $SPACE_KEY)"
echo "================================================================"

# ── 1. Tagged set (cf[10104]) + optional commit set → union ────────────────
#    COMMIT_IDS (space/comma/newline separated keys) is optional; if provided
#    the table classifies each ticket's Source, mirroring the workflow.
curl -s -X POST \
  -H "Authorization: Basic $JAUTH" -H "Content-Type: application/json" -H "Accept: application/json" \
  -d "$(jq -n --arg jql "cf[10104] = \"$TAG\"" '{jql:$jql, fields:["key"], maxResults:1000}')" \
  "$JIRA_BASE_URL/rest/api/3/search/jql" | jq -r '.issues[].key' > cf_ids.txt
printf '%s\n' "${COMMIT_IDS:-}" | grep -oiE '[A-Za-z]+-[0-9]+' | tr 'a-z' 'A-Z' | sort -u > commit_ids.txt || true
cat cf_ids.txt commit_ids.txt | sed '/^$/d' | sort -u > jira_ids.txt
JIRA_IDS=$(cat jira_ids.txt)
echo "Tagged: $(paste -sd' ' cf_ids.txt)"
echo "Commits: $(paste -sd' ' commit_ids.txt)"
echo "Union:  $(paste -sd' ' jira_ids.txt)"

# ── 2. Build Jira Table (HTML) with combined-source classification ─────────
{ echo "<table><tbody>"; echo "<tr><th>Ticket</th><th>Status</th><th>Source</th></tr>"; } > jira_table.html
while read -r ticket; do
  [ -z "$ticket" ] && continue
  STATUS=$(curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" "$JIRA_BASE_URL/rest/api/3/issue/$ticket?fields=status" | jq -r '.fields.status.name // "Unknown"')
  grep -qx "$ticket" cf_ids.txt     && IN_CF=yes     || IN_CF=no
  grep -qx "$ticket" commit_ids.txt && IN_COMMIT=yes || IN_COMMIT=no
  if   [ "$IN_CF" = yes ] && [ "$IN_COMMIT" = yes ]; then SRC="Tagged + merged"
  elif [ "$IN_CF" = yes ];                            then SRC="Tagged · not merged"
  else                                                    SRC="Merged · fix version missing"
  fi
  echo "<tr><td><a href=\"$JIRA_BASE_URL/browse/$ticket\">$ticket</a></td><td>$STATUS</td><td>$SRC</td></tr>" >> jira_table.html
done <<< "$JIRA_IDS"
echo "</tbody></table>" >> jira_table.html

# ── 3. Fetch Epic Summaries (deduped) ──────────────────────────────────────
echo "[]" > release_notes.json
while read -r ticket; do
  [ -z "$ticket" ] && continue
  RESP=$(curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" "$JIRA_BASE_URL/rest/api/3/issue/$ticket?fields=issuetype,parent")
  [ "$(echo "$RESP" | jq -r '.fields.issuetype.name')" != "Story" ] && continue
  EPIC_KEY=$(echo "$RESP" | jq -r '.fields.parent.key // empty'); [ -z "$EPIC_KEY" ] && continue
  EPIC_RESP=$(curl -s -u "$JIRA_EMAIL:$JIRA_API_TOKEN" "$JIRA_BASE_URL/rest/api/3/issue/$EPIC_KEY?fields=summary,description")
  EPIC_SUMMARY=$(echo "$EPIC_RESP" | jq -r '.fields.summary // ""')
  EPIC_DESC=$(echo "$EPIC_RESP" | jq -r 'def extract: if type=="object" and has("content") then .content[]|extract elif type=="object" and has("text") then .text else empty end; .fields.description | extract' | tr "\n" " ")
  SHORT=$(echo "$EPIC_DESC" | awk '{for(i=1;i<=15 && i<=NF;i++) printf $i" ";}')
  if [ "$(jq --arg k "$EPIC_KEY" 'any(.[]; .epic==$k)' release_notes.json)" = "false" ]; then
    jq --arg epic "$EPIC_KEY" --arg title "$EPIC_SUMMARY" --arg short "$SHORT" \
      '. += [{"epic":$epic,"title":$title,"short":$short}]' release_notes.json > tmp.json && mv tmp.json release_notes.json
  fi
done <<< "$JIRA_IDS"
echo "Epics:"; jq -r '.[] | "  \(.epic): \(.title)"' release_notes.json

# ── 4. Build the new release section ───────────────────────────────────────
TABLE=$(cat jira_table.html)
EPICS_JSON=$(cat release_notes.json)
EPIC_HTML=$(echo "$EPICS_JSON" | jq -r '"<ul>" + (map("<li><b>" + .epic + "</b>: " + .title + " — " + .short + "</li>") | join("")) + "</ul>"')
DATE=$(date)
NEW_SECTION="<hr/><h2>Release $TAG</h2><p><b>Date:</b> $DATE</p><h3>Epic Highlights</h3>$EPIC_HTML<h3>Jira Tickets</h3>$TABLE"

# ── 5. Resolve the per-line page by TITLE, then update-or-create ────────────
echo "Looking up page titled \"$PAGE_TITLE\" in space ${SPACE_KEY} ..."
FOUND=$(curl -s -G -u "$CONFLUENCE_EMAIL:$CONFLUENCE_API_TOKEN" \
  --data-urlencode "title=$PAGE_TITLE" \
  --data-urlencode "spaceKey=$SPACE_KEY" \
  --data-urlencode "type=page" \
  --data-urlencode "expand=version,body.storage" \
  "$CONFLUENCE_BASE_URL/wiki/rest/api/content")
PAGE_ID=$(echo "$FOUND" | jq -r '.results[0].id // empty')
TITLE_JSON=$(printf '%s' "$PAGE_TITLE" | jq -Rs .)

if [ -n "$PAGE_ID" ]; then
  VERSION=$(echo "$FOUND" | jq -r '.results[0].version.number')
  EXISTING=$(echo "$FOUND" | jq -r '.results[0].body.storage.value')
  NEW_VERSION=$((VERSION + 1))
  ESCAPED=$(printf '%s' "$NEW_SECTION $EXISTING" | jq -Rs .)
  echo "Found page id=$PAGE_ID (version $VERSION) — prepending Release $TAG, updating to $NEW_VERSION ..."
  RESULT=$(curl -s -u "$CONFLUENCE_EMAIL:$CONFLUENCE_API_TOKEN" -X PUT \
    "$CONFLUENCE_BASE_URL/wiki/rest/api/content/$PAGE_ID" \
    -H "Content-Type: application/json" \
    -d "{\"id\":\"$PAGE_ID\",\"type\":\"page\",\"title\":$TITLE_JSON,\"version\":{\"number\":$NEW_VERSION},\"body\":{\"storage\":{\"value\":$ESCAPED,\"representation\":\"storage\"}}}")
else
  echo "No page titled \"$PAGE_TITLE\" — creating and populating it ..."
  ESCAPED=$(printf '%s' "$NEW_SECTION" | jq -Rs .)
  RESULT=$(curl -s -u "$CONFLUENCE_EMAIL:$CONFLUENCE_API_TOKEN" -X POST \
    -H "Content-Type: application/json" \
    -d "{\"type\":\"page\",\"title\":$TITLE_JSON,\"space\":{\"key\":\"$SPACE_KEY\"},\"body\":{\"storage\":{\"value\":$ESCAPED,\"representation\":\"storage\"}}}" \
    "$CONFLUENCE_BASE_URL/wiki/rest/api/content")
  PAGE_ID=$(echo "$RESULT" | jq -r '.id // empty')
fi

if [ -z "$PAGE_ID" ] || [ "$(echo "$RESULT" | jq -r '.id // empty')" = "" ]; then
  echo "❌ Confluence operation failed:"; echo "$RESULT" | jq '.' 2>/dev/null || echo "$RESULT"; exit 1
fi
WEBUI=$(echo "$RESULT" | jq -r '(._links.base // "") + (._links.webui // "")')
echo "✅ Page \"$PAGE_TITLE\" id=$PAGE_ID  version=$(echo "$RESULT" | jq -r '.version.number')"
echo "🔗 ${WEBUI:-$CONFLUENCE_BASE_URL/wiki/spaces/$SPACE_KEY/pages/$PAGE_ID}"

rm -f jira_table.html release_notes.json cf_ids.txt commit_ids.txt jira_ids.txt
