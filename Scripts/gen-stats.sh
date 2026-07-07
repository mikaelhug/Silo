#!/usr/bin/env bash
# Generate docs/stats.json from GitHub Releases download counts.
#
# Pure GitHub-native adoption stats: NO client-side ping, NO external service, NO
# per-machine tracking. GitHub already tallies a download_count on every release
# asset; every Silo.zip download (manual install or self-update) increments it, so
# those counters ARE the install + update numbers — this script just sums them into
# a small JSON the landing page renders. (Download count != unique machines.)
#
# Silo publishes MULTIPLE release streams: the app (tags like v0.2.1, asset Silo.zip)
# AND component builds (dxmt-*/wine-* tags, .tar.xz assets). We count ONLY releases
# that carry an app asset (.zip/.dmg) so the component releases can't pollute the
# total or get picked as "latest". .sha256 sidecars end in .sha256, so they're
# excluded too. `latest` is the newest non-prerelease app release.
#
# Run by .github/workflows/pages.yml (scheduled daily + on any docs/ change) so the
# deployed site always ships a fresh docs/stats.json. Also runnable locally after
# `gh auth login`. Never commits — the file is generated into the Pages artifact
# at deploy time (see .gitignore). gh + jq are preinstalled on GitHub runners.
set -euo pipefail
cd "$(dirname "$0")/.."

# Repo comes from Actions ($GITHUB_REPOSITORY) or, locally, from versions.env — the
# single source of truth for owner/name.
repo="${GITHUB_REPOSITORY:-}"
if [ -z "$repo" ]; then
  set -a; . ./versions.env; set +a
  repo="$SILO_GITHUB_REPO"
fi

out="docs/stats.json"

gh api --paginate "repos/$repo/releases" \
  | jq -s --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      (add // [])
      | def appcount: [.assets[] | select(.name | test("\\.(zip|dmg)$")) | .download_count] | add // 0;
        map(select(.draft | not))
        | map(select(any(.assets[]?; .name | test("\\.(zip|dmg)$")))) as $rels
        | ($rels | map(appcount) | add // 0) as $total
        | ($rels | map(select(.prerelease | not)) | first) as $latest
        | {
            generated_at: $now,
            total_downloads: $total,
            release_count: ($rels | length),
            latest: (
              if $latest == null then null
              else { version: ($latest.tag_name | ltrimstr("v")), downloads: ($latest | appcount) }
              end
            )
          }
    ' > "$out.tmp"

mv "$out.tmp" "$out"
echo "Wrote $out:"
cat "$out"
