#!/usr/bin/env bash
#
# Test de parite entre le moteur Unix (lib/licensing_eval.awk) et le
# moteur Windows (windows/check_oracle_licensing.ps1).
#
# POURQUOI CE TEST EXISTE
#
# Windows n'a ni awk ni shell POSIX : la logique de conformite y est
# necessairement reimplementee. Deux implementations de la meme regle
# divergent toujours a terme, et une divergence ici signifie qu'un
# serveur Windows et un serveur Linux rendraient des verdicts differents
# sur des donnees identiques -- exactement ce qui ruine la credibilite
# d'un controle de licence.
#
# Ce test compare, sur les memes caches de reference, le code retour et
# la ligne de statut des deux moteurs.
#
# Necessite pwsh. Ignore proprement s'il est absent : Windows n'est pas
# testable partout, mais la suite Unix doit rester executable.
#
set -o nounset
set -o pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd); readonly ROOT
readonly SH_CHECK=$ROOT/bin/check_oracle_licensing.sh
readonly PS_CHECK=$ROOT/windows/check_oracle_licensing.ps1
readonly MAP=$ROOT/etc/licensable-features.map
readonly AWKF=$ROOT/lib/licensing_eval.awk
WORK=$(mktemp -d); readonly WORK
trap 'rm -rf "$WORK"' EXIT

PWSH=${PWSH:-$(command -v pwsh 2>/dev/null)}
if [[ -z ${PWSH:-} || ! -x ${PWSH:-} ]]; then
    echo "### Parite Unix/Windows ignoree (pwsh absent)"
    exit 0
fi

PASS=0; FAIL=0

mkcache() {
    local name=$1 age=${2:-300} epoch
    epoch=$(( $(date +%s) - age ))
    sed -e "s/@EPOCH@/$epoch/" -e "s/@DATE@/fixe/" \
        "$ROOT/tests/fixtures/${name}.dat.tmpl" > "$WORK/${name}.dat"
}

# Neutralise ce qui peut legitimement differer entre deux executions
# successives ou entre les deux plateformes.
normalise() {
    sed -e 's/cache_age=[0-9]*s/cache_age=Ns/g' \
        -e 's/il y a [0-9]* \(min\|h\|j\)/il y a N/g' \
        -e 's/(lscpu indisponible)/(inventaire indisponible)/g' \
        -e 's/(WMI indisponible)/(inventaire indisponible)/g'
}

compare() {
    local label=$1 sid=$2; shift 2
    local sh_out sh_rc ps_out ps_rc

    sh_out=$("$SH_CHECK" --cache-dir "$WORK" --map "$MAP" --awk "$AWKF" \
             --config /dev/null -s "$sid" "$@" 2>&1 | head -1 | normalise)
    sh_rc=${PIPESTATUS[0]}
    sh_rc=$("$SH_CHECK" --cache-dir "$WORK" --map "$MAP" --awk "$AWKF" \
             --config /dev/null -s "$sid" "$@" >/dev/null 2>&1; echo $?)

    # Traduction des options longues Unix vers les parametres PowerShell.
    local -a psargs=()
    while [[ $# -gt 0 ]]; do
        case $1 in
            -m|--mode)              psargs+=(-Mode "$2"); shift 2 ;;
            -w|--warning)           psargs+=(-WarnThreshold "$2"); shift 2 ;;
            -c|--critical)          psargs+=(-CritThreshold "$2"); shift 2 ;;
            --licensed-options)     psargs+=(-LicensedOptions "$2"); shift 2 ;;
            --licensed-processors)  psargs+=(-LicensedProcessors "$2"); shift 2 ;;
            --ignore-historical)    psargs+=(-IgnoreHistorical); shift ;;
            -v|--verbose)           psargs+=(-Detail); shift ;;
            *)                      shift ;;
        esac
    done

    ps_out=$("$PWSH" -NoProfile -File "$PS_CHECK" -Sid "$sid" \
             -CacheDir "$WORK" -MapFile "$MAP" -ConfigFile /dev/null \
             "${psargs[@]}" 2>&1 | head -1 | normalise)
    ps_rc=$("$PWSH" -NoProfile -File "$PS_CHECK" -Sid "$sid" \
             -CacheDir "$WORK" -MapFile "$MAP" -ConfigFile /dev/null \
             "${psargs[@]}" >/dev/null 2>&1; echo $?)

    if [[ $sh_rc == "$ps_rc" && $sh_out == "$ps_out" ]]; then
        printf '  ok   %-52s (rc=%s)\n' "$label" "$sh_rc"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL %-52s\n' "$label"
        [[ $sh_rc != "$ps_rc" ]] && printf '       rc  unix=%s windows=%s\n' "$sh_rc" "$ps_rc"
        if [[ $sh_out != "$ps_out" ]]; then
            printf '       unix    : %s\n' "$sh_out"
            printf '       windows : %s\n' "$ps_out"
        fi
        FAIL=$(( FAIL + 1 ))
    fi
}

