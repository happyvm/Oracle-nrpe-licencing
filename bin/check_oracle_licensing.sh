#!/bin/sh
#
# check_oracle_licensing.sh
#
# Plugin Nagios/NRPE de controle de conformite des licences Oracle.
#
# Ne se connecte PAS a la base : il lit le cache produit par
# oracle_licensing_collector.sh. L'execution est immediate et tient
# largement dans le timeout NRPE de 10 secondes.
#
# PORTABILITE
#
# Ecrit en shell POSIX, sans aucune construction bash : le parc cible
# couvre RHEL 5 a 9, soit bash 3.2 a 5.1. Les tableaux associatifs
# exigent bash 4.0 et les references nommees bash 4.3, ce qui exclurait
# RHEL 5, 6 et 7. Toute la logique d'evaluation vit donc dans
# lib/licensing_eval.awk, et ce script se limite a la glue.
#
# Codes retour Nagios : 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN.
#

PROGNAME=`basename "$0"`
VERSION=1.1.0
UNKNOWN=3

# Emplacements par defaut, surchargeables par la configuration.
CONFIG_FILE=${ORACLE_LICENSING_CONF:-/etc/oracle-licensing/oracle-licensing.conf}
CACHE_DIR=/var/cache/oracle-licensing
MAP_FILE=/etc/oracle-licensing/licensable-features.map
EVIDENCE_FILE=/etc/oracle-licensing/structural-evidence.map
AWK_FILE=/usr/lib/oracle-licensing/licensing_eval.awk
SID=
MODE=options
WARN=
CRIT=
LICENSED_OPTIONS=
LICENSED_PROCESSORS=
MAX_CACHE_AGE=93600
IGNORE_HISTORICAL=0
VERBOSE=0

usage() {
    cat <<EOF
Usage: $PROGNAME -s SID [-m MODE] [options]

Controle la conformite des licences Oracle a partir du cache local.

  -s, --sid SID           Instance a controler (obligatoire)
  -m, --mode MODE         options | processors | sessions | freshness | inventory
                          (defaut: options)
  -w, --warning SEUIL     Seuil warning (selon le mode)
  -c, --critical SEUIL    Seuil critical (selon le mode)
      --licensed-options L    Options detenues, separees par des virgules
      --licensed-processors N Nombre de licences Processor detenues
      --max-cache-age S   Age maximal du cache en secondes (defaut: $MAX_CACHE_AGE)
      --ignore-historical Ne signaler que les options en cours d'utilisation
      --cache-dir REP     Repertoire de cache
      --map FICHIER       Table de correspondance des features
      --evidence FICHIER  Table des preuves structurelles
      --awk FICHIER       Moteur d'evaluation awk
      --config FICHIER    Fichier de configuration
  -v, --verbose           Detailler chaque option en sortie longue
  -V, --version           Version
  -h, --help              Cette aide

Modes :
  options     Compare les options payantes utilisees aux options detenues.
              Combine le releve d'usage (DBA_FEATURE_USAGE_STATISTICS,
              Oracle 10.1+) et les preuves structurelles du dictionnaire,
              seules disponibles sur 9i.
  processors  Licences Processor calculees contre licences detenues.
  sessions    High-water mark de sessions, plancher NUP.
  freshness   Verifie que le collecteur tourne encore.
  inventory   Restitue l'inventaire sans emettre d'alerte.
EOF
}

die_unknown() {
    echo "UNKNOWN - $*"
    exit $UNKNOWN
}

# --- Arguments -------------------------------------------------------
cli_licensed_options=
cli_licensed_processors=
while [ $# -gt 0 ]; do
    case $1 in
        -s|--sid)              SID=$2; shift 2 ;;
        -m|--mode)             MODE=$2; shift 2 ;;
        -w|--warning)          WARN=$2; shift 2 ;;
        -c|--critical)         CRIT=$2; shift 2 ;;
        --licensed-options)    cli_licensed_options=$2; shift 2 ;;
        --licensed-processors) cli_licensed_processors=$2; shift 2 ;;
        --max-cache-age)       MAX_CACHE_AGE=$2; shift 2 ;;
        --ignore-historical)   IGNORE_HISTORICAL=1; shift ;;
        --cache-dir)           CACHE_DIR=$2; shift 2 ;;
        --map)                 MAP_FILE=$2; shift 2 ;;
        --evidence)            EVIDENCE_FILE=$2; shift 2 ;;
        --awk)                 AWK_FILE=$2; shift 2 ;;
        --config)              CONFIG_FILE=$2; shift 2 ;;
        -v|--verbose)          VERBOSE=1; shift ;;
        -V|--version)          echo "$PROGNAME $VERSION"; exit 0 ;;
        -h|--help)             usage; exit 0 ;;
        *)                     die_unknown "argument inconnu : $1" ;;
    esac
done

# La configuration ne doit jamais ecraser un argument explicite.
if [ -r "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
fi
[ -n "$cli_licensed_options" ]    && LICENSED_OPTIONS=$cli_licensed_options
[ -n "$cli_licensed_processors" ] && LICENSED_PROCESSORS=$cli_licensed_processors

[ -n "$SID" ] || die_unknown "option -s/--sid obligatoire"

CACHE_FILE=$CACHE_DIR/$SID.dat
[ -r "$CACHE_FILE" ] || die_unknown "cache absent ou illisible : $CACHE_FILE (le collecteur a-t-il tourne ?)"
[ -r "$MAP_FILE" ]   || die_unknown "table de correspondance illisible : $MAP_FILE"
[ -r "$EVIDENCE_FILE" ] || die_unknown "table des preuves structurelles illisible : $EVIDENCE_FILE"
[ -r "$AWK_FILE" ]   || die_unknown "moteur d'evaluation illisible : $AWK_FILE"

# Choix de l'interpreteur awk : nawk est prefere sur les Unix ou "awk"
# designe encore l'implementation historique, sans fonctions definies
# par l'utilisateur.
AWK="awk"
if command -v nawk >/dev/null 2>&1; then
    AWK="nawk"
fi
command -v "$AWK" >/dev/null 2>&1 || die_unknown "awk introuvable"

NOW=`date +%s`

"$AWK" \
    -v mode="$MODE" \
    -v sid="$SID" \
    -v now="$NOW" \
    -v max_cache_age="$MAX_CACHE_AGE" \
    -v licensed_options="$LICENSED_OPTIONS" \
    -v licensed_processors="$LICENSED_PROCESSORS" \
    -v warn="$WARN" \
    -v crit="$CRIT" \
    -v ignore_historical="$IGNORE_HISTORICAL" \
    -v verbose="$VERBOSE" \
    -f "$AWK_FILE" \
    "$MAP_FILE" "$EVIDENCE_FILE" "$CACHE_FILE"
exit $?
