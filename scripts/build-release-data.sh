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

# Optional commit-derived ticket keys for this tag, provided by the caller
# (e.g. GitHub Actions collects Jira keys from commit messages since the previous tag).
# Union with the cf[10104] set lets us catch work that was merged but where the
# developer forgot to set the fix version, and flag tickets tagged-but-not-merged.
# If COMMIT_IDS is UNSET, commit attribution is "not tracked" (classification by
# fix-version membership only). If SET (even empty), we classify against it.
if [ "${COMMIT_IDS+set}" = "set" ]; then
  COMMITS_TRACKED="true"
  # grep exits 1 when COMMIT_IDS has no ticket keys; tolerate that under `set -e`/pipefail.
  COMMIT_KEYS_JSON=$(printf '%s\n' "$COMMIT_IDS" | { grep -oiE '[A-Za-z][A-Za-z0-9_]*-[0-9]+' || true; } | tr 'a-z' 'A-Z' | sort -u | jq -R . | jq -s 'map(select(length>0))')
else
  COMMITS_TRACKED="false"
  COMMIT_KEYS_JSON='[]'
fi

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

CF_COUNT=$(jq 'length' "$ISSUES_FILE")
echo ""
echo "📊 Tagged (cf[10104]) tickets for $TAG: $CF_COUNT"

# ─────────────────────────────────────────────────────────────────────
# Union with commit-derived tickets that are NOT tagged with this version
# (work merged but fix version not set). Fetched by key so we can enrich them.
# ─────────────────────────────────────────────────────────────────────
if [ "$COMMITS_TRACKED" = "true" ]; then
  CF_KEYS_JSON=$(jq '[ .[].key ]' "$ISSUES_FILE")
  COMMIT_ONLY_JSON=$(jq -n --argjson c "$COMMIT_KEYS_JSON" --argjson cf "$CF_KEYS_JSON" '$c - $cf')
  COMMIT_ONLY_COUNT=$(echo "$COMMIT_ONLY_JSON" | jq 'length')
  echo "🔗 Commit-derived keys: $(echo "$COMMIT_KEYS_JSON" | jq -c .)  | commit-only (untagged): $COMMIT_ONLY_COUNT"
  if [ "$COMMIT_ONLY_COUNT" -gt 0 ]; then
    KEYS_CSV=$(echo "$COMMIT_ONLY_JSON" | jq -r 'join(",")')
    CO_RESP=$(curl -s -X POST --http1.1 \
      -H "Authorization: Basic $AUTH" -H "Content-Type: application/json" -H "Accept: application/json" \
      -d "$(jq -n --arg jql "key in ($KEYS_CSV)" --argjson fields "$FIELDS" '{jql:$jql, fields:$fields, maxResults:100}')" \
      "$ENDPOINT")
    if echo "$CO_RESP" | jq -e 'has("issues")' >/dev/null 2>&1; then
      jq -s '.[0] + (.[1].issues // [])' "$ISSUES_FILE" <(echo "$CO_RESP") > "$ISSUES_FILE.tmp" && mv "$ISSUES_FILE.tmp" "$ISSUES_FILE"
    else
      echo "⚠️  Some commit-only keys could not be fetched (may not exist): $(echo "$CO_RESP" | jq -rc '.errorMessages // []')"
    fi
  fi
fi

TICKET_COUNT=$(jq 'length' "$ISSUES_FILE")
echo "📊 Total tickets for $TAG (tagged ∪ committed): $TICKET_COUNT"

# 0 tickets is a VALID outcome (fix version not set yet, or a tag cut with no work).
# We still record an empty release block so the dashboard shows the cut happened.
# Sample recent cf[10104] values to help spot a wrong/typo'd tag value.
if [ "$TICKET_COUNT" -eq 0 ]; then
  echo "⚠️  No tickets matched cf[10104] = \"$TAG\"."
  echo "🔍 Recent cf[10104] values (to spot a value/typo mismatch):"
  curl -s -X POST --http1.1 \
    -H "Authorization: Basic $AUTH" -H "Content-Type: application/json" -H "Accept: application/json" \
    -d "$(jq -n '{jql:"order by created DESC", fields:["key","customfield_10104"], maxResults:20}')" \
    "$ENDPOINT" 2>/dev/null \
    | jq -r '.issues[]? | "  \(.key)  cf[10104]=\(.fields.customfield_10104 // "(null)")"' 2>/dev/null \
    || echo "  (could not fetch sample)"
  echo "➡️  Recording an empty release block for $TAG so the dashboard reflects the cut."
fi

# ─────────────────────────────────────────────────────────────────────
# Transform raw issues -> structured tickets[] and deduped epics[]
# epic = parent, but only when the parent is itself an Epic issue type.
# ─────────────────────────────────────────────────────────────────────
TICKETS_JSON=$(jq \
  --arg base "$JIRA_BASE_URL" \
  --arg tag "$TAG" \
  --arg tracked "$COMMITS_TRACKED" \
  --argjson commitKeys "$COMMIT_KEYS_JSON" '
  [ .[]
    | .key as $k
    | ( .fields.customfield_10104 // [] ) as $tags
    | ( $tags | any(. == $tag) ) as $inFV
    | ( if $tracked == "true" then ($commitKeys | any(. == $k)) else null end ) as $inC
    | {
      id:       $k,
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
      inFixVersion: $inFV,
      inCommits:    $inC,
      source: ( if $tracked != "true" then "tagged"
                elif ($inFV and $inC) then "both"
                elif $inFV then "tagged_only"
                else "commit_only" end ),
      link:     ($base + "/browse/" + $k)
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
  epicCount:  ( [ .[] | .epic | select(.!=null) ] | unique | length ),
  bySource:   { both:        ( [ .[] | select(.source=="both") ] | length ),
                taggedOnly:  ( [ .[] | select(.source=="tagged_only") ] | length ),
                commitOnly:  ( [ .[] | select(.source=="commit_only") ] | length ) }
}')

NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

NEW_ENTRY=$(jq -n \
  --arg tag "$TAG" \
  --arg branch "$BRANCH" \
  --arg date "$NOW" \
  --argjson commitsTracked "$COMMITS_TRACKED" \
  --argjson ticket_count "$TICKET_COUNT" \
  --argjson tickets_done "$DONE_COUNT" \
  --argjson summary "$SUMMARY_JSON" \
  --argjson tickets "$TICKETS_JSON" \
  --argjson epics "$EPICS_JSON" \
  '{tag:$tag, branch:$branch, date:$date, commitsTracked:$commitsTracked,
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
  ( [ .releases[]? | select(.tag != $entry.tag and (.tickets | type) == "array") ] + [$entry] )
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
