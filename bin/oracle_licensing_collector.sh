#!/usr/bin/env bash
#
# oracle_licensing_collector.sh
#
# Collecte les donnees de conformite de licence Oracle sur l'hote local et
# les depose dans un cache plat lu ensuite par check_oracle_licensing.sh.
#
# Concu pour tourner via timer systemd ou cron (1 a 2 fois par jour) sous
# l'utilisateur proprietaire d'ORACLE_HOME. La collecte peut durer
# plusieurs dizaines de secondes : c'est precisement pour cela qu'elle est
# separee du plugin NRPE, dont le timeout par defaut est de 10 secondes.
#
# Aucune ecriture en base. Aucun mot de passe : authentification OS.
#
set -o nounset
set -o pipefail

readonly PROGNAME=${0##*/}
readonly VERSION=1.0.0

# --- Emplacements par defaut, surchargeables par le fichier de conf ----
CONFIG_FILE=${ORACLE_LICENSING_CONF:-/etc/oracle-licensing/oracle-licensing.conf}
CACHE_DIR=/var/cache/oracle-licensing
SQL_FILE=/usr/lib/oracle-licensing/collect_licensing.sql
ORATAB=/etc/oratab
CACHE_GROUP=nagios
SQLPLUS_TIMEOUT=120
CORE_FACTOR=            # vide => deduit de l'architecture
INCLUDE_SIDS=           # vide => toutes les instances de l'oratab
EXCLUDE_SIDS=
VERBOSE=0
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $PROGNAME [options]

Collecte l'usage des options Oracle payantes et l'inventaire CPU de l'hote,
puis ecrit un fichier de cache par instance dans CACHE_DIR.

Options :
  -c, --config FICHIER   Fichier de configuration (defaut: $CONFIG_FILE)
  -d, --cache-dir REP    Repertoire de cache (defaut: $CACHE_DIR)
  -s, --sid SID          Ne traiter que ce SID (repetable)
  -n, --dry-run          Afficher sur stdout sans ecrire le cache
  -v, --verbose          Tracer le deroulement sur stderr
  -V, --version          Afficher la version
  -h, --help             Afficher cette aide

Codes retour : 0 succes, 1 succes partiel, 2 echec total, 3 erreur d'usage.
EOF
}

log()  { [[ $VERBOSE -eq 1 ]] && printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2; return 0; }
warn() { printf '%s: %s\n' "$PROGNAME" "$*" >&2; }
die()  { warn "$*"; exit 2; }

# ----------------------------------------------------------------------
# Analyse des arguments
# ----------------------------------------------------------------------
declare -a CLI_SIDS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config)    CONFIG_FILE=${2:?option --config sans valeur}; shift 2 ;;
        -d|--cache-dir) CACHE_DIR=${2:?option --cache-dir sans valeur}; shift 2 ;;
        -s|--sid)       CLI_SIDS+=("${2:?option --sid sans valeur}"); shift 2 ;;
        -n|--dry-run)   DRY_RUN=1; shift ;;
        -v|--verbose)   VERBOSE=1; shift ;;
        -V|--version)   printf '%s %s\n' "$PROGNAME" "$VERSION"; exit 0 ;;
        -h|--help)      usage; exit 0 ;;
        *)              usage >&2; exit 3 ;;
    esac
done

