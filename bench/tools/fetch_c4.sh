#!/usr/bin/env bash
# Pull judged-valid high-severity findings from public Code4rena audit competitions.
# Each finding is a real, addressable GitHub issue. These are the no-loss side of the
# corpus: a protocol-risk situation that was disclosed and judged valid, with no
# depositor loss recorded against that protocol in the incident dataset.
set -u
out=/tmp/c4_findings.jsonl
: > "$out"
for repo in "$@"; do
  for label in "3%20(High%20Risk)" "2%20(Med%20Risk)"; do
    gh api "repos/code-423n4/$repo/issues?labels=$label&state=all&per_page=100" \
      --jq ".[] | select([.labels[].name] | index(\"unsatisfactory\") | not)
             | select([.labels[].name] | (index(\"satisfactory\") or index(\"sponsor confirmed\") or index(\"selected for report\")))
             | {repo:\"$repo\", number:.number, title:.title, url:.html_url, createdAt:.created_at,
                labels:[.labels[].name]}" 2>/dev/null >> "$out"
  done
done
wc -l < "$out"
