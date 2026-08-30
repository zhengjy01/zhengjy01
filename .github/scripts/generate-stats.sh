#!/usr/bin/env bash
# Generate a self-hosted GitHub profile stats SVG from GitHub's official API.
# Reliable: no third-party card service, hosted on GitHub's own domain.
# Triggered by .github/workflows/profile-stats.yml (daily + manual dispatch).

set -uo pipefail

USER="${USERNAME:-zhengjy01}"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
API="https://api.github.com"
OUT="${OUT:-stats.svg}"

AUTH=()
[ -n "$TOKEN" ] && AUTH=(-H "Authorization: Bearer $TOKEN")

api_json() { curl -s "${AUTH[@]}" -H "Accept: application/vnd.github+json" "$@"; }

# --- 1. PRs (created / merged) ---
PR=$(api_json --get "$API/search/issues" --data-urlencode "q=author:${USER} type:pr" | jq -r '.total_count // 0')
PR_MERGED=$(api_json --get "$API/search/issues" --data-urlencode "q=author:${USER} type:pr is:merged" | jq -r '.total_count // 0')

# --- 2. Commits ---
COMMITS=$(api_json --get "$API/search/commits" --data-urlencode "q=author:${USER}" | jq -r '.total_count // 0')

# --- 3. Repos / stars / top language (own = non-fork) ---
# manual pagination (curl has no --paginate)
REPOS="[]"
page=1
while :; do
  page_json=$(api_json --get "$API/users/$USER/repos" --data-urlencode "per_page=100" --data-urlencode "page=$page")
  n=$(printf '%s' "$page_json" | jq 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)
  [ "$n" = "0" ] && break
  if [ "$page" = "1" ]; then REPOS="$page_json"; else REPOS=$(printf '%s\n%s' "$REPOS" "$page_json" | jq -s 'add'); fi
  [ "$n" -lt 100 ] && break
  page=$((page+1))
  [ "$page" -gt 10 ] && break
done
OWN=$(echo "$REPOS" | jq '[.[] | select(.fork==false)] | length')
TOTAL=$(echo "$REPOS" | jq 'length')
STARS=$(echo "$REPOS" | jq '[.[] | select(.fork==false) | .stargazers_count] | add // 0')
TOP_LANG=$(echo "$REPOS" | jq -r '[.[] | select(.fork==false) | .language? // empty] | group_by(.) | sort_by(-length) | .[0][0] // "N/A"')

# --- 4. Contributions (GraphQL) ---
CONTRIB=0
if [ -n "$TOKEN" ]; then
  CONTRIB=$(curl -s "${AUTH[@]}" -H "Accept: application/vnd.github+json" \
    -X POST "$API/graphql" \
    -d "{\"query\":\"query { user(login:\\\"${USER}\\\") { contributionsCollection { contributionCalendar { totalContributions } } } }\"}" \
    | jq -r '.data.user.contributionsCollection.contributionCalendar.totalContributions // 0')
fi

# Sanitize numbers (coerce to int, guard junk)
for v in PR PR_MERGED COMMITS OWN TOTAL STARS CONTRIB; do
  eval "$v=\$(printf '%s' \"\$$v\" | grep -Eo '[0-9]+' | head -1 || echo 0)"
  eval "[ \"\$$v\" ] || $v=0"
done
TOP_LANG=$(printf '%s' "$TOP_LANG" | tr -d '"' | head -c 24)

# Thousands separator
fmt() { echo "$1" | perl -pe 's/(\d)(?=(\d{3})+$)/$1,/g'; }

PR_F=$(fmt "$PR"); PRM_F=$(fmt "$PR_MERGED"); COM_F=$(fmt "$COMMITS")
OWN_F=$(fmt "$OWN"); TOT_F=$(fmt "$TOTAL"); STA_F=$(fmt "$STARS"); CON_F=$(fmt "$CONTRIB")

# --- SVG layout ---
# tiles: (label, value, accent color, sublabel)
T=''
tile() { # x y label value color sub fs
  local x="$1" y="$2" label="$3" value="$4" color="$5" sub="$6"
  local fs="${7:-30}"
  local vlen="${#value}"
  [ "$vlen" -gt 12 ] && fs=20
  [ "$vlen" -gt 8 ] && [ "$fs" = "30" ] && fs=24
  T+="<g>
    <rect x=\"$x\" y=\"$y\" width=\"252\" height=\"92\" rx=\"14\" fill=\"#1b1830\" stroke=\"#2a2545\" stroke-width=\"1\"/>
    <text x=\"$((x+126))\" y=\"$((y+46))\" text-anchor=\"middle\" font-family=\"-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif\" font-size=\"$fs\" font-weight=\"700\" fill=\"$color\">$value</text>
    <text x=\"$((x+126))\" y=\"$((y+70))\" text-anchor=\"middle\" font-family=\"-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif\" font-size=\"13\" fill=\"#8b93a7\">$label</text>
    <text x=\"$((x+126))\" y=\"$((y+85))\" text-anchor=\"middle\" font-family=\"-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif\" font-size=\"10\" fill=\"#5a6072\">$sub</text>
  </g>"
}

# grid of 2 rows x 3 cols
tile 30   96  "CONTRIBUTIONS" "$CON_F" "#fe428e" "last 365 days"
tile 302  96  "COMMITS"       "$COM_F" "#a371f7" "all time"
tile 574  96  "PRs MERGED"    "$PRM_F"  "#58a6ff" "of $PR_F opened" "" 26
tile 30   210 "OWN REPOS"     "$OWN_F"  "#2dd4bf" "$TOT_F public incl. forks"
tile 302  210 "STARS EARNED"  "$STA_F"  "#fbc02d" "across own repos"
tile 574  210 "TOP LANGUAGE"  "$TOP_LANG" "#7ee787" "by own repo count" "" 22

# Determine card height based on content
cat > "$OUT" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="856" height="330" viewBox="0 0 856 330" role="img" aria-label="GitHub profile stats for ${USER}">
  <defs>
    <linearGradient id="hd" x1="0" y1="0" x2="1" y2="0">
      <stop offset="0%" stop-color="#fe428e"/>
      <stop offset="50%" stop-color="#a371f7"/>
      <stop offset="100%" stop-color="#58a6ff"/>
    </linearGradient>
  </defs>
  <rect width="856" height="330" rx="20" fill="#141321"/>
  <rect x="0.5" y="0.5" width="855" height="329" rx="20" fill="none" stroke="#2a2545"/>
  <text x="32" y="44" font-family="-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif" font-size="19" font-weight="700" fill="url(#hd)">GitHub @ ${USER}</text>
  <text x="32" y="66" font-family="-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif" font-size="12" fill="#8b93a7">Live from GitHub official API · auto-updated daily by GitHub Actions</text>
  <line x1="32" y1="80" x2="824" y2="80" stroke="#2a2545" stroke-width="1"/>
  ${T}
  <text x="32" y="320" font-family="-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif" font-size="10" fill="#5a6072">Generated ${USER} · See https://github.com/${USER} for the live profile.</text>
</svg>
SVG

echo "stats.svg written: $(wc -c < "$OUT") bytes"
echo "contrib=$CONTRIB commits=$COMMITS pr=$PR merged=$PR_MERGED own=$OWN total=$TOTAL stars=$STARS lang=$TOP_LANG"
