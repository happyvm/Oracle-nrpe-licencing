#!/usr/bin/env bash
#
# check_oracle_licensing.sh
#
# Plugin Nagios/NRPE de controle de conformite des licences Oracle.
#
# Ne se connecte PAS a la base : il lit le cache produit par
# oracle_licensing_collector.sh. L'execution est donc immediate et tient
# largement dans le timeout NRPE de 10 secondes.
#
# Codes retour Nagios : 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN.
#
set -o nounset
set -o pipefail

readonly PROGNAME=${0##*/}
readonly VERSION=1.0.0
readonly OK=0 WARNING=1 CRITICAL=2 UNKNOWN=3

CONFIG_FILE=${ORACLE_LICENSING_CONF:-/etc/oracle-licensing/oracle-licensing.conf}
CACHE_DIR=/var/cache/oracle-licensing
MAP_FILE=/etc/oracle-licensing/licensable-features.map
SID=
MODE=options
WARN=
CRIT=
LICENSED_OPTIONS=
LICENSED_PROCESSORS=
MAX_CACHE_AGE=93600          # 26 h : tolere un decalage du run quotidien
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
      --licensed-options L  Liste des options detenues, separees par des
                          virgules. Ex: "Partitioning,Diagnostics Pack"
      --licensed-processors N  Nombre de licences Processor detenues
      --max-cache-age S   Age maximal du cache en secondes (defaut: $MAX_CACHE_AGE)
      --ignore-historical Ne signaler que les options en cours d'utilisation
      --cache-dir REP     Repertoire de cache (defaut: $CACHE_DIR)
      --map FICHIER       Table de correspondance (defaut: $MAP_FILE)
      --config FICHIER    Fichier de configuration
  -v, --verbose           Detailler chaque option en sortie longue
  -V, --version           Version
  -h, --help              Cette aide

Modes :
  options     Compare les options payantes reellement utilisees aux
              options declarees detenues. CRITICAL sur usage non couvert.
  processors  Compare les licences Processor calculees (coeurs x facteur)
              aux licences detenues.
  sessions    Surveille le high-water mark de sessions (dimensionnement NUP).
  freshness   Verifie que le collecteur tourne encore.
  inventory   Restitue l'inventaire sans emettre d'alerte.
EOF
}

die_unknown() { printf 'UNKNOWN - %s\n' "$*"; exit $UNKNOWN; }

# ----------------------------------------------------------------------
# Arguments
# ----------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--sid)                 SID=${2:?}; shift 2 ;;
        -m|--mode)                MODE=${2:?}; shift 2 ;;
        -w|--warning)             WARN=${2:?}; shift 2 ;;
        -c|--critical)            CRIT=${2:?}; shift 2 ;;
        --licensed-options)       LICENSED_OPTIONS=${2:?}; shift 2 ;;
        --licensed-processors)    LICENSED_PROCESSORS=${2:?}; shift 2 ;;
        --max-cache-age)          MAX_CACHE_AGE=${2:?}; shift 2 ;;
        --ignore-historical)      IGNORE_HISTORICAL=1; shift ;;
        --cache-dir)              CACHE_DIR=${2:?}; shift 2 ;;
        --map)                    MAP_FILE=${2:?}; shift 2 ;;
        --config)                 CONFIG_FILE=${2:?}; shift 2 ;;
        -v|--verbose)             VERBOSE=1; shift ;;
        -V|--version)             printf '%s %s\n' "$PROGNAME" "$VERSION"; exit 0 ;;
        -h|--help)                usage; exit 0 ;;
        *)                        die_unknown "argument inconnu : $1" ;;
    esac
done

# La configuration ne doit jamais ecraser un argument explicite : on
# memorise ce qui vient de la ligne de commande avant de la sourcer.
_cli_licensed_options=$LICENSED_OPTIONS
_cli_licensed_processors=$LICENSED_PROCESSORS
if [[ -r $CONFIG_FILE ]]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi
[[ -n $_cli_licensed_options ]]    && LICENSED_OPTIONS=$_cli_licensed_options
[[ -n $_cli_licensed_processors ]] && LICENSED_PROCESSORS=$_cli_licensed_processors

