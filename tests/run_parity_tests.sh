#!/usr/bin/env bash
#
# Test de parite entre les trois moteurs d'evaluation :
#   - Unix     : lib/licensing_eval.awk
#   - Windows  : windows/check_oracle_licensing.ps1  (PowerShell 2.0+)
#   - Windows  : windows/check_oracle_licensing.vbs  (Windows Script Host)
#
# POURQUOI CE TEST EXISTE
#
# Windows n'a ni awk ni shell POSIX : la logique de conformite y est
# necessairement reimplementee. Trois implementations de la meme regle
# divergent toujours a terme, et une divergence ici signifie que deux
# serveurs rendraient des verdicts differents sur des donnees
# identiques -- exactement ce qui ruine la credibilite d'un controle de
# licence.
#
# La variante VBScript existe parce que Windows Server 2003 n'embarque
# aucun PowerShell, et parce que cscript s'execute la ou les strategies
# de groupe interdisent "-ExecutionPolicy Bypass".
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
readonly EVID=$ROOT/etc/structural-evidence.map
WORK=$(mktemp -d); readonly WORK
trap 'rm -rf "$WORK"' EXIT

readonly VBS_CHECK=$ROOT/windows/check_oracle_licensing.vbs

PWSH=${PWSH:-$(command -v pwsh 2>/dev/null)}
HAVE_PS=0
[[ -n ${PWSH:-} && -x ${PWSH:-} ]] && HAVE_PS=1

# cscript via wine : permet d'executer reellement le moteur VBScript
# hors de Windows. Wine n'implemente pas tout Windows Script Host, mais
# le moteur a ete ecrit pour ne dependre que du sous-ensemble commun.
WINE=${WINE:-$(command -v wine64 2>/dev/null || command -v wine 2>/dev/null)}
[[ -z ${WINE:-} && -x /usr/lib/wine/wine64 ]] && WINE=/usr/lib/wine/wine64
HAVE_VBS=0
if [[ -n ${WINE:-} && -x ${WINE:-} ]]; then
    export WINEDEBUG=${WINEDEBUG:--all}
    export WINEPREFIX=${WINEPREFIX:-$WORK/wineprefix}
    # wine exige un HOME accessible en ecriture pour son prefixe.
    export HOME=${HOME:-/root}
    HAVE_VBS=1
fi

if [[ $HAVE_PS -eq 0 && $HAVE_VBS -eq 0 ]]; then
    echo "### Parite entre moteurs ignoree (ni pwsh ni wine)"
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
# successives ou entre les plateformes.
#
# Les messages de validation nomment l'option dans la syntaxe propre a
# chaque plateforme -- "--warning", "-WarnThreshold", "/Warning". C'est
# voulu : un exploitant Windows doit lire la syntaxe qu'il tape. La
# parite porte sur le verdict, pas sur la forme de l'appel.
normalise() {
    sed -e 's/cache_age=-\?[0-9]*s/cache_age=Ns/g' \
        -e 's/il y a [0-9]* \(min\|h\|j\)/il y a N/g' \
        -e 's/(lscpu indisponible)/(inventaire indisponible)/g' \
        -e 's/(WMI indisponible)/(inventaire indisponible)/g' \
        -e 's/^UNKNOWN - [-/][A-Za-z-]* invalide/UNKNOWN - <option> invalide/' \
        -e 's/dans le futur de [0-9]* \(min\|h\|j\)/dans le futur de N/'
}

