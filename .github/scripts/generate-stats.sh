#!/usr/bin/env bash
# Generate self-hosted GitHub profile stats SVGs (English + Chinese) from GitHub's official API.
# Reliable: no third-party card service, hosted on GitHub's own domain.
# Outputs:
#   stats.svg     -> English labels  (used by README.EN.md)
#   stats.zh.svg  -> Chinese labels  (used by README.md)
# Triggered by .github/workflows/profile-stats.yml (daily + manual dispatch).

set -uo pipefail

USER="${USERNAME:-zhengjy01}"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
API="https://api.github.com"

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

# Font stack (includes CJK fonts so Chinese labels render everywhere)
FF="-apple-system,BlinkMacSystemFont,'Segoe UI','PingFang SC','Hiragino Sans GB','Microsoft YaHei',Helvetica,Arial,sans-serif"

# Language-agnostic tile builder: appends to global $T
tile() { # x y label value color sub fs
  local x="$1" y="$2" label="$3" value="$4" color="$5" sub="$6"
  local fs="${7:-30}"
  local vlen="${#value}"
  [ "$vlen" -gt 12 ] && fs=20
  [ "$vlen" -gt 8 ] && [ "$fs" = "30" ] && fs=24
  T+="<g>
    <rect x=\"$x\" y=\"$y\" width=\"252\" height=\"92\" rx=\"14\" fill=\"#1b1830\" stroke=\"#2a2545\" stroke-width=\"1\"/>
    <text x=\"$((x+126))\" y=\"$((y+46))\" text-anchor=\"middle\" font-family=\"$FF\" font-size=\"$fs\" font-weight=\"700\" fill=\"$color\">$value</text>
    <text x=\"$((x+126))\" y=\"$((y+70))\" text-anchor=\"middle\" font-family=\"$FF\" font-size=\"13\" fill=\"#8b93a7\">$label</text>
    <text x=\"$((x+126))\" y=\"$((y+85))\" text-anchor=\"middle\" font-family=\"$FF\" font-size=\"10\" fill=\"#5a6072\">$sub</text>
  </g>"
}

render() { # lang outfile
  local lang="$1" outfile="$2" T=""
  local TITLE HEAD_SUB FOOTER
  local L_CONTRIB_L L_CONTRIB_S L_COMMITS_L L_COMMITS_S L_PR_L L_PR_S L_REPO_L L_REPO_S L_STAR_L L_STAR_S L_LANG_L L_LANG_S

  if [ "$lang" = "zh" ]; then
    TITLE="GitHub @ ${USER}"
    HEAD_SUB="数据来自 GitHub 官方 API · 由 GitHub Actions 每天自动更新"
    FOOTER="Generated ${USER} · 实时档案见 https://github.com/${USER}"
    L_CONTRIB_L="贡献";      L_CONTRIB_S="近 365 天"
    L_COMMITS_L="提交";      L_COMMITS_S="累计"
    L_PR_L="已合并 PR";      L_PR_S="共 ${PR_F} 个"
    L_REPO_L="自有仓库";     L_REPO_S="共 ${TOT_F} 个公开（含 fork）"
    L_STAR_L="收获 Star";    L_STAR_S="分布于自有仓库"
    L_LANG_L="主语言";       L_LANG_S="按自有仓库数"
  else
    TITLE="GitHub @ ${USER}"
    HEAD_SUB="Live from GitHub official API · auto-updated daily by GitHub Actions"
    FOOTER="Generated ${USER} · See https://github.com/${USER} for the live profile."
    L_CONTRIB_L="CONTRIBUTIONS"; L_CONTRIB_S="last 365 days"
    L_COMMITS_L="COMMITS";       L_COMMITS_S="all time"
    L_PR_L="PRs MERGED";         L_PR_S="of ${PR_F} opened"
    L_REPO_L="OWN REPOS";        L_REPO_S="${TOT_F} public incl. forks"
    L_STAR_L="STARS EARNED";     L_STAR_S="across own repos"
    L_LANG_L="TOP LANGUAGE";     L_LANG_S="by own repo count"
  fi

  tile 30   96  "$L_CONTRIB_L" "$CON_F"   "#fe428e" "$L_CONTRIB_S"
  tile 302  96  "$L_COMMITS_L" "$COM_F"   "#a371f7" "$L_COMMITS_S"
  tile 574  96  "$L_PR_L"      "$PRM_F"   "#58a6ff" "$L_PR_S" "" 26
  tile 30   210 "$L_REPO_L"    "$OWN_F"   "#2dd4bf" "$L_REPO_S"
  tile 302  210 "$L_STAR_L"    "$STA_F"   "#fbc02d" "$L_STAR_S"
  tile 574  210 "$L_LANG_L"    "$TOP_LANG" "#7ee787" "$L_LANG_S" "" 22

  cat > "$outfile" <<SVG
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
  <text x="32" y="44" font-family="$FF" font-size="19" font-weight="700" fill="url(#hd)">${TITLE}</text>
  <text x="32" y="66" font-family="$FF" font-size="12" fill="#8b93a7">${HEAD_SUB}</text>
  <line x1="32" y1="80" x2="824" y2="80" stroke="#2a2545" stroke-width="1"/>
  ${T}
  <text x="32" y="320" font-family="$FF" font-size="10" fill="#5a6072">${FOOTER}</text>
</svg>
SVG
  echo "  wrote $outfile ($(wc -c < "$outfile") bytes)"
}

echo "stats: contrib=$CONTRIB commits=$COMMITS pr=$PR merged=$PR_MERGED own=$OWN total=$TOTAL stars=$STARS lang=$TOP_LANG"
render en stats.svg
render zh stats.zh.svg
