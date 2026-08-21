#!/usr/bin/env bash
#
# Execute l'ensemble des suites de tests et l'analyse statique.
# Aucune base Oracle requise.
#
set -o nounset
set -o pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd); readonly ROOT
rc=0

if command -v shellcheck >/dev/null 2>&1; then
    echo "### Analyse statique"
    if shellcheck -S warning "$ROOT"/bin/*.sh "$ROOT"/tests/*.sh; then
        echo "  aucun avertissement"
    else
        rc=1
    fi
    echo
else
    echo "### Analyse statique ignoree (shellcheck absent)"; echo
fi

echo "### Plugin de controle"
"$ROOT/tests/run_tests.sh" || rc=1
echo
echo "### Collecteur"
"$ROOT/tests/run_collector_tests.sh" || rc=1

echo
[[ $rc -eq 0 ]] && echo "Toutes les suites sont vertes." || echo "Au moins une suite a echoue."
exit $rc