[[ -n $SID ]] || die_unknown "option -s/--sid obligatoire"

readonly CACHE_FILE=$CACHE_DIR/${SID}.dat
[[ -r $CACHE_FILE ]] || die_unknown "cache absent ou illisible : $CACHE_FILE (le collecteur a-t-il tourne ?)"

# ----------------------------------------------------------------------
# Chargement du cache
# ----------------------------------------------------------------------
declare -A KV=()                       # cle scalaire   -> valeur
declare -A OPTV=()                     # option binaire -> TRUE/FALSE
declare -A FEAT_USED=() FEAT_DET=() FEAT_LAST=() FEAT_FIRST=() FEAT_AUX=()
declare -A HWM=()

load_cache() {
    local rtype a b c d e f
    while IFS='|' read -r rtype a b c d e f; do
        case $rtype in
            KV)   KV[$a]=$b ;;
            OPT)  OPTV[$a]=$b ;;
            FEAT) FEAT_USED[$a]=$b; FEAT_DET[$a]=$c
                  FEAT_LAST[$a]=$d;  FEAT_FIRST[$a]=$e; FEAT_AUX[$a]=${f:-0} ;;
            HWM)  HWM[$a]=$b ;;
        esac
    done < <(grep -E '^(KV|OPT|FEAT|HWM)\|' "$CACHE_FILE")
}
load_cache

kv() { printf '%s' "${KV[$1]:-${2:-}}"; }

DB_NAME=$(kv db.name "$SID");                readonly DB_NAME
DB_EDITION=$(kv db.edition UNKNOWN);         readonly DB_EDITION
DB_VERSION=$(kv inst.version 0);             readonly DB_VERSION
COLLECT_STATUS=$(kv collect.status unknown); readonly COLLECT_STATUS
COLLECT_EPOCH=$(kv collect.epoch 0);         readonly COLLECT_EPOCH

# ----------------------------------------------------------------------
# Comparaison de versions Oracle ("19.22.0.0.0" >= "12.2")
# Les composants absents comptent pour zero, donc "19" >= "12.2" est vrai.
# ----------------------------------------------------------------------
version_ge() {
    awk -v a="$1" -v b="$2" '
        BEGIN {
            n = split(a, x, "."); m = split(b, y, ".");
            k = (n > m ? n : m);
            for (i = 1; i <= k; i++) {
                u = (i <= n ? x[i] + 0 : 0);
                v = (i <= m ? y[i] + 0 : 0);
                if (u > v) { print 1; exit }
                if (u < v) { print 0; exit }
            }
            print 1
        }'
}

# ----------------------------------------------------------------------
# Fraicheur du cache : une donnee perimee est une donnee dangereuse. Une
# option activee hier n'apparaitrait pas, et le check afficherait un vert
# trompeur. Tous les modes verifient donc l'age en premier.
# ----------------------------------------------------------------------
cache_age() {
    local now; now=$(date +%s)
    printf '%s' $(( now - COLLECT_EPOCH ))
}

human_age() {
    local s=$1
    if   [[ $s -lt 3600 ]];  then printf '%d min' $(( s / 60 ))
    elif [[ $s -lt 172800 ]]; then printf '%d h'  $(( s / 3600 ))
    else                          printf '%d j'   $(( s / 86400 ))
    fi
}

AGE=$(cache_age)

# ----------------------------------------------------------------------
# Normalisation d'une liste "a,b,c" en lignes, espaces de bord retires.
# ----------------------------------------------------------------------
# Le saut de ligne final est indispensable : sans lui, "read" abandonne
# le dernier element de la liste et l'option correspondante passerait
# pour non declaree.
list_to_lines() {
    printf '%s\n' "$1" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e '/^$/d'
}

is_licensed() {
    local want=$1 have
    while IFS= read -r have; do
        [[ ${have,,} == "${want,,}" ]] && return 0
    done < <(list_to_lines "$LICENSED_OPTIONS")
    return 1
}

