#!/usr/bin/env bash
# Period-ladder helper for mac_pe -- run INSIDE the nix shell:
#
#     cd ~/workspace/librelane_project/difetto && nix develop
#     cd ~/workspace/librelane_project
#     ./designs/mac/librelane_flow_pd/scripts/sweep_period.sh 6.5 7.0 7.5
#
# For each period it updates THE THREE PLACES THAT MUST AGREE
# (docs/02_RUNBOOK.md §4) and then runs a full Classic flow with a
# derived tag: 6.5 -> f65, 7.0 -> f70, 7.5 -> f75.
#
#   1. config.yaml   CLOCK_PERIOD   (drives PnR repair/optimization)
#   2. impl.sdc      create_clock   (PnR STA)
#   3. signoff.sdc   create_clock   (signoff STA)
#
# Setup-violation checker warnings do NOT stop the ladder (we WANT those
# reports -- they are the evidence for the next rung). A hard config/parse
# error still shows up in each run's error.log.
#
# NEVER use this together with --overwrite on a tag you want to keep: each
# tag is rewritten on re-run.

D="$(cd "$(dirname "$0")/.." && pwd)"
R="$(cd "$D/../../.." && pwd)"
cd "$R"
C=./designs/mac/librelane_flow_pd/config.yaml

for P in "$@"; do
    TAG="f${P/./}"
    echo "### period $P ns -> tag $TAG  ($(date +%T))"
    sed -i "s/^CLOCK_PERIOD: [0-9.]*/CLOCK_PERIOD: $P/" "$D/config.yaml"
    sed -i "s/^create_clock -name clk -period [0-9.]*/create_clock -name clk -period $P/" "$D/impl.sdc" "$D/signoff.sdc"
    printf '    CLOCK_PERIOD: %s | ' "$(grep -h '^CLOCK_PERIOD' "$D/config.yaml" | cut -d'#' -f1 | tr -d ' ')"
    printf 'impl: %s | ' "$(grep -h '^create_clock' "$D/impl.sdc" | grep -o 'period [0-9.]*')"
    printf 'signoff: %s\n' "$(grep -h '^create_clock' "$D/signoff.sdc" | grep -o 'period [0-9.]*')"
    python3 -m librelane "$C" --run-tag "$TAG" --flow Classic --overwrite 2>&1 | tail -2
done
echo "PERIOD_LADDER_DONE ($(date +%T))"
