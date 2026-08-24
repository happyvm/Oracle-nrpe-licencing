#!/usr/bin/env bash
#
# Execute l'ensemble des suites de tests et l'analyse statique.
# Aucune base Oracle requise.
#
# Les suites sont rejouees sous chaque shell disponible : le parc cible
# va de RHEL 5 (bash 3.2) a RHEL 9 (bash 5.1), et les constructions
# bash 4+ echouent silencieusement a la lecture avant d'echouer bruyamment
# en production. Definir BASH32 pour ajouter un interpreteur bash 3.2.
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

# Le moteur awk doit etre accepte par chaque implementation presente :
# gawk sur RHEL, mais mawk et busybox awk existent ailleurs.
echo "### Portabilite du moteur awk"
for impl in awk gawk mawk nawk original-awk; do
    command -v "$impl" >/dev/null 2>&1 || continue
    if "$impl" -f "$ROOT/lib/licensing_eval.awk" /dev/null /dev/null >/dev/null 2>&1; then
        echo "  ok   $impl"
    else
        # Code 3 = "mode inconnu", reponse normale sur une entree vide.
        if [ $? -eq 3 ]; then echo "  ok   $impl"; else echo "  FAIL $impl"; rc=1; fi
    fi
done
echo

shells="/bin/sh"
[[ -x /bin/bash ]] && shells="$shells /bin/bash"
[[ -n ${BASH32:-} && -x ${BASH32:-} ]] && shells="$shells $BASH32"

for sh in $shells; do
    echo "### Suites sous $sh ($("$sh" -c 'echo ${BASH_VERSION:-POSIX sh}'))"
    SHELL_UNDER_TEST=$sh "$ROOT/tests/run_tests.sh"           || rc=1
    SHELL_UNDER_TEST=$sh "$ROOT/tests/run_collector_tests.sh" || rc=1
    echo
done

# Parite entre moteurs : la logique etant reimplementee en PowerShell et
# en VBScript, rien n'empeche les trois de diverger sans ce controle.
# Definir PWSH et/ou WINE pour exercer les moteurs Windows.
"$ROOT/tests/run_parity_tests.sh" || rc=1

echo
[[ $rc -eq 0 ]] && echo "Toutes les suites sont vertes." || echo "Au moins une suite a echoue."
exit $rc
