#!/usr/bin/env bash
# Probe one rekt.news slug. Prints "slug<TAB>headline" only when the article really exists:
# HTTP 200 and a non-empty headline. A missing article answers 500, so the absence of a
# citation is observable rather than assumed.
slug="$1"
body=$(curl -sS --max-time 20 -w '\n%{http_code}' "https://rekt.news/$slug" 2>/dev/null) || exit 0
code=$(printf '%s' "$body" | tail -1)
[ "$code" = "200" ] || exit 0
headline=$(printf '%s' "$body" | sed -e 's/<[^>]*>/ /g' | tr -s ' \n' ' ' | sed -n 's/.*Rekt - \([^|]\{1,80\}\) function gtag.*/\1/p' | head -1)
[ -n "$headline" ] || exit 0
printf '%s\t%s\n' "$slug" "$headline"