compare() {
    local label=$1 sid=$2; shift 2
    local sh_out sh_rc ps_out ps_rc vbs_out vbs_rc diverged=0

    sh_out=$("$SH_CHECK" --cache-dir "$WORK" --map "$MAP" --evidence "$EVID" --awk "$AWKF" \
             --config /dev/null -s "$sid" "$@" 2>&1 | head -1 | normalise)
    sh_rc=$("$SH_CHECK" --cache-dir "$WORK" --map "$MAP" --evidence "$EVID" --awk "$AWKF" \
             --config /dev/null -s "$sid" "$@" >/dev/null 2>&1; echo $?)

    # Traduction des options longues Unix vers chaque syntaxe cible.
    local -a psargs=() vbsargs=()
    while [[ $# -gt 0 ]]; do
        case $1 in
            -m|--mode)              psargs+=(-Mode "$2");               vbsargs+=("/Mode:$2"); shift 2 ;;
            -w|--warning)           psargs+=(-WarnThreshold "$2");      vbsargs+=("/Warning:$2"); shift 2 ;;
            -c|--critical)          psargs+=(-CritThreshold "$2");      vbsargs+=("/Critical:$2"); shift 2 ;;
            --licensed-options)     psargs+=(-LicensedOptions "$2");    vbsargs+=("/LicensedOptions:$2"); shift 2 ;;
            --licensed-processors)  psargs+=(-LicensedProcessors "$2"); vbsargs+=("/LicensedProcessors:$2"); shift 2 ;;
            --ignore-historical)    psargs+=(-IgnoreHistorical);        vbsargs+=("/IgnoreHistorical"); shift ;;
            -v|--verbose)           psargs+=(-Detail);                  vbsargs+=("/Detail"); shift ;;
            *)                      shift ;;
        esac
    done

    if [[ $HAVE_PS -eq 1 ]]; then
        ps_out=$("$PWSH" -NoProfile -File "$PS_CHECK" -Sid "$sid" \
                 -CacheDir "$WORK" -MapFile "$MAP" -EvidenceFile "$EVID" -ConfigFile /dev/null \
                 "${psargs[@]}" 2>&1 | head -1 | normalise)
        ps_rc=$("$PWSH" -NoProfile -File "$PS_CHECK" -Sid "$sid" \
                 -CacheDir "$WORK" -MapFile "$MAP" -EvidenceFile "$EVID" -ConfigFile /dev/null \
                 "${psargs[@]}" >/dev/null 2>&1; echo $?)
        if [[ $sh_rc != "$ps_rc" || $sh_out != "$ps_out" ]]; then
            diverged=1
            printf '  FAIL %-52s\n' "$label"
            [[ $sh_rc != "$ps_rc" ]] && printf '       rc     awk=%s ps=%s\n' "$sh_rc" "$ps_rc"
            [[ $sh_out != "$ps_out" ]] && {
                printf '       awk        : %s\n' "$sh_out"
                printf '       powershell : %s\n' "$ps_out"; }
        fi
    fi

    if [[ $HAVE_VBS -eq 1 ]]; then
        # cscript n'accepte que des chemins Windows : Z: est monte sur /.
        vbs_out=$("$WINE" cscript //NoLogo "Z:$VBS_CHECK" "/Sid:$sid" \
                  "/CacheDir:Z:$WORK" "/MapFile:Z:$MAP" "/EvidenceFile:Z:$EVID" "/ConfigFile:Z:/dev/null" \
                  "${vbsargs[@]}" 2>/dev/null | head -1 | tr -d '\r' | normalise)
        vbs_rc=$("$WINE" cscript //NoLogo "Z:$VBS_CHECK" "/Sid:$sid" \
                  "/CacheDir:Z:$WORK" "/MapFile:Z:$MAP" "/EvidenceFile:Z:$EVID" "/ConfigFile:Z:/dev/null" \
                  "${vbsargs[@]}" >/dev/null 2>&1; echo $?)
        if [[ $sh_rc != "$vbs_rc" || $sh_out != "$vbs_out" ]]; then
            [[ $diverged -eq 0 ]] && printf '  FAIL %-52s\n' "$label"
            diverged=1
            [[ $sh_rc != "$vbs_rc" ]] && printf '       rc     awk=%s vbs=%s\n' "$sh_rc" "$vbs_rc"
            [[ $sh_out != "$vbs_out" ]] && {
                printf '       awk        : %s\n' "$sh_out"
                printf '       vbscript   : %s\n' "$vbs_out"; }
        fi
    fi

    if [[ $diverged -eq 0 ]]; then
        printf '  ok   %-52s (rc=%s)\n' "$label" "$sh_rc"; PASS=$(( PASS + 1 ))
    else
        FAIL=$(( FAIL + 1 ))
    fi
}