# ----------------------------------------------------------------------
# Mode "options" : detection de derive de conformite.
#
# Regroupement par OPTION et non par feature : on achete une option, pas
# une feature. Une option devient un constat des lors qu'au moins une de
# ses features est utilisee.
#
# Trois niveaux de gravite :
#   CRITICAL  option non detenue et en cours d'utilisation, ou option
#             inutilisable dans l'edition installee
#   WARNING   option non detenue mais dont l'usage est seulement
#             historique (a justifier, sans urgence d'exploitation)
#   OK        usage couvert par une option declaree, ou feature devenue
#             gratuite dans cette version
# ----------------------------------------------------------------------
mode_options() {
    [[ -r $MAP_FILE ]] || die_unknown "table de correspondance illisible : $MAP_FILE"

    local -a rules=()
    mapfile -t rules < <(grep -vE '^[[:space:]]*(#|$)' "$MAP_FILE")
    [[ ${#rules[@]} -gt 0 ]] || die_unknown "table de correspondance vide : $MAP_FILE"

    declare -A viol_now=() viol_past=() covered=() freed=() wrong_edition=()
    declare -A detail=()

    local feature det used aux rule pat opt eds minaux freefrom note

    shopt -s nocasematch
    for feature in "${!FEAT_DET[@]}"; do
        det=${FEAT_DET[$feature]:-0}
        det=${det//[^0-9]/}; det=${det:-0}
        [[ $det -gt 0 ]] || continue

        opt=
        for rule in "${rules[@]}"; do
            IFS='|' read -r pat opt eds minaux freefrom note <<<"$rule"
            [[ $feature =~ $pat ]] && break
            opt=
        done
        [[ -n $opt ]] || continue        # feature non payante : ignoree

        used=${FEAT_USED[$feature]:-FALSE}
        aux=${FEAT_AUX[$feature]:-0}
        aux=${aux//[^0-9]/}; aux=${aux:-0}
        minaux=${minaux//[^0-9]/}; minaux=${minaux:-0}

        # Seuil AUX_COUNT : Multitenant n'est facturable qu'au-dela d'une
        # PDB, l'usage en deca est inclus dans l'edition.
        [[ $aux -le $minaux && $minaux -gt 0 ]] && continue

        # Feature devenue gratuite dans cette version.
        if [[ $freefrom != "-" ]] && [[ $(version_ge "$DB_VERSION" "$freefrom") == 1 ]]; then
            freed[$opt]=1
            continue
        fi

        detail[$opt]+="${detail[$opt]:+$'\n'}    - ${feature} (usages=${det}, en cours=${used}, depuis=${FEAT_FIRST[$feature]:--}, dernier=${FEAT_LAST[$feature]:--}${note:+ ; $note})"

        # Option non vendable dans cette edition : anomalie structurelle,
        # aucune commande ne peut la regulariser.
        if [[ $eds != ALL && $DB_EDITION != UNKNOWN ]] && ! [[ ,$eds, == *,$DB_EDITION,* ]]; then
            wrong_edition[$opt]=1
            continue
        fi

        if is_licensed "$opt"; then
            covered[$opt]=1
        elif [[ $used == TRUE ]]; then
            viol_now[$opt]=1
        else
            viol_past[$opt]=1
        fi
    done
    shopt -u nocasematch

    # Une option en infraction courante ne doit pas etre comptee deux fois.
    local o
    for o in "${!viol_now[@]}";      do unset 'viol_past[$o]'; done
    for o in "${!wrong_edition[@]}"; do unset 'viol_now[$o]' 'viol_past[$o]' 'covered[$o]'; done

    local n_now=${#viol_now[@]} n_past=${#viol_past[@]}
    local n_cov=${#covered[@]}  n_edt=${#wrong_edition[@]}
    [[ $IGNORE_HISTORICAL -eq 1 ]] && n_past=0

    local status=$OK label=OK
    if   [[ $n_edt -gt 0 || $n_now -gt 0 ]]; then status=$CRITICAL; label=CRITICAL
    elif [[ $n_past -gt 0 ]];                then status=$WARNING;  label=WARNING
    fi

    # Un cache perime rend le verdict caduc : on le signale sans masquer
    # une infraction deja constatee.
    local stale=
    if [[ $AGE -gt $MAX_CACHE_AGE ]]; then
        stale=" [cache perime: $(human_age "$AGE")]"
        [[ $status -eq $OK ]] && { status=$WARNING; label=WARNING; }
    fi

    local -a parts=()
    [[ $n_edt  -gt 0 ]] && parts+=("$n_edt option(s) incompatible(s) avec l'edition $DB_EDITION: $(joinkeys wrong_edition)")
    [[ $n_now  -gt 0 ]] && parts+=("$n_now option(s) non licenciee(s) en cours d'utilisation: $(joinkeys viol_now)")
    [[ $n_past -gt 0 ]] && parts+=("$n_past option(s) non licenciee(s) avec usage historique: $(joinkeys viol_past)")
    [[ ${#parts[@]} -eq 0 ]] && parts+=("aucune derive detectee sur $n_cov option(s) declaree(s)")

    printf '%s - %s/%s (%s %s): %s%s' \
        "$label" "$DB_NAME" "$SID" "$DB_EDITION" "$DB_VERSION" \
        "$(local IFS='; '; printf '%s' "${parts[*]}")" "$stale"

    printf '|unlicensed_now=%d;;1;0 unlicensed_past=%d;1;;0 wrong_edition=%d;;1;0 licensed_used=%d;;;0 cache_age=%ds;;%d;0\n' \
        "$n_now" "$n_past" "$n_edt" "$n_cov" "$AGE" "$MAX_CACHE_AGE"

    # Sortie longue : c'est elle qui permet au DBA d'agir sans se
    # reconnecter a la base.
    if [[ $VERBOSE -eq 1 || $status -ne $OK ]]; then
        local grp
        local -n ref
        for grp in wrong_edition viol_now viol_past covered; do
            unset -n ref; local -n ref=$grp
            [[ ${#ref[@]} -eq 0 ]] && continue
            case $grp in
                wrong_edition) echo "Options incompatibles avec l'edition installee :" ;;
                viol_now)      echo "Options utilisees SANS licence declaree :" ;;
                viol_past)     echo "Options non licenciees, usage historique uniquement :" ;;
                covered)       [[ $VERBOSE -eq 1 ]] || continue
                               echo "Options couvertes par la declaration :" ;;
            esac
            for o in "${!ref[@]}"; do
                printf '  %s\n%s\n' "$o" "${detail[$o]}"
            done
        done
        if [[ $VERBOSE -eq 1 && ${#freed[@]} -gt 0 ]]; then
            printf 'Features payantes par le passe, incluses en %s : %s\n' \
                   "$DB_VERSION" "$(joinkeys freed)"
        fi
    fi

    return $status
}

# Concatene les cles d'un tableau associatif, triees, separees par ", ".
joinkeys() {
    local -n arr=$1
    local -a k=()
    mapfile -t k < <(printf '%s\n' "${!arr[@]}" | sort)
    local IFS=', '
    printf '%s' "${k[*]}"
}

# ----------------------------------------------------------------------
# Mode "processors" : licences Processor requises par le materiel.
#
# ceil(coeurs physiques x facteur de coeur). En virtualisation "soft
# partitioning" (VMware, KVM, Hyper-V), Oracle considere que l'ensemble
# des hotes ou la VM peut migrer doit etre licencie : le chiffre calcule
# ici est donc un PLANCHER, jamais un plafond.
# ----------------------------------------------------------------------
mode_processors() {
    local cores sockets factor required virt reliable
    cores=$(kv host.cpu.cores 0)
    sockets=$(kv host.cpu.sockets 0)
    factor=$(kv host.core_factor 1.0)
    required=$(kv host.processor_licenses 0)
    virt=$(kv host.virt none)
    reliable=$(kv host.cpu.reliable 1)

    local status=$OK label=OK msg
    msg=$(printf '%s licence(s) Processor requise(s) (%s coeurs x facteur %s, %s socket(s))' \
                 "$required" "$cores" "$factor" "$sockets")

    if [[ -n $LICENSED_PROCESSORS ]]; then
        if [[ $required -gt $LICENSED_PROCESSORS ]]; then
            status=$CRITICAL; label=CRITICAL
            msg="$msg, $LICENSED_PROCESSORS detenue(s) -- deficit de $(( required - LICENSED_PROCESSORS ))"
        else
            msg="$msg, $LICENSED_PROCESSORS detenue(s)"
        fi
    else
        msg="$msg, aucune declaration de reference"
    fi

    # SE2 est plafonnee a 2 sockets : au-dela, l'installation est non
    # conforme quel que soit le nombre de licences detenues.
    if [[ $DB_EDITION == SE2 && $sockets -gt 2 ]]; then
        status=$CRITICAL; label=CRITICAL
        msg="$msg ; SE2 limitee a 2 sockets, $sockets detectes"
    fi

    if [[ $reliable -ne 1 ]]; then
        [[ $status -eq $OK ]] && { status=$WARNING; label=WARNING; }
        msg="$msg ; comptage de coeurs non fiable (lscpu indisponible)"
    fi

    if [[ $virt != none && $virt != kvm-guest ]]; then
        msg="$msg ; hyperviseur '$virt' detecte : verifier la regle de licence du cluster"
        [[ $status -eq $OK ]] && { status=$WARNING; label=WARNING; }
    fi

    printf '%s - %s/%s: %s|processor_licenses=%d;;%s;0 cpu_cores=%d;;;0 cpu_sockets=%d;;;0 cache_age=%ds;;%d;0\n' \
        "$label" "$DB_NAME" "$SID" "$msg" \
        "$required" "${LICENSED_PROCESSORS:-}" "$cores" "$sockets" "$AGE" "$MAX_CACHE_AGE"
    return $status
}

# ----------------------------------------------------------------------
# Mode "sessions" : high-water mark de sessions.
#
# Sert au dimensionnement Named User Plus. Le minimum contractuel Oracle
# est de 25 NUP par licence Processor en Enterprise Edition : le plancher
# calcule ici sert de reference au comptage NUP.
# ----------------------------------------------------------------------
mode_sessions() {
    local hwm inst_hwm hist_hwm current maxs nup_floor procs
    inst_hwm=$(kv license.sessions_highwater 0)
    hist_hwm=${HWM[SESSIONS]:-0}
    current=$(kv license.sessions_current 0)
    maxs=$(kv license.sessions_max 0)
    procs=$(kv host.processor_licenses 0)
    nup_floor=$(( procs * 25 ))

    # V$LICENSE.sessions_highwater repart de zero a chaque redemarrage de
    # l'instance ; DBA_HIGH_WATER_MARK_STATISTICS conserve le pic
    # historique. Le dimensionnement NUP doit retenir le plus eleve des
    # deux, sans quoi un simple bounce ferait disparaitre le pic reel.
    hwm=$inst_hwm
    [[ ${hist_hwm//[^0-9]/} -gt $hwm ]] 2>/dev/null && hwm=${hist_hwm//[^0-9]/}

    local status=$OK label=OK msg
    msg="high-water mark $hwm session(s), $current en cours"
    [[ $hist_hwm -gt $inst_hwm ]] && msg="$msg (pic historique $hist_hwm > pic depuis demarrage $inst_hwm)"
    [[ $maxs -gt 0 ]] && msg="$msg, plafond sessions_max=$maxs"
    msg="$msg ; plancher NUP contractuel: $nup_floor (25 x $procs Processor)"

    # Les seuils portent sur le high-water mark, image du pic d'usage.
    if [[ -n $CRIT && $hwm -ge $CRIT ]]; then
        status=$CRITICAL; label=CRITICAL
    elif [[ -n $WARN && $hwm -ge $WARN ]]; then
        status=$WARNING; label=WARNING
    fi

    printf '%s - %s/%s: %s|sessions_highwater=%d;%s;%s;0 sessions_current=%d;;;0 sessions_hwm_instance=%d;;;0 nup_floor=%d;;;0\n' \
        "$label" "$DB_NAME" "$SID" "$msg" \
        "$hwm" "${WARN:-}" "${CRIT:-}" "$current" "$inst_hwm" "$nup_floor"
    return $status
}

# ----------------------------------------------------------------------
# Mode "freshness" : le collecteur tourne-t-il encore ?
#
# A superviser en propre : sans lui, une panne silencieuse du timer
# ferait passer tous les autres controles au vert sur des donnees gelees.
# ----------------------------------------------------------------------
mode_freshness() {
    local status=$OK label=OK msg
    msg="derniere collecte il y a $(human_age "$AGE") ($(kv collect.date inconnue)), statut=$COLLECT_STATUS"

    if [[ $COLLECT_EPOCH -eq 0 ]]; then
        status=$UNKNOWN; label=UNKNOWN; msg="horodatage de collecte absent du cache"
    elif [[ $AGE -gt $(( MAX_CACHE_AGE * 2 )) ]]; then
        status=$CRITICAL; label=CRITICAL
    elif [[ $AGE -gt $MAX_CACHE_AGE ]]; then
        status=$WARNING; label=WARNING
    fi

    case $COLLECT_STATUS in
        instance_down) [[ $status -eq $OK ]] && { status=$WARNING; label=WARNING; }
                       msg="$msg (instance arretee lors de la derniere collecte)" ;;
        query_failed)  status=$CRITICAL; label=CRITICAL
                       msg="$msg (l'interrogation SQL a echoue)" ;;
    esac

    printf '%s - %s/%s: %s|cache_age=%ds;%d;%d;0\n' \
        "$label" "$DB_NAME" "$SID" "$msg" "$AGE" "$MAX_CACHE_AGE" $(( MAX_CACHE_AGE * 2 ))
    return $status
}

# ----------------------------------------------------------------------
# Mode "inventory" : restitution sans alerte, pour la documentation et
# les campagnes de recensement avant negociation contractuelle.
# ----------------------------------------------------------------------
mode_inventory() {
    local nfeat=${#FEAT_DET[@]} nopt=0 k
    for k in "${!OPTV[@]}"; do [[ ${OPTV[$k]} == TRUE ]] && nopt=$(( nopt + 1 )); done

    printf 'OK - %s/%s: %s %s, %s, %s coeurs/%s sockets, %d option(s) liee(s), %d feature(s) tracee(s)' \
        "$DB_NAME" "$SID" "$DB_EDITION" "$DB_VERSION" "$(kv db.role PRIMARY)" \
        "$(kv host.cpu.cores 0)" "$(kv host.cpu.sockets 0)" "$nopt" "$nfeat"
    printf '|linked_options=%d;;;0 tracked_features=%d;;;0 processor_licenses=%d;;;0 cache_age=%ds;;;0\n' \
        "$nopt" "$nfeat" "$(kv host.processor_licenses 0)" "$AGE"

    printf 'Hote          : %s (%s, %s)\n' "$(kv host.name -)" "$(kv host.cpu.model -)" "$(kv host.virt none)"
    printf 'Base          : %s / DBID %s / role %s / mode %s\n' \
           "$DB_NAME" "$(kv db.dbid -)" "$(kv db.role -)" "$(kv db.open_mode -)"
    printf 'ORACLE_HOME   : %s\n' "$(kv inst.oracle_home -)"
    printf 'RAC           : %s instance(s)\n' "$(kv db.rac_instances 1)"
    printf 'Multitenant   : CDB=%s, %s PDB utilisateur\n' "$(kv db.cdb NO)" "$(kv db.pdb_count 0)"
    printf 'Facteur coeur : %s -> %s licence(s) Processor\n' \
           "$(kv host.core_factor -)" "$(kv host.processor_licenses 0)"

    if [[ $VERBOSE -eq 1 ]]; then
        echo 'Options liees au binaire (V$OPTION = TRUE) :'
        for k in $(printf '%s\n' "${!OPTV[@]}" | sort); do
            [[ ${OPTV[$k]} == TRUE ]] && printf '  - %s\n' "$k"
        done
    fi
    return $OK
}

# ----------------------------------------------------------------------
case $MODE in
    options)    mode_options ;;
    processors) mode_processors ;;
    sessions)   mode_sessions ;;
    freshness)  mode_freshness ;;
    inventory)  mode_inventory ;;
    *)          die_unknown "mode inconnu : $MODE (options|processors|sessions|freshness|inventory)" ;;
esac
exit $?