# Le fichier de conf est optionnel : les defauts ci-dessus suffisent a une
# installation standard.
if [[ -r $CONFIG_FILE ]]; then
    log "chargement de la configuration $CONFIG_FILE"
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi
[[ ${#CLI_SIDS[@]} -gt 0 ]] && INCLUDE_SIDS="${CLI_SIDS[*]}"

# ----------------------------------------------------------------------
# Inventaire CPU de l'hote
#
# C'est la partie qui justifie l'execution locale : V$OSSTAT ne voit que
# ce que l'hyperviseur expose au guest, alors que la facturation Oracle
# porte sur les coeurs physiques du serveur (voire du cluster entier en
# virtualisation "soft partitioning").
# ----------------------------------------------------------------------
collect_host_cpu() {
    local sockets cores threads model arch virt factor licenses

    arch=$(uname -m 2>/dev/null || echo unknown)
    threads=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0)
    sockets=0; cores=0; model=unknown

    if command -v lscpu >/dev/null 2>&1; then
        local cps
        sockets=$(lscpu 2>/dev/null | awk -F: '/^Socket\(s\)/        {gsub(/ /,"",$2); print $2; exit}')
        cps=$(    lscpu 2>/dev/null | awk -F: '/^Core\(s\) per socket/{gsub(/ /,"",$2); print $2; exit}')
        model=$(  lscpu 2>/dev/null | awk -F: '/^Model name/         {sub(/^[ \t]+/,"",$2); print $2; exit}')
        [[ -n ${sockets:-} && -n ${cps:-} ]] && cores=$(( sockets * cps ))
    fi

    # Repli sur /proc/cpuinfo quand lscpu est absent (images minimales).
    if [[ ${cores:-0} -eq 0 && -r /proc/cpuinfo ]]; then
        sockets=$(awk -F: '/^physical id/{print $2}' /proc/cpuinfo | sort -u | wc -l)
        local cps
        cps=$(awk -F: '/^cpu cores/{gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo)
        [[ ${sockets:-0} -gt 0 && -n ${cps:-} ]] && cores=$(( sockets * cps ))
        model=$(awk -F: '/^model name/{sub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo)
    fi

    # Dernier recours : un thread = un coeur. Sous-estime avec
    # l'hyperthreading, donc on le signale comme non fiable.
    local reliable=1
    if [[ ${cores:-0} -eq 0 ]]; then
        cores=$threads; sockets=0; reliable=0
    fi

    virt=none
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt=$(systemd-detect-virt 2>/dev/null || echo none)
    elif command -v virt-what >/dev/null 2>&1; then
        virt=$(virt-what 2>/dev/null | head -1); virt=${virt:-none}
    fi

    # Table des facteurs de coeur Oracle (Core Factor Table). x86_64
    # multicoeur vaut 0,5 ; SPARC et POWER different. Toute plateforme
    # exotique doit etre fixee explicitement en configuration.
    if [[ -n ${CORE_FACTOR:-} ]]; then
        factor=$CORE_FACTOR
    else
        case $arch in
            x86_64|amd64) factor=0.5 ;;
            ia64)         factor=0.5 ;;
            sparc64|sun4v) factor=0.5 ;;
            ppc64|ppc64le) factor=1.0 ;;
            *)            factor=1.0 ;;
        esac
    fi

    # ceil(coeurs x facteur) : Oracle arrondit toujours a l'entier superieur.
    licenses=$(awk -v c="$cores" -v f="$factor" 'BEGIN{v=c*f; r=int(v); if(v>r) r++; print r}')

    printf 'KV|host.name|%s\n'            "$(hostname -f 2>/dev/null || hostname)"
    printf 'KV|host.arch|%s\n'            "$arch"
    printf 'KV|host.cpu.model|%s\n'       "${model:-unknown}"
    printf 'KV|host.cpu.sockets|%s\n'     "${sockets:-0}"
    printf 'KV|host.cpu.cores|%s\n'       "${cores:-0}"
    printf 'KV|host.cpu.threads|%s\n'     "${threads:-0}"
    printf 'KV|host.cpu.reliable|%s\n'    "$reliable"
    printf 'KV|host.virt|%s\n'            "${virt:-none}"
    printf 'KV|host.core_factor|%s\n'     "$factor"
    printf 'KV|host.processor_licenses|%s\n' "$licenses"
}