engines="awk"
[[ $HAVE_PS  -eq 1 ]] && engines="$engines + $("$PWSH" --version)"
[[ $HAVE_VBS -eq 1 ]] && engines="$engines + VBScript (cscript via wine)"
echo "### Parite entre moteurs : $engines"

for fx in ORCL SE2DB DB9I DB10G DB11G DB12C DB18C DB21C DOWNDB; do
    mkcache "$fx" 300
done

echo "== Mode options =="
compare "ORCL sans declaration"        ORCL  -m options
compare "ORCL declaration partielle"   ORCL  -m options --licensed-options "Partitioning"
compare "ORCL declaration complete"    ORCL  -m options --licensed-options "Partitioning,Diagnostics Pack,Multitenant,Advanced Compression,Tuning Pack"
compare "ORCL historique ignore"       ORCL  -m options --ignore-historical --licensed-options "Partitioning,Diagnostics Pack,Multitenant,Advanced Compression"
compare "SE2DB edition incompatible"   SE2DB -m options --licensed-options "Partitioning,Diagnostics Pack"
compare "DB9I preuves structurelles"   DB9I  -m options
compare "DB9I preuves declarees"      DB9I  -m options --licensed-options "Partitioning,Spatial and Graph"
compare "DB10G Spatial encore payant"  DB10G -m options --licensed-options "Partitioning"
compare "DB10G Spatial declare"        DB10G -m options --licensed-options "Partitioning,Spatial and Graph"
compare "DB11G exposition packs"       DB11G -m options --licensed-options "Partitioning,Advanced Compression"
compare "DB11G packs declares"         DB11G -m options --licensed-options "Partitioning,Advanced Compression,Diagnostics Pack,Tuning Pack"
compare "DB11G usage avere"            DB11G -m options
compare "DB12C Multitenant 2 PDB"      DB12C -m options --licensed-options "Partitioning"
compare "DB12C tout declare"           DB12C -m options --licensed-options "Partitioning,Database In-Memory,Advanced Security,Advanced Compression,Multitenant"
compare "ORCL 19c 3 PDB incluses"      ORCL  -m options --licensed-options "Partitioning,Diagnostics Pack,Advanced Compression,Tuning Pack"
compare "DB18C seuil de 12.2"          DB18C -m options --licensed-options "Partitioning"
compare "DB18C tout declare"           DB18C -m options --licensed-options "Partitioning,Database Vault,Multitenant"
compare "DB21C In-Memory Base Level"   DB21C -m options --licensed-options "Partitioning"
compare "DB21C inventaire"             DB21C -m inventory
compare "DOWNDB instance arretee"      DOWNDB -m options

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

echo "== Cache inexploitable =="
printf 'KV|collect.epoch|%s\nKV|db.name|FAILED\nKV|collect.status|query_failed\n' \
    "$(( $(date +%s) - 300 ))" > "$WORK/FAILED.dat"
compare "collecte en echec"            FAILED -m options
compare "collecte en echec, processors" FAILED -m processors
compare "inventaire sur donnees incompletes" FAILED -m inventory

echo "== Horodatage aberrant =="
# Un cache date du futur trahit une horloge decalee ou un calcul
# d'epoque errone -- risque reel cote VBScript, ou le fuseau vient de WMI.
printf 'KV|collect.epoch|%s\nKV|db.name|FUT\nKV|inst.version|19.22.0.0.0\nKV|db.edition|EE\nKV|collect.sql_complete|1\nKV|collect.status|ok\nKV|host.cpu.cores|8\nKV|host.processor_licenses|4\n' \
    "$(( $(date +%s) + 7200 ))" > "$WORK/FUT.dat"
compare "cache date du futur"          FUT   -m freshness

echo "== Validation des entrees =="
compare "seuil non numerique"          ORCL  -m sessions -w abc -c 99999
compare "processors non numerique"     ORCL  -m processors --licensed-processors x1

echo "== Robustesse =="
compare "mode inconnu"                 ORCL  -m bidon

echo
printf 'Total : %d reussi(s), %d echec(s)\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
