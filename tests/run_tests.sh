#!/usr/bin/env bash
#
# Harnais de test du plugin check_oracle_licensing.sh.
#
# Aucune base Oracle requise : les tests s'appuient sur des caches de
# reference dans tests/fixtures/. C'est le principal benefice de
# l'architecture en deux etages -- la logique de conformite est testable
# hors production.
#
set -o nounset
set -o pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd); readonly ROOT
readonly CHECK=$ROOT/bin/check_oracle_licensing.sh
readonly MAP=$ROOT/etc/licensable-features.map
readonly AWKF=$ROOT/lib/licensing_eval.awk
readonly EVID=$ROOT/etc/structural-evidence.map
# Shell sous lequel exercer le plugin : permet de rejouer toute la suite
# sur bash 3.2 (RHEL 5) comme sur bash 5 (RHEL 9).
SHELL_UNDER_TEST=${SHELL_UNDER_TEST:-/bin/sh}
WORK=$(mktemp -d); readonly WORK
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0

# Materialise une fixture avec un horodatage de collecte donne.
mkcache() {
    local name=$1 age=${2:-300} epoch
    epoch=$(( $(date +%s) - age ))
    sed -e "s/@EPOCH@/$epoch/" \
        -e "s/@DATE@/$(date -d "@$epoch" '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || echo '-')/" \
        "$ROOT/tests/fixtures/${name}.dat.tmpl" > "$WORK/${name}.dat"
}

# Derive une fixture en appliquant des substitutions sed supplementaires,
# pour isoler un seul facteur a la fois dans un test.
mkcache_variant() {
    local src=$1 dst=$2; shift 2
    mkcache "$src" 300
    local -a seds=()
    local e; for e in "$@"; do seds+=(-e "$e"); done
    sed "${seds[@]}" "$WORK/${src}.dat" > "$WORK/${dst}.dat"
}

# assert_rc <attendu> <libelle> <arguments du plugin...>
assert_rc() {
    local want=$1 label=$2; shift 2
    local out rc
    out=$("$SHELL_UNDER_TEST" "$CHECK" --cache-dir "$WORK" --map "$MAP" --evidence "$EVID" --awk "$AWKF" --config /dev/null "$@" 2>&1)
    rc=$?
    if [[ $rc -eq $want ]]; then
        printf '  ok   %-58s (rc=%d)\n' "$label" "$rc"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL %-58s (attendu=%d obtenu=%d)\n' "$label" "$want" "$rc"
        printf '       %s\n' "${out%%$'\n'*}"; FAIL=$(( FAIL + 1 ))
    fi
}

# assert_out <motif> <libelle> <arguments...>
assert_out() {
    local pat=$1 label=$2; shift 2
    local out
    out=$("$SHELL_UNDER_TEST" "$CHECK" --cache-dir "$WORK" --map "$MAP" --evidence "$EVID" --awk "$AWKF" --config /dev/null "$@" 2>&1)
    if grep -qE -- "$pat" <<<"$out"; then
        printf '  ok   %-58s\n' "$label"; PASS=$(( PASS + 1 ))
    else
        printf '  FAIL %-58s\n' "$label"
        printf '       motif absent : %s\n' "$pat"
        printf '       sortie       : %s\n' "${out%%$'\n'*}"; FAIL=$(( FAIL + 1 ))
    fi
}

echo "== Mode options (shell: $SHELL_UNDER_TEST) =="
mkcache ORCL 300

assert_rc 2 "aucune option declaree -> CRITICAL" \
    -s ORCL -m options
assert_rc 2 "declaration partielle -> CRITICAL" \
    -s ORCL -m options --licensed-options "Partitioning"
assert_rc 1 "usage courant couvert, reste l'historique -> WARNING" \
    -s ORCL -m options \
    --licensed-options "Partitioning,Diagnostics Pack,Multitenant,Advanced Compression"
assert_rc 0 "declaration complete -> OK" \
    -s ORCL -m options \
    --licensed-options "Partitioning,Diagnostics Pack,Multitenant,Advanced Compression,Tuning Pack"
assert_rc 0 "historique ignore sur demande -> OK" \
    -s ORCL -m options --ignore-historical \
    --licensed-options "Partitioning,Diagnostics Pack,Multitenant,Advanced Compression"

echo "== Exactitude de la detection =="
assert_out 'Tuning Pack' "usage historique du Tuning Pack signale" \
    -s ORCL -m options \
    --licensed-options "Partitioning,Diagnostics Pack,Multitenant,Advanced Compression"
assert_out 'Advanced Compression' "Advanced Index Compression -> Advanced Compression" \
    -s ORCL -m options --licensed-options "Partitioning"
assert_out 'Multitenant' "3 PDB -> option Multitenant requise" \
    -s ORCL -m options --licensed-options "Partitioning"