# ----------------------------------------------------------------------
# Decouverte des instances
#
# /etc/oratab est la source d'autorite locale. On ecarte les instances
# d'infrastructure (ASM, referentiel Grid) qui ne portent pas de licence
# Database, ainsi que les entrees generiques.
# ----------------------------------------------------------------------
discover_instances() {
    [[ -r $ORATAB ]] || { warn "oratab illisible : $ORATAB"; return 1; }

    local sid home rest
    while IFS=: read -r sid home rest; do
        [[ -z ${sid:-} ]]                      && continue
        [[ $sid == \#* ]]                      && continue
        [[ $sid == \** ]]                      && continue
        [[ $sid == +* ]]                       && continue   # +ASM, +APX
        [[ $sid == -MGMTDB ]]                  && continue
        [[ -z ${home:-} || ! -d $home ]]       && { warn "ORACLE_HOME absent pour $sid : ${home:-<vide>}"; continue; }

        if [[ -n ${INCLUDE_SIDS:-} ]] && ! grep -qw -- "$sid" <<<"$INCLUDE_SIDS"; then
            log "$sid ignore (hors INCLUDE_SIDS)"; continue
        fi
        if [[ -n ${EXCLUDE_SIDS:-} ]] && grep -qw -- "$sid" <<<"$EXCLUDE_SIDS"; then
            log "$sid ignore (dans EXCLUDE_SIDS)"; continue
        fi

        printf '%s:%s\n' "$sid" "$home"
    done < "$ORATAB"
}

instance_is_running() {
    local sid=$1
    pgrep -f "ora_pmon_${sid}\$" >/dev/null 2>&1 || pgrep -x "ora_pmon_${sid}" >/dev/null 2>&1
}

# ----------------------------------------------------------------------
# Interrogation d'une instance
#
# Connexion "/ as sysdba" : authentification par appartenance au groupe
# OSDBA, donc aucun secret stocke ni transmis. C'est l'argument decisif
# en faveur de la collecte locale.
# ----------------------------------------------------------------------
query_instance() {
    local sid=$1 home=$2 output rc

    export ORACLE_SID=$sid
    export ORACLE_HOME=$home
    export PATH=$home/bin:$PATH
    export LD_LIBRARY_PATH=$home/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
    export NLS_LANG=AMERICAN_AMERICA.AL32UTF8

    [[ -x $home/bin/sqlplus ]] || { warn "$sid : sqlplus introuvable dans $home/bin"; return 1; }

    output=$(timeout --signal=TERM --kill-after=10 "$SQLPLUS_TIMEOUT" \
                 "$home/bin/sqlplus" -S -L /nolog <<-EOSQL 2>&1
		CONNECT / AS SYSDBA
		@${SQL_FILE}
	EOSQL
            )
    rc=$?

    if [[ $rc -eq 124 || $rc -eq 137 ]]; then
        warn "$sid : delai de $SQLPLUS_TIMEOUT s depasse"
        return 1
    fi

    # sqlplus signale les erreurs Oracle dans le flux, pas toujours par son
    # code retour : on inspecte le texte.
    if grep -qE '^(ORA|SP2|TNS)-[0-9]+' <<<"$output"; then
        local firsterr
        firsterr=$(grep -m1 -E '^(ORA|SP2|TNS)-[0-9]+' <<<"$output")
        # ORA-01219 / ORA-01507 : base non ouverte. Le rapport reste
        # exploitable (V$OPTION et l'identite sont lisibles en MOUNT).
        if grep -qE '^(ORA-01219|ORA-01507|ORA-01034)' <<<"$output"; then
            warn "$sid : base non ouverte ($firsterr), collecte partielle"
        else
            warn "$sid : $firsterr"
            grep -qE '^KV\|db\.name\|' <<<"$output" || return 1
        fi
    fi

    # On ne conserve que les enregistrements structures : sqlplus emet
    # aussi des lignes vides et des messages divers.
    grep -E '^(KV|OPT|FEAT|HWM)\|' <<<"$output"
}

# ----------------------------------------------------------------------
# Ecriture atomique du cache
#
# Le plugin NRPE peut lire a tout instant : un rename() est atomique sur
# le meme systeme de fichiers, donc jamais de lecture partielle.
# ----------------------------------------------------------------------
write_cache() {
    local sid=$1 content=$2
    # Affectation en deux temps : dans un meme "local", une variable
    # declaree a gauche n'est pas encore visible a droite. Ecrire
    # "local sid=$1 target=.../${sid}.dat" donnerait ici le bon chemin
    # par accident -- main() expose deja un "sid" homonyme via la portee
    # dynamique -- et produirait "<cache>/.dat" des que cet appelant
    # changerait. On ne s'appuie pas sur cette coincidence.
    local target=$CACHE_DIR/${sid}.dat tmp

    tmp=$(mktemp "${target}.XXXXXX") || { warn "$sid : mktemp a echoue"; return 1; }
    printf '%s\n' "$content" > "$tmp" || { rm -f "$tmp"; return 1; }

    # Lisible par le compte NRPE, jamais modifiable par lui.
    chmod 0640 "$tmp"
    chgrp "$CACHE_GROUP" "$tmp" 2>/dev/null || log "groupe $CACHE_GROUP non applique sur $tmp"
    mv -f "$tmp" "$target" || { rm -f "$tmp"; return 1; }
    log "$sid : cache ecrit dans $target"
}

# ----------------------------------------------------------------------
# Programme principal
# ----------------------------------------------------------------------
main() {
    [[ -r $SQL_FILE ]] || die "script SQL illisible : $SQL_FILE"

    if [[ $DRY_RUN -eq 0 ]]; then
        mkdir -p "$CACHE_DIR" || die "creation impossible : $CACHE_DIR"
        chmod 0750 "$CACHE_DIR" 2>/dev/null || true
    fi

    local host_block
    host_block=$(collect_host_cpu)

    local -a instances=()
    mapfile -t instances < <(discover_instances)
    [[ ${#instances[@]} -eq 0 ]] && die "aucune instance exploitable dans $ORATAB"
    log "${#instances[@]} instance(s) a traiter"

    local ok=0 ko=0 entry sid home started db_block header content
    for entry in "${instances[@]}"; do
        sid=${entry%%:*}
        home=${entry#*:}

        if instance_is_running "$sid"; then started=1; else started=0; fi
        log "$sid : demarree=$started home=$home"

        header=$(printf '%s\n' \
            "# oracle-licensing cache v1 -- NE PAS EDITER" \
            "KV|collect.version|$VERSION" \
            "KV|collect.epoch|$(date +%s)" \
            "KV|collect.date|$(date '+%Y-%m-%d %H:%M:%S %z')" \
            "KV|inst.sid|$sid" \
            "KV|inst.oracle_home|$home" \
            "KV|inst.running|$started")

        if [[ $started -eq 0 ]]; then
            # Instance a l'arret : on publie quand meme une fiche pour que
            # le plugin distingue "arretee" de "jamais collectee".
            content=$(printf '%s\n%s\nKV|collect.status|instance_down\n' "$header" "$host_block")
            ko=$(( ko + 1 ))
        elif db_block=$(query_instance "$sid" "$home"); then
            content=$(printf '%s\n%s\n%s\nKV|collect.status|ok\n' "$header" "$host_block" "$db_block")
            ok=$(( ok + 1 ))
        else
            content=$(printf '%s\n%s\nKV|collect.status|query_failed\n' "$header" "$host_block")
            ko=$(( ko + 1 ))
        fi

        if [[ $DRY_RUN -eq 1 ]]; then
            printf '%s\n' "$content"
        else
            write_cache "$sid" "$content" || ko=$(( ko + 1 ))
        fi
    done

    log "termine : $ok succes, $ko echec(s)"
    [[ $ok -gt 0 && $ko -eq 0 ]] && return 0
    [[ $ok -gt 0 ]]              && return 1
    return 2
}

main "$@"
