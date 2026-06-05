#!/usr/bin/env bash
#
# Build structured release data for the dashboard HTML template.
#
# Fetches every Jira ticket associated with a release TAG via customfield_10104,
# enriches each ticket (title/status/assignee/epic/...), and merges the result
# into docs/data/releases.json — accumulating one block per tag under its
# release branch (26.<sprint>.x). Re-running the same tag refreshes it in place.
#
# Usage:  ./scripts/build-release-data.sh [TAG]
#         (defaults to 26.7.0)
#
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────
# CONFIG — uses env vars when set (CI / GitHub Actions secrets), and
# falls back to the hardcoded POC values for local runs. POC token only.
# ─────────────────────────────────────────────────────────────────────
JIRA_BASE_URL="${JIRA_BASE_URL}"
JIRA_EMAIL="${JIRA_EMAIL}"
JIRA_API_TOKEN="${JIRA_API_TOKEN}"

TAG="${1:-26.7.0}"
CUSTOM_FIELD="customfield_10104"
OUT_FILE="docs/data/releases.json"

# Derive the release branch from the tag: 26.7.0 -> 26.7.x
BRANCH="$(echo "$TAG" | sed -E 's/\.[0-9]+$/.x/')"

# Resolve repo root so the script works from any cwd
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

echo "========================================="
echo "Building release data"
echo "  Tag    : $TAG"
echo "  Branch : $BRANCH"
echo "========================================="

# macOS base64 has no -w; strip newlines so the auth header is never corrupted.
AUTH=$(printf '%s' "$JIRA_EMAIL:$JIRA_API_TOKEN" | base64 | tr -d '\n')

ENDPOINT="$JIRA_BASE_URL/rest/api/3/search/jql"
JQL="cf[10104] = \"$TAG\""
FIELDS='["key","summary","status","issuetype","priority","assignee","parent","labels","components","reporter","created","updated","resolutiondate","customfield_10104"]'

echo "🔍 Endpoint : $ENDPOINT"
echo "🔍 JQL      : $JQL"

# Accumulate raw issues across pages into a temp file (one JSON array per page)
ISSUES_FILE=$(mktemp)
echo "[]" > "$ISSUES_FILE"
PAGE=1
NEXT_PAGE_TOKEN=""

while true; do
  echo ""
  echo "--- Page $PAGE ---"

  if [ -z "$NEXT_PAGE_TOKEN" ]; then
    REQUEST_BODY=$(jq -n --arg jql "$JQL" --argjson fields "$FIELDS" --argjson maxResults 100 \
      '{jql:$jql, fields:$fields, maxResults:$maxResults}')
  else
    REQUEST_BODY=$(jq -n --arg jql "$JQL" --argjson fields "$FIELDS" --argjson maxResults 100 \
      --arg npt "$NEXT_PAGE_TOKEN" \
      '{jql:$jql, fields:$fields, maxResults:$maxResults, nextPageToken:$npt}')
  fi

  HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" -X POST --http1.1 \
    -H "Authorization: Basic $AUTH" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$REQUEST_BODY" \
    "$ENDPOINT")

  HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n1)
  RESPONSE=$(echo "$HTTP_RESPONSE" | sed '$d')
  echo "🔍 HTTP Status: $HTTP_CODE"

  if [ "$HTTP_CODE" != "200" ]; then
    echo "❌ Request failed (HTTP $HTTP_CODE)"
    echo "$RESPONSE" | jq '.' 2>/dev/null || echo "$RESPONSE"
    exit 1
  fi

  # Append this page's issues to the accumulator
  PAGE_COUNT=$(echo "$RESPONSE" | jq '.issues | length')
  jq -s '.[0] + (.[1].issues // [])' "$ISSUES_FILE" <(echo "$RESPONSE") > "$ISSUES_FILE.tmp" \
    && mv "$ISSUES_FILE.tmp" "$ISSUES_FILE"
  echo "📄 Issues on this page: $PAGE_COUNT"

  NEXT_PAGE_TOKEN=$(echo "$RESPONSE" | jq -r '.nextPageToken // empty')
  if [ -z "$NEXT_PAGE_TOKEN" ]; then
    echo "✅ All pages fetched"
    break
  fi
  PAGE=$((PAGE + 1))
done

TICKET_COUNT=$(jq 'length' "$ISSUES_FILE")
echo ""
echo "📊 Total tickets for $TAG: $TICKET_COUNT"