echo "### Parite Unix/Windows ($("$PWSH" --version))"

for fx in ORCL SE2DB DB9I DB10G DOWNDB; do
    mkcache "$fx" 300
done

echo "== Mode options =="
compare "ORCL sans declaration"        ORCL  -m options
compare "ORCL declaration partielle"   ORCL  -m options --licensed-options "Partitioning"
compare "ORCL declaration complete"    ORCL  -m options --licensed-options "Partitioning,Diagnostics Pack,Multitenant,Advanced Compression,Tuning Pack"
compare "ORCL historique ignore"       ORCL  -m options --ignore-historical --licensed-options "Partitioning,Diagnostics Pack,Multitenant,Advanced Compression"
compare "SE2DB edition incompatible"   SE2DB -m options --licensed-options "Partitioning,Diagnostics Pack"
compare "DB9I usage indisponible"      DB9I  -m options
compare "DB10G Spatial encore payant"  DB10G -m options --licensed-options "Partitioning"
compare "DB10G Spatial declare"        DB10G -m options --licensed-options "Partitioning,Spatial and Graph"
compare "DOWNDB sans feature"          DOWNDB -m options

echo "== Mode processors =="
compare "ORCL conforme"                ORCL  -m processors --licensed-processors 32
compare "ORCL deficit"                 ORCL  -m processors --licensed-processors 16
compare "ORCL sans declaration"        ORCL  -m processors
compare "SE2DB 4 sockets"              SE2DB -m processors --licensed-processors 64
compare "DB9I inventaire OS"           DB9I  -m processors --licensed-processors 2

echo "== Mode sessions =="
compare "ORCL sous les seuils"         ORCL  -m sessions -w 2000 -c 3000
compare "ORCL warning"                 ORCL  -m sessions -w 1000 -c 3000
compare "ORCL critical"                ORCL  -m sessions -w 500  -c 1000
compare "DB9I sans HWM historique"     DB9I  -m sessions -w 5000 -c 9000
compare "DB10G HWM historique superieur" DB10G -m sessions -w 5000 -c 9000

echo "== Mode freshness =="
compare "ORCL cache frais"             ORCL   -m freshness
compare "DOWNDB instance arretee"      DOWNDB -m freshness
mkcache ORCL 300000
compare "ORCL cache tres perime"       ORCL   -m freshness
compare "ORCL options sur cache perime" ORCL  -m options --licensed-options "Partitioning,Diagnostics Pack,Multitenant,Advanced Compression,Tuning Pack"
mkcache ORCL 300

echo "== Mode inventory =="
compare "ORCL inventaire"              ORCL  -m inventory
compare "DB9I inventaire limite"       DB9I  -m inventory

echo "== Robustesse =="
compare "mode inconnu"                 ORCL  -m bidon

echo
printf 'Total : %d reussi(s), %d echec(s)\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