echo "== Absence de faux positifs =="
for noise in 'Partitioning \(system\)' 'SecureFiles \(user\)' 'Java Virtual Machine' 'Spatial'; do
    out=$("$SHELL_UNDER_TEST" "$CHECK" --cache-dir "$WORK" --map "$MAP" --evidence "$EVID" --awk "$AWKF" \
          --config /dev/null -s ORCL -m options --licensed-options "Partitioning" 2>&1)
    if grep -qE -- "$noise" <<<"$out"; then
        printf '  FAIL %-58s\n' "faux positif : $noise"; FAIL=$(( FAIL + 1 ))
    else
        printf '  ok   %-58s\n' "pas de faux positif : $noise"; PASS=$(( PASS + 1 ))
    fi
done

echo "== Mode processors =="
assert_rc 0 "32 licences requises, 32 detenues -> OK" \
    -s ORCL -m processors --licensed-processors 32
assert_rc 2 "32 requises, 16 detenues -> CRITICAL" \
    -s ORCL -m processors --licensed-processors 16
assert_out 'deficit de 16' "deficit chiffre dans la sortie" \
    -s ORCL -m processors --licensed-processors 16
assert_out 'processor_licenses=32' "perfdata licences Processor" \
    -s ORCL -m processors

echo "== Mode sessions =="
assert_rc 0 "HWM 1180 sous les seuils -> OK"      -s ORCL -m sessions -w 2000 -c 3000
assert_rc 1 "HWM 1180 au-dessus du warning"       -s ORCL -m sessions -w 1000 -c 3000
assert_rc 2 "HWM 1180 au-dessus du critical"      -s ORCL -m sessions -w 500  -c 1000
assert_out 'nup_floor=800' "plancher NUP = 25 x 32 Processor" -s ORCL -m sessions

echo "== Mode freshness =="
assert_rc 0 "cache de 5 min -> OK" -s ORCL -m freshness
mkcache ORCL 100000    # ~27,7 h
assert_rc 1 "cache de 27 h -> WARNING" -s ORCL -m freshness
mkcache ORCL 300000    # ~3,5 j
assert_rc 2 "cache de 3 jours -> CRITICAL" -s ORCL -m freshness
assert_rc 1 "cache perime degrade aussi le mode options" \
    -s ORCL -m options \
    --licensed-options "Partitioning,Diagnostics Pack,Multitenant,Advanced Compression,Tuning Pack"

echo "== Mode inventory =="
mkcache ORCL 300
assert_rc 0 "inventory ne leve jamais d'alerte" -s ORCL -m inventory
assert_out 'EE 19.22.0.0.0' "edition et version restituees" -s ORCL -m inventory

echo "== Edition incompatible (SE2) =="
mkcache SE2DB 300
assert_rc 2 "option EE utilisee sur SE2 -> CRITICAL" \
    -s SE2DB -m options --licensed-options "Partitioning,Diagnostics Pack"
assert_out 'incompatible' "l'incompatibilite d'edition est nommee" \
    -s SE2DB -m options --licensed-options "Partitioning,Diagnostics Pack"
assert_out 'wrong_edition=[12]' "les options hors edition sortent du comptage normal" \
    -s SE2DB -m options --licensed-options "Partitioning,Diagnostics Pack"
assert_rc 2 "SE2 sur 4 sockets -> CRITICAL" \
    -s SE2DB -m processors --licensed-processors 64
assert_out '2 sockets' "la limite de 2 sockets de SE2 est rappelee" \
    -s SE2DB -m processors --licensed-processors 64
assert_out 'vmware' "l'hyperviseur est signale" -s SE2DB -m processors
# Meme hote virtualise, mais en EE et sur 2 sockets : plus rien ne doit
# peser sur le verdict hormis l'hyperviseur lui-meme.
mkcache_variant SE2DB VMEE 's/|db.edition|SE2/|db.edition|EE/' 's/|host.cpu.sockets|4/|host.cpu.sockets|2/'
assert_rc 1 "hyperviseur seul -> WARNING" \
    -s VMEE -m processors --licensed-processors 999
assert_rc 0 "hote physique conforme -> OK sans WARNING parasite" \
    -s ORCL -m processors --licensed-processors 999

echo "== Instance arretee =="
mkcache DOWNDB 300
assert_rc 1 "instance arretee -> WARNING en freshness" -s DOWNDB -m freshness
assert_out 'instance arretee' "l'etat arrete est explicite"  -s DOWNDB -m freshness
assert_rc 0 "aucune feature collectee -> pas de fausse alerte" -s DOWNDB -m options

