#!/usr/bin/env bash
#
# Fetch + classify the tickets for a release TAG and write tickets.json (plus cf_ids.txt,
# commit_ids.txt, jira_ids.txt) into the current directory.
#
# jira-loading.yml runs this TWICE:
#   1. before the freeze notification — so the notice can list open work + assignees;
#   2. again right before Confluence/dashboard — so any status / assignee / PR changes
#      during the freeze window are reflected at cut time.
#
# Usage: scripts/fetch-release-tickets.sh <TAG> [PREV_TAG]
# Env:   JIRA_BASE_URL, JIRA_EMAIL, JIRA_API_TOKEN
#
set -euo pipefail

TAG="${1:?usage: fetch-release-tickets.sh <TAG> [PREV_TAG]}"
PREV="${2:-}"

AUTH=$(printf '%s' "$JIRA_EMAIL:$JIRA_API_TOKEN" | base64 | tr -d '\n')
ENDPOINT="$JIRA_BASE_URL/rest/api/3/search/jql"
JQL="cf[10104] = \"$TAG\""

echo "Endpoint : $ENDPOINT"
echo "JQL      : $JQL"

# ── Auth guard ──────────────────────────────────────────────────────────────
# A bad/empty Basic-auth header makes Jira fall back to ANONYMOUS: /myself 401s,
# while search returns HTTP 200 with 0 issues (looks exactly like "no tickets /
# index lag"). Catch it here instead of silently producing an empty release.
WHO_RESP=$(curl -s -w $'\n%{http_code}' -H "Authorization: Basic $AUTH" -H "Accept: application/json" "$JIRA_BASE_URL/rest/api/3/myself")
WHO_CODE=$(printf '%s' "$WHO_RESP" | tail -n1)
WHO=$(printf '%s' "$WHO_RESP" | sed '$d')
ACCT=$(echo "$WHO" | jq -r '.accountId // empty' 2>/dev/null || true)
echo "Auth as  : $(echo "$WHO" | jq -r '.displayName + " <" + (.emailAddress // "n/a") + "> " + .accountId' 2>/dev/null || echo "UNKNOWN")"
echo "Site     : $(echo "$WHO" | jq -r '.self // empty' 2>/dev/null | sed -E 's#/rest/.*##')"
if [ "$WHO_CODE" != "200" ] || [ -z "$ACCT" ]; then
  echo "❌ JIRA_EMAIL/JIRA_API_TOKEN did NOT authenticate (/myself HTTP $WHO_CODE)."
  echo "   Bad/empty/whitespace creds make Jira fall back to ANONYMOUS: search returns HTTP 200"
  echo "   with 0 results and no error — the exact '0 tickets' symptom. This is NOT indexing lag."
  echo "   → Fix JIRA_EMAIL / JIRA_API_TOKEN (no trailing newline/space) and JIRA_BASE_URL."
  exit 1
fi

# ── 1. Tagged set (cf[10104]), with retry for JQL index lag ─────────────────
ATTEMPTS=6; SLEEP=10; : > cf_ids.txt
for i in $(seq 1 "$ATTEMPTS"); do
  RESP=$(curl -s -w $'\n%{http_code}' --http1.1 -X POST \
    -H "Authorization: Basic $AUTH" -H "Content-Type: application/json" -H "Accept: application/json" \
    -d "$(jq -n --arg jql "$JQL" '{jql:$jql, fields:["key"], maxResults:100}')" "$ENDPOINT")
  CODE=$(printf '%s' "$RESP" | tail -n1)
  BODY=$(printf '%s' "$RESP" | sed '$d')
  if [ "$CODE" != "200" ]; then
    echo "❌ Jira search failed (HTTP $CODE):"; echo "$BODY" | jq '.' 2>/dev/null || echo "$BODY"; exit 1
  fi
  if ! echo "$BODY" | jq -e 'has("issues")' >/dev/null 2>&1; then
    echo "❌ Unexpected Jira response (no .issues field):"; echo "$BODY"; exit 1
  fi
  COUNT=$(echo "$BODY" | jq '.issues | length')
  echo "Attempt $i/$ATTEMPTS — $COUNT issue(s) match cf[10104] = \"$TAG\""
  if [ "$COUNT" -gt 0 ]; then echo "$BODY" | jq -r '.issues[].key' > cf_ids.txt; break; fi
  if [ "$i" -lt "$ATTEMPTS" ]; then echo "  none indexed yet — retrying in ${SLEEP}s"; sleep "$SLEEP"; fi
