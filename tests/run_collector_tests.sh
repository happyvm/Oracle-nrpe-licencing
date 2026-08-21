#!/usr/bin/env bash
#
# Tests du collecteur, avec sqlplus et oratab simules.
#
# Le collecteur n'etait couvert par aucun test. Ceux-ci verrouillent le
# nommage des fichiers de cache, l'ecriture atomique, les filtres
# d'instances et le traitement multi-instances.
#
# Note : l'assertion sur l'absence de "<cache>/.dat" est un filet, pas la
# preuve d'une regression passee. Le defaut d'affectation "local"
# signale en SC2318 etait masque par la portee dynamique de bash, donc
# inobservable par ce chemin.
#
set -o nounset
set -o pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd); readonly ROOT
readonly COLLECTOR=$ROOT/bin/oracle_licensing_collector.sh
WORK=$(mktemp -d); readonly WORK
declare -a FAKE_PMON=()
cleanup() {
    # Tuer le bash parent ne suffit pas : son "sleep" enfant survivrait
    # et retiendrait tout tube herite. On cible les deux par motif.
    pkill -f "$WORK/ora_pmon_" 2>/dev/null
    local p; for p in "${FAKE_PMON[@]:-}"; do [[ -n $p ]] && kill "$p" 2>/dev/null; done
    wait 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

PASS=0; FAIL=0
ok()   { printf '  ok   %-58s\n' "$1"; PASS=$(( PASS + 1 )); }
bad()  { printf '  FAIL %-58s\n' "$1"; [[ $# -gt 1 ]] && printf '       %s\n' "$2"; FAIL=$(( FAIL + 1 )); }

# --- Faux ORACLE_HOME : un sqlplus qui rejoue une sortie preparee ------
make_home() {
    local sid=$1
    local home=$WORK/oh_$sid
    mkdir -p "$home/bin"
    cat > "$home/bin/sqlplus" <<EOS
#!/usr/bin/env bash
# Stub sqlplus : consomme le heredoc et rejoue une reponse figee.
cat > /dev/null
cat "$WORK/reply_$sid.txt"
EOS
    chmod +x "$home/bin/sqlplus"
    printf '%s' "$home"
}

# --- Faux processus pmon, pour que instance_is_running() reponde vrai --
start_fake_pmon() {
    local sid=$1
    local script=$WORK/ora_pmon_$sid
    printf '#!/usr/bin/env bash\nsleep 300\n' > "$script"
    chmod +x "$script"
    "$script" >/dev/null 2>&1 </dev/null & FAKE_PMON+=("$!")
    # pgrep -f cherche "ora_pmon_<SID>" en fin de ligne de commande.
    local attempt
    for attempt in $(seq 10); do
        pgrep -f "ora_pmon_${sid}\$" >/dev/null 2>&1 && return 0
        : "$attempt"
        sleep 0.2
    done
    return 1
}

echo "== Preparation =="
H1=$(make_home PROD1); H2=$(make_home PROD2)
cat > "$WORK/reply_PROD1.txt" <<'EOS'

KV|db.name|PROD1
KV|db.edition|EE
KV|inst.version|19.22.0.0.0
OPT|Partitioning|TRUE
FEAT|Partitioning (user)|TRUE|500|2026-08-20|2020-01-01|4
HWM|SESSIONS|900|300
KV|collect.sql_complete|1
EOS
cat > "$WORK/reply_PROD2.txt" <<'EOS'

KV|db.name|PROD2
KV|db.edition|SE2
KV|inst.version|19.21.0.0.0
OPT|Partitioning|FALSE
KV|collect.sql_complete|1
EOS

cat > "$WORK/oratab" <<EOS
# commentaires et entrees d'infrastructure a ignorer
+ASM:/u01/grid:N
-MGMTDB:/u01/grid:N
*:/u01/dummy:N
PROD1:$H1:Y
PROD2:$H2:Y
GHOST:/inexistant/home:Y
EOS

if start_fake_pmon PROD1 && start_fake_pmon PROD2; then
    ok "faux processus pmon demarres"
else
    bad "impossible de simuler pmon" "tests du collecteur ignores"; exit 1
fi

echo "== Collecte =="
CACHE=$WORK/cache
cat > "$WORK/conf" <<EOS
CACHE_DIR=$CACHE
SQL_FILE=$ROOT/sql/collect_licensing.sql
ORATAB=$WORK/oratab
CACHE_GROUP=$(id -gn)
SQLPLUS_TIMEOUT=30
EOS
out=$("$COLLECTOR" --config "$WORK/conf" -v 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "collecte terminee sans echec (rc=0)" \
                || bad "collecte en echec (rc=$rc)" "${out##*$'\n'}"

echo "== Nommage des fichiers de cache =="
# Un chemin de cache mal construit se traduirait par un unique fichier
# ".dat" partage par toutes les instances.
[[ -f $CACHE/PROD1.dat ]] && ok "PROD1.dat cree" || bad "PROD1.dat absent"
[[ -f $CACHE/PROD2.dat ]] && ok "PROD2.dat cree" || bad "PROD2.dat absent"
[[ -e $CACHE/.dat ]] && bad "fichier '.dat' parasite (chemin de cache errone)" \
                     || ok "aucun fichier '.dat' parasite"
[[ -e $CACHE/GHOST.dat ]] && bad "ORACLE_HOME inexistant traite quand meme" \
                          || ok "entree a ORACLE_HOME inexistant ecartee"
for skip in +ASM -MGMTDB '*'; do
    [[ -e $CACHE/${skip}.dat ]] && bad "entree $skip non ignoree" \
                                || ok "entree $skip ignoree"
done
# Aucun fichier temporaire ne doit subsister apres un rename() reussi.
leftovers=$(find "$CACHE" -name '*.dat.*' | wc -l)
[[ $leftovers -eq 0 ]] && ok "aucun fichier temporaire residuel" \
                       || bad "$leftovers fichier(s) temporaire(s) residuel(s)"

echo "== Contenu des caches =="
grep -q '^KV|db.name|PROD1$'      "$CACHE/PROD1.dat" && ok "PROD1 : identite base"      || bad "PROD1 : identite base"
grep -q '^KV|db.name|PROD2$'      "$CACHE/PROD2.dat" && ok "PROD2 : identite base"      || bad "PROD2 : identite base"
grep -q '^KV|inst.sid|PROD1$'     "$CACHE/PROD1.dat" && ok "PROD1 : SID"                || bad "PROD1 : SID"
grep -q '^KV|collect.status|ok$'  "$CACHE/PROD1.dat" && ok "PROD1 : statut ok"          || bad "PROD1 : statut ok"
grep -q '^KV|host.cpu.cores|'     "$CACHE/PROD1.dat" && ok "PROD1 : inventaire CPU"     || bad "PROD1 : inventaire CPU"
grep -q '^KV|host.processor_licenses|' "$CACHE/PROD1.dat" && ok "PROD1 : licences calculees" || bad "PROD1 : licences calculees"
grep -q '^FEAT|Partitioning (user)|' "$CACHE/PROD1.dat" && ok "PROD1 : features remontees" || bad "PROD1 : features remontees"
# Chaque cache doit porter SES donnees, pas celles du voisin.
grep -q 'PROD1' "$CACHE/PROD2.dat" && bad "fuite de PROD1 dans le cache PROD2" \
                                  || ok "pas de fuite entre instances"

echo "== Filtres INCLUDE / EXCLUDE =="
rm -rf "$CACHE"
"$COLLECTOR" --config "$WORK/conf" -s PROD1 >/dev/null 2>&1
[[ -f $CACHE/PROD1.dat && ! -f $CACHE/PROD2.dat ]] \
    && ok "--sid restreint bien la collecte" || bad "--sid sans effet"

rm -rf "$CACHE"
echo 'EXCLUDE_SIDS="PROD2"' >> "$WORK/conf"
"$COLLECTOR" --config "$WORK/conf" >/dev/null 2>&1
[[ -f $CACHE/PROD1.dat && ! -f $CACHE/PROD2.dat ]] \
    && ok "EXCLUDE_SIDS respecte" || bad "EXCLUDE_SIDS sans effet"

echo "== Mode dry-run =="
rm -rf "$CACHE"
out=$("$COLLECTOR" --config "$WORK/conf" -n 2>/dev/null)
[[ ! -d $CACHE ]] && ok "--dry-run n'ecrit rien sur disque" || bad "--dry-run a ecrit dans le cache"
grep -q '^KV|db.name|PROD1$' <<<"$out" && ok "--dry-run emet sur stdout" || bad "--dry-run muet"

echo "== Instance arretee =="
rm -rf "$CACHE"
cat > "$WORK/oratab" <<EOS
STOPPED:$H1:Y
EOS
sed -i '/EXCLUDE_SIDS/d' "$WORK/conf"
"$COLLECTOR" --config "$WORK/conf" >/dev/null 2>&1
grep -q '^KV|collect.status|instance_down$' "$CACHE/STOPPED.dat" 2>/dev/null \
    && ok "instance arretee : fiche publiee avec le bon statut" \
    || bad "instance arretee : statut incorrect"

echo
printf 'Total : %d reussi(s), %d echec(s)\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