echo "== Oracle 9i : controle par preuves structurelles =="
mkcache DB9I 300
# DBA_FEATURE_USAGE_STATISTICS n'existe pas avant 10.1, mais le
# dictionnaire, lui, existe depuis 8i : une table partitionnee prouve
# l'usage de Partitioning aussi surement qu'un releve MMON.
assert_rc 2 "9i : Partitioning prouve par le dictionnaire -> CRITICAL" -s DB9I -m options
assert_out 'Partitioning'      "9i : Partitioning nomme"            -s DB9I -m options
assert_out 'preuve structurelle' "9i : la nature de la preuve est dite" -s DB9I -m options
assert_out '24 objet'          "9i : le compte d'objets est chiffre" -s DB9I -m options
assert_out 'couverture partielle' "9i : la couverture partielle est annoncee" -s DB9I -m options
assert_out '10\.1'             "9i : la limite de version est rappelee" -s DB9I -m options
assert_rc 0 "9i : options declarees -> OK" -s DB9I -m options \
    --licensed-options "Partitioning,Spatial and Graph"
# Une option EE prouvee sur une edition qui ne la vend pas reste une
# anomalie structurelle, meme sans releve d'usage.
assert_out 'Spatial'           "9i : Spatial encore payant en 9.2"  -s DB9I -m options
assert_rc 0 "9i : inventory reste exploitable"     -s DB9I -m inventory
assert_out 'INDISPONIBLE' "9i : inventory signale la limite"        -s DB9I -m inventory
# V$LICENSE et l'inventaire OS existent depuis bien avant 9i.
assert_rc 0 "9i : sessions fonctionne (V\$LICENSE)"  -s DB9I -m sessions -w 5000 -c 9000
assert_out 'nup_floor=50' "9i : plancher NUP calcule (25 x 2)"      -s DB9I -m sessions
assert_rc 0 "9i : processors fonctionne (inventaire OS)" -s DB9I -m processors --licensed-processors 2
assert_rc 2 "9i : deficit Processor detecte"        -s DB9I -m processors --licensed-processors 1

echo "== Oracle 10g : gratuite dependante de la version =="
mkcache DB10G 300
# Spatial n'est inclus sans supplement qu'a partir de 12.2 : sur 10.2 il
# reste une option payante et doit etre signale.
assert_out 'Spatial' "10g : Spatial encore payant en 10.2"          -s DB10G -m options --licensed-options "Partitioning"
assert_rc 2 "10g : Spatial non declare -> CRITICAL"                 -s DB10G -m options --licensed-options "Partitioning"
assert_rc 0 "10g : Spatial declare -> OK"                           -s DB10G -m options --licensed-options "Partitioning,Spatial and Graph"
# La meme feature sur 19c ne doit plus rien declencher : c'est la
# comparaison de version qui fait la difference, pas le nom.
mkcache ORCL 300
assert_rc 0 "19c : la meme Spatial est gratuite" -s ORCL -m options \
    --licensed-options "Partitioning,Diagnostics Pack,Multitenant,Advanced Compression,Tuning Pack"

echo "== Oracle 11g : exposition aux management packs =="
mkcache DB11G 300
# CONTROL_MANAGEMENT_PACK_ACCESS vaut DIAGNOSTIC+TUNING par defaut en EE :
# une base neuve autorise les packs sans qu'ils soient achetes. C'est une
# porte ouverte, pas un usage constate -- donc WARNING, pas CRITICAL.
assert_rc 1 "11g : packs accessibles seuls -> WARNING" -s DB11G -m options \
    --licensed-options "Partitioning,Advanced Compression"
assert_out 'CONTROL_MANAGEMENT_PACK_ACCESS' "11g : le parametre en cause est nomme" \
    -s DB11G -m options --licensed-options "Partitioning,Advanced Compression"
assert_out 'positionnez le parametre a NONE' "11g : la remediation est donnee" \
    -s DB11G -m options --licensed-options "Partitioning,Advanced Compression"
assert_out 'exposed_packs=2' "11g : l'exposition est chiffree en perfdata" \
    -s DB11G -m options --licensed-options "Partitioning,Advanced Compression"
# Packs declares : plus d'exposition a signaler.
assert_rc 0 "11g : packs declares -> OK" -s DB11G -m options \
    --licensed-options "Partitioning,Advanced Compression,Diagnostics Pack,Tuning Pack"
# Un usage avere prime sur la simple exposition.
assert_rc 2 "11g : usage avere -> CRITICAL malgre l'exposition" -s DB11G -m options

echo "== Oracle 11g : preuves propres a la version =="
# Advanced Compression n'apparait dans aucun releve d'usage ici : seules
# les preuves structurelles la revelent. C'est tout l'interet du recoupement.
assert_out 'oltp_compressed_tables' "11g : compression OLTP detectee" -s DB11G -m options
assert_out 'securefile_compressed'  "11g : LOB SecureFile compresses detectes" -s DB11G -m options
assert_out 'Advanced Compression'   "11g : rattachee a la bonne option" -s DB11G -m options

echo "== Robustesse =="
assert_rc 3 "SID inconnu -> UNKNOWN"   -s NOPE -m options
assert_rc 3 "mode inconnu -> UNKNOWN"  -s ORCL -m bidon
assert_rc 3 "SID manquant -> UNKNOWN"  -m options

echo
printf 'Total : %d reussi(s), %d echec(s)\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