done
echo "Tagged (cf[10104]) tickets: $(grep -c . cf_ids.txt || true)"
if [ ! -s cf_ids.txt ]; then
  echo "⚠️  0 tagged tickets for \"$TAG\" after $ATTEMPTS attempts (commit-derived IDs may still apply)."
  echo "🔍 Most-recent cf[10104] values (spot value/typo mismatches):"
  curl -s --http1.1 -X POST -H "Authorization: Basic $AUTH" -H "Content-Type: application/json" -H "Accept: application/json" \
    -d "$(jq -n '{jql:"order by created DESC", fields:["key","customfield_10104"], maxResults:20}')" "$ENDPOINT" \
    | jq -r '.issues[]? | "  \(.key)  cf[10104]=\(.fields.customfield_10104 // "(null)")"' || true
fi

# ── 2. Commit-derived keys since the previous tag (merged-but-untagged work) ─
if [ -n "$PREV" ] && git rev-parse "$PREV" >/dev/null 2>&1; then RANGE="$PREV..HEAD"; else RANGE="HEAD"; fi
echo "Commit range: $RANGE"
git log $RANGE --pretty=format:"%s %b" 2>/dev/null \
  | { grep -oiE '[A-Z]+-[0-9]+' || true; } | tr 'a-z' 'A-Z' | sort -u > commit_ids.txt || true
echo "Commit-derived tickets: $(grep -c . commit_ids.txt || true)"

# ── 3. Union (full set for table + epics) ───────────────────────────────────
cat cf_ids.txt commit_ids.txt 2>/dev/null | sed '/^$/d' | sort -u > jira_ids.txt

# ── 4. Bulk-enrich the union → tickets.json (classified by source) ──────────
if [ ! -s jira_ids.txt ]; then
  echo "Union (cf[10104] ∪ commits) is empty — tickets.json = []"
  echo '{"issues":[]}' > raw.json
else
  KEYS_CSV=$(paste -sd, jira_ids.txt)
  echo "Bulk fetch: key in ($KEYS_CSV)"
  RESP=$(curl -s -w $'\n%{http_code}' --http1.1 -X POST -H "Authorization: Basic $AUTH" -H "Content-Type: application/json" -H "Accept: application/json" \
    -d "$(jq -n --arg jql "key in ($KEYS_CSV)" '{jql:$jql, fields:["summary","status","assignee","priority","issuetype","parent"], maxResults:100}')" \
    "$ENDPOINT")
  CODE=$(printf '%s' "$RESP" | tail -n1); printf '%s' "$RESP" | sed '$d' > raw.json
  echo "Bulk fetch HTTP $CODE — issues returned: $(jq '.issues|length' raw.json 2>/dev/null || echo '?')"
  if [ "$CODE" != "200" ]; then echo "❌ Bulk fetch failed:"; cat raw.json; exit 1; fi
fi

CF_JSON=$(jq -R . cf_ids.txt | jq -s 'map(select(length>0))')
COMMIT_JSON=$(jq -R . commit_ids.txt | jq -s 'map(select(length>0))')
jq --arg base "$JIRA_BASE_URL" --argjson cf "$CF_JSON" --argjson commits "$COMMIT_JSON" '
  [ .issues[]? | .key as $k
    | ($cf | index($k) != null) as $inCf
    | ($commits | index($k) != null) as $inC
    | { id:$k,
        summary:  (.fields.summary // "—"),
        status:   (.fields.status.name // "Unknown"),
        statusCat:(.fields.status.statusCategory.key // "new"),
        assignee: (.fields.assignee.displayName // "Unassigned"),
        priority: (.fields.priority.name // "Medium"),
        epic:      (if (.fields.parent.fields.issuetype.name // "")=="Epic" then .fields.parent.key else null end),
        epicTitle: (if (.fields.parent.fields.issuetype.name // "")=="Epic" then .fields.parent.fields.summary else "No epic" end),
        source: (if $inCf and $inC then "both" elif $inCf then "tagged_only" elif $inC then "commit_only" else "tagged_only" end),
        link: ($base + "/browse/" + $k) } ]' raw.json > tickets.json
echo "tickets.json: $(jq length tickets.json) ticket(s)"