# Safety: don't write an empty release block (likely a wrong tag value or access issue).
# Sample recent cf[10104] values to help diagnose, then exit cleanly without touching the file.
if [ "$TICKET_COUNT" -eq 0 ]; then
  echo "⚠️  No tickets matched cf[10104] = \"$TAG\" — leaving $OUT_FILE unchanged."
  echo "🔍 Recent cf[10104] values (for reference):"
  curl -s -X POST --http1.1 \
    -H "Authorization: Basic $AUTH" -H "Content-Type: application/json" -H "Accept: application/json" \
    -d "$(jq -n '{jql:"order by created DESC", fields:["key","customfield_10104"], maxResults:20}')" \
    "$ENDPOINT" 2>/dev/null \
    | jq -r '.issues[]? | "  \(.key)  cf[10104]=\(.fields.customfield_10104 // "(null)")"' 2>/dev/null \
    || echo "  (could not fetch sample)"
  rm -f "$ISSUES_FILE"
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────
# Transform raw issues -> structured tickets[] and deduped epics[]
# epic = parent, but only when the parent is itself an Epic issue type.
# ─────────────────────────────────────────────────────────────────────
TICKETS_JSON=$(jq --arg base "$JIRA_BASE_URL" '
  [ .[] | ( .fields.customfield_10104 // [] ) as $tags | {
      id:       .key,
      summary:  (.fields.summary // "—"),
      status:   (.fields.status.name // "Unknown"),
      statusCategory: (.fields.status.statusCategory.key // "new"),
      type:     (.fields.issuetype.name // "Task"),
      priority: (.fields.priority.name // "Medium"),
      assignee: (.fields.assignee.displayName // "Unassigned"),
      reporter: (.fields.reporter.displayName // "Unknown"),
      epic:      ( if (.fields.parent.fields.issuetype.name // "") == "Epic"
                   then .fields.parent.key else null end ),
      epicTitle: ( if (.fields.parent.fields.issuetype.name // "") == "Epic"
                   then .fields.parent.fields.summary else null end ),
      labels:     (.fields.labels // []),
      components: ( [ (.fields.components // [])[].name ] ),
      created:    .fields.created,
      updated:    .fields.updated,
      resolved:   .fields.resolutiondate,
      tags:       $tags,
      carriedOver: (($tags | length) > 1),
      link:     ($base + "/browse/" + .key)
    } ]
' "$ISSUES_FILE")

EPICS_JSON=$(echo "$TICKETS_JSON" | jq '
  [ .[] | select(.epic != null) | {epic: .epic, title: .epicTitle} ] | unique_by(.epic)
')

# Per-release rollup: done count (by status category = done), status breakdown,
# unassigned count, carry-over count, distinct assignees.
DONE_COUNT=$(echo "$TICKETS_JSON" | jq '[ .[] | select(.statusCategory=="done") ] | length')

SUMMARY_JSON=$(echo "$TICKETS_JSON" | jq '{
  byStatus:   ( reduce .[] as $t ({}; .[$t.status] = ((.[$t.status] // 0) + 1)) ),
  unassigned: ( [ .[] | select(.assignee=="Unassigned") ] | length ),
  carriedOver:( [ .[] | select(.carriedOver) ] | length ),
  assignees:  ( [ .[] | select(.assignee!="Unassigned") | .assignee ] | unique ),
  epicCount:  ( [ .[] | .epic | select(.!=null) ] | unique | length )
}')

NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

NEW_ENTRY=$(jq -n \
  --arg tag "$TAG" \
  --arg branch "$BRANCH" \
  --arg date "$NOW" \
  --argjson ticket_count "$TICKET_COUNT" \
  --argjson tickets_done "$DONE_COUNT" \
  --argjson summary "$SUMMARY_JSON" \
  --argjson tickets "$TICKETS_JSON" \
  --argjson epics "$EPICS_JSON" \
  '{tag:$tag, branch:$branch, date:$date,
    ticket_count:$ticket_count, tickets_done:$tickets_done,
    summary:$summary, tickets:$tickets, epics:$epics}')

# ─────────────────────────────────────────────────────────────────────
# Idempotent merge into releases.json
#   - drop any existing entry with the same tag
#   - add the new entry
#   - sort releases by tag version descending (numeric, per segment)
#   - recompute rollups
# ─────────────────────────────────────────────────────────────────────
mkdir -p docs/data
if [ -f "$OUT_FILE" ]; then
  EXISTING="$(cat "$OUT_FILE")"
else
  EXISTING='{"releases":[]}'
fi

echo "$EXISTING" | jq \
  --argjson entry "$NEW_ENTRY" \
  --arg generatedAt "$NOW" \
  '
  ( [ .releases[]? | select(.tag != $entry.tag) ] + [$entry] )
    | sort_by( .tag | split(".") | map(tonumber? // 0) ) | reverse
  as $rel
  | {
      generatedAt: $generatedAt,
      totalReleases: ($rel | length),
      totalTickets: ([ $rel[].ticket_count ] | add // 0),
      totalDone: ([ $rel[].tickets_done ] | add // 0),
      totalEpics: ([ $rel[].epics[]?.epic ] | unique | length),
      branches: ([ $rel[].branch ] | unique),
      releases: $rel
    }
  ' > "$OUT_FILE"

echo ""
echo "💾 $OUT_FILE written"
echo "   totalReleases : $(jq '.totalReleases' "$OUT_FILE")"
echo "   totalTickets  : $(jq '.totalTickets' "$OUT_FILE")"
echo ""
echo "📄 Preview:"
jq '.' "$OUT_FILE"

rm -f "$ISSUES_FILE"
