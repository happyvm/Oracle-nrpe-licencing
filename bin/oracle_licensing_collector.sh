#!/bin/sh
#
# oracle_licensing_collector.sh
#
# Collecte les donnees de conformite de licence Oracle sur l'hote local
# et les depose dans un cache plat lu ensuite par check_oracle_licensing.
#
# Concu pour tourner via timer systemd ou cron (une a deux fois par
# jour) sous l'utilisateur proprietaire d'ORACLE_HOME. La collecte peut
# durer plusieurs dizaines de secondes : c'est pour cela qu'elle est
# separee du plugin NRPE, dont le timeout par defaut est de 10 secondes.
#
# PORTABILITE : shell POSIX, cible RHEL 5 a 9. Pas de tableaux bash, pas
# de mapfile, et un repli maison pour "timeout", absent de coreutils
# avant RHEL 6.
#
# Aucune ecriture en base. Aucun mot de passe : authentification OS.
#

PROGNAME=`basename "$0"`
VERSION=1.1.0

CONFIG_FILE=${ORACLE_LICENSING_CONF:-/etc/oracle-licensing/oracle-licensing.conf}
CACHE_DIR=/var/cache/oracle-licensing
SQL_FILE=/usr/lib/oracle-licensing/collect_licensing.sql
ORATAB=/etc/oratab
CACHE_GROUP=nagios
SQLPLUS_TIMEOUT=120
CORE_FACTOR=
INCLUDE_SIDS=
EXCLUDE_SIDS=
VERBOSE=0
DRY_RUN=0

usage() {
    cat <<EOF
Usage: $PROGNAME [options]

Collecte l'usage des options Oracle payantes et l'inventaire CPU de
l'hote, puis ecrit un fichier de cache par instance dans CACHE_DIR.

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

# Nettoyage des temporaires, y compris sur interruption : un collecteur
# quotidien tue en cours de route -- arret systeme, delai du timer --
# laisserait sinon un residu dans /tmp a chaque fois.
TMP_PREFIX=${TMPDIR:-/tmp}/orlic.$$
cleanup_tmp() {
    rm -f "$TMP_PREFIX".* 2>/dev/null
}
trap 'cleanup_tmp' EXIT
trap 'cleanup_tmp; exit 130' INT
trap 'cleanup_tmp; exit 143' TERM

log()  { [ "$VERBOSE" = 1 ] && echo "[`date '+%H:%M:%S'`] $*" >&2; return 0; }
warn() { echo "$PROGNAME: $*" >&2; }
die()  { warn "$*"; exit 2; }

# --- Arguments -------------------------------------------------------
CLI_SIDS=
while [ $# -gt 0 ]; do
    case $1 in
        -c|--config)    CONFIG_FILE=$2; shift 2 ;;
        -d|--cache-dir) CACHE_DIR=$2; shift 2 ;;
        -s|--sid)       CLI_SIDS="$CLI_SIDS $2"; shift 2 ;;
        -n|--dry-run)   DRY_RUN=1; shift ;;
        -v|--verbose)   VERBOSE=1; shift ;;
        -V|--version)   echo "$PROGNAME $VERSION"; exit 0 ;;
        -h|--help)      usage; exit 0 ;;
        *)              usage >&2; exit 3 ;;
    esac
done

if [ -r "$CONFIG_FILE" ]; then
    log "chargement de la configuration $CONFIG_FILE"
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
fi
[ -n "$CLI_SIDS" ] && INCLUDE_SIDS=$CLI_SIDS

# ---------------------------------------------------------------------
# Repli pour "timeout", absent de coreutils avant RHEL 6.
#
# La commande est lancee en arriere-plan, surveillee par un chien de
# garde qui l'interrompt puis la tue. Sans cela, un sqlplus bloque sur
# une base gelee immobiliserait la collecte de tout le serveur.
# ---------------------------------------------------------------------
HAVE_TIMEOUT=0
command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1

run_limited() {
    # run_limited <secondes> <fichier_sortie> <commande...>
    limit=$1; outfile=$2; shift 2

    if [ "$HAVE_TIMEOUT" = 1 ]; then
        timeout --signal=TERM --kill-after=10 "$limit" "$@" > "$outfile" 2>&1
        return $?
    fi

    "$@" > "$outfile" 2>&1 &
    cmd_pid=$!
    (
        i=0
        while [ "$i" -lt "$limit" ]; do
            kill -0 "$cmd_pid" 2>/dev/null || exit 0
            sleep 1
            i=`expr $i + 1`
        done
        kill -TERM "$cmd_pid" 2>/dev/null
        sleep 10
        kill -KILL "$cmd_pid" 2>/dev/null
    ) >/dev/null 2>&1 &
    guard_pid=$!

    wait "$cmd_pid" 2>/dev/null
    rc=$?
    kill "$guard_pid" 2>/dev/null
    wait "$guard_pid" 2>/dev/null
    # Un processus tue par signal rend 128+n ; on l'aligne sur le code
    # 124 de "timeout" pour que l'appelant n'ait qu'un cas a traiter.
    if [ "$rc" -ge 143 ] && [ "$rc" -le 144 ]; then rc=124; fi
    if [ "$rc" -eq 137 ]; then rc=124; fi
    return $rc
}

# ---------------------------------------------------------------------
# Inventaire CPU de l'hote
#
# C'est la partie qui justifie l'execution locale : V$OSSTAT ne voit que
# ce que l'hyperviseur expose au guest, alors que la facturation Oracle
# porte sur les coeurs physiques du serveur, voire du cluster entier en
# virtualisation dite "soft partitioning".
# ---------------------------------------------------------------------
collect_host_cpu() {
    arch=`uname -m 2>/dev/null || echo unknown`
    threads=`getconf _NPROCESSORS_ONLN 2>/dev/null || echo 0`
    sockets=0; cores=0; model=unknown; reliable=1

    # lscpu n'existe pas sur RHEL 5 (util-linux-ng anterieur a 2.14).
    if command -v lscpu >/dev/null 2>&1; then
        sockets=`lscpu 2>/dev/null | awk -F: '/^Socket\(s\)/         {gsub(/ /,"",$2); print $2; exit}'`
        cps=`    lscpu 2>/dev/null | awk -F: '/^Core\(s\) per socket/{gsub(/ /,"",$2); print $2; exit}'`
        model=`  lscpu 2>/dev/null | awk -F: '/^Model name/          {sub(/^[ \t]+/,"",$2); print $2; exit}'`
        if [ -n "$sockets" ] && [ -n "$cps" ]; then
            cores=`expr "$sockets" \* "$cps" 2>/dev/null || echo 0`
        fi
    fi

    # Repli /proc/cpuinfo : c'est le chemin normal sur RHEL 5.
    if [ "${cores:-0}" -eq 0 ] && [ -r /proc/cpuinfo ]; then
        sockets=`awk -F: '/^physical id/{print $2}' /proc/cpuinfo | sort -u | wc -l | tr -d ' '`
        cps=`awk -F: '/^cpu cores/{gsub(/ /,"",$2); print $2; exit}' /proc/cpuinfo`
        if [ "${sockets:-0}" -gt 0 ] && [ -n "$cps" ]; then
            cores=`expr "$sockets" \* "$cps" 2>/dev/null || echo 0`
        fi
        model=`awk -F: '/^model name/{sub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo`
    fi

    # Dernier recours : un thread pour un coeur. Sous-estime des que
    # l'hyperthreading est actif, donc signale comme non fiable.
    if [ "${cores:-0}" -eq 0 ]; then
        cores=$threads; sockets=0; reliable=0
    fi

    # Detection de virtualisation, du plus precis au plus fruste.
    # systemd-detect-virt n'existe pas avant RHEL 7.
    virt=none
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        virt=`systemd-detect-virt 2>/dev/null` || virt=none
    elif command -v virt-what >/dev/null 2>&1; then
        virt=`virt-what 2>/dev/null | head -1`
    elif command -v dmidecode >/dev/null 2>&1; then
        vendor=`dmidecode -s system-product-name 2>/dev/null | head -1`
        case $vendor in
            *VMware*)         virt=vmware ;;
            *VirtualBox*)     virt=oracle ;;
            *KVM*|*QEMU*)     virt=kvm ;;
            *Virtual\ Machine*) virt=microsoft ;;
        esac
    elif grep -qi '^flags.*hypervisor' /proc/cpuinfo 2>/dev/null; then
        virt=unknown-hypervisor
    fi
    [ -z "$virt" ] && virt=none

    # Table des facteurs de coeur Oracle. x86_64 multicoeur vaut 0,5 ;
    # SPARC et POWER different. Toute plateforme exotique doit etre
    # fixee explicitement en configuration.
    if [ -n "$CORE_FACTOR" ]; then
        factor=$CORE_FACTOR
    else
        case $arch in
            x86_64|amd64)   factor=0.5 ;;
            ia64)           factor=0.5 ;;
            sparc64|sun4v)  factor=0.5 ;;
            ppc64|ppc64le)  factor=1.0 ;;
            *)              factor=1.0 ;;
        esac
    fi

    # Oracle arrondit toujours a l'entier superieur.
    licenses=`awk -v c="$cores" -v f="$factor" 'BEGIN{v=c*f; r=int(v); if(v>r) r++; print r}'`

    # printf plutot que echo : sous dash, echo interprete les
    # antislashes d'une valeur -- un modele de processeur exotique
    # serait deforme, et un "\c" tronquerait la suite du cache. Le
    # comportement d'echo differe entre dash et bash, donc entre
    # distributions.
    printf 'KV|host.name|%s\n'               "`hostname -f 2>/dev/null || hostname`"
    printf 'KV|host.arch|%s\n'               "$arch"
    printf 'KV|host.cpu.model|%s\n'          "${model:-unknown}"
    printf 'KV|host.cpu.sockets|%s\n'        "${sockets:-0}"
    printf 'KV|host.cpu.cores|%s\n'          "${cores:-0}"
    printf 'KV|host.cpu.threads|%s\n'        "${threads:-0}"
    printf 'KV|host.cpu.reliable|%s\n'       "$reliable"
    printf 'KV|host.virt|%s\n'               "$virt"
    printf 'KV|host.core_factor|%s\n'        "$factor"
    printf 'KV|host.processor_licenses|%s\n' "$licenses"
}

# ---------------------------------------------------------------------
# Decouverte des instances
#
# /etc/oratab est la source d'autorite locale. On ecarte les instances
# d'infrastructure (ASM, referentiel Grid) qui ne portent pas de licence
# Database, ainsi que les entrees generiques.
# ---------------------------------------------------------------------
discover_instances() {
    [ -r "$ORATAB" ] || { warn "oratab illisible : $ORATAB"; return 1; }

    # IFS local a la boucle : restaure ensuite pour ne pas perturber le
    # reste du script.
    oldifs=$IFS
    IFS=:
    while read -r sid home rest; do
        IFS=$oldifs
        case $sid in
            ''|\#*|\**|+*|-MGMTDB) IFS=:; continue ;;
        esac
        if [ -z "$home" ] || [ ! -d "$home" ]; then
            warn "ORACLE_HOME absent pour $sid : ${home:-<vide>}"
            IFS=:; continue
        fi
        if [ -n "$INCLUDE_SIDS" ] && ! sid_in_list "$sid" "$INCLUDE_SIDS"; then
            log "$sid ignore (hors INCLUDE_SIDS)"; IFS=:; continue
        fi
        if [ -n "$EXCLUDE_SIDS" ] && sid_in_list "$sid" "$EXCLUDE_SIDS"; then
            log "$sid ignore (dans EXCLUDE_SIDS)"; IFS=:; continue
        fi
        printf '%s:%s\n' "$sid" "$home"
        IFS=:
    done < "$ORATAB"
    IFS=$oldifs
    # "rest" n'est pas exploite mais doit exister pour que "read" ne
    # replie pas les champs suivants dans "home".
    : "${rest:-}"
}

# Appartenance a une liste de SID separes par des espaces. La
# comparaison est litterale : passer par grep interpreterait le SID
# comme une expression reguliere.
sid_in_list() {
    _needle=$1
    for _item in $2; do
        [ "$_item" = "$_needle" ] && return 0
    done
    return 1
}

instance_is_running() {
    sid=$1
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -f "ora_pmon_${sid}\$" >/dev/null 2>&1 && return 0
        pgrep -x "ora_pmon_${sid}"   >/dev/null 2>&1 && return 0
        return 1
    fi
    # Repli sans pgrep, pour les installations minimales.
    ps -ef 2>/dev/null | grep -v grep | grep -q "ora_pmon_${sid}\$"
}

# ---------------------------------------------------------------------
# Interrogation d'une instance
#
# Connexion "/ as sysdba" : authentification par appartenance au groupe
# OSDBA, donc aucun secret stocke ni transmis. C'est l'argument decisif
# en faveur de la collecte locale.
# ---------------------------------------------------------------------
query_instance() {
    sid=$1; home=$2

    ORACLE_SID=$sid;  export ORACLE_SID
    ORACLE_HOME=$home; export ORACLE_HOME
    PATH=$home/bin:$PATH; export PATH
    LD_LIBRARY_PATH=$home/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}; export LD_LIBRARY_PATH
    NLS_LANG=AMERICAN_AMERICA.AL32UTF8; export NLS_LANG

    if [ ! -x "$home/bin/sqlplus" ]; then
        warn "$sid : sqlplus introuvable dans $home/bin"
        return 1
    fi

    qtmp=`mktemp "${TMP_PREFIX}.XXXXXX"` || return 1
    cat > "$qtmp.in" <<EOSQL
CONNECT / AS SYSDBA
@${SQL_FILE}
EOSQL

    run_limited "$SQLPLUS_TIMEOUT" "$qtmp" \
        sh -c "'$home/bin/sqlplus' -S -L /nolog < '$qtmp.in'"
    rc=$?

    if [ "$rc" -eq 124 ]; then
        warn "$sid : delai de $SQLPLUS_TIMEOUT s depasse"
        rm -f "$qtmp" "$qtmp.in"
        return 1
    fi

    # sqlplus signale les erreurs Oracle dans le flux, pas toujours par
    # son code retour : on inspecte le texte.
    if grep -qE '^(ORA|SP2|TNS)-[0-9]+' "$qtmp" 2>/dev/null; then
        firsterr=`grep -m1 -E '^(ORA|SP2|TNS)-[0-9]+' "$qtmp"`
        if grep -qE '^(ORA-01219|ORA-01507|ORA-01034)' "$qtmp"; then
            # Base non ouverte : le rapport reste exploitable pour
            # l'identite et V$OPTION.
            warn "$sid : base non ouverte ($firsterr), collecte partielle"
        else
            warn "$sid : $firsterr"
            if ! grep -qE '^KV\|db\.name\|' "$qtmp"; then
                rm -f "$qtmp" "$qtmp.in"
                return 1
            fi
        fi
    fi

    # On ne conserve que les enregistrements structures : sqlplus emet
    # aussi des lignes vides et des messages divers.
    #
    # OBJ porte les preuves structurelles : l'omettre reviendrait a
    # perdre la seule source d'usage disponible sur 9i, et le
    # recoupement du dictionnaire sur toutes les autres versions.
    grep -E '^(KV|OPT|FEAT|HWM|OBJ)\|' "$qtmp"
    rm -f "$qtmp" "$qtmp.in"
    return 0
}

# ---------------------------------------------------------------------
# Ecriture atomique du cache
#
# Le plugin NRPE peut lire a tout instant : un rename() est atomique sur
# le meme systeme de fichiers, donc jamais de lecture partielle.
# ---------------------------------------------------------------------
write_cache() {
    sid=$1; content=$2
    target=$CACHE_DIR/$sid.dat

    tmp=`mktemp "$target.XXXXXX"` || { warn "$sid : mktemp a echoue"; return 1; }
    printf '%s\n' "$content" > "$tmp" || { rm -f "$tmp"; return 1; }

    # Lisible par le compte NRPE, jamais modifiable par lui.
    chmod 0640 "$tmp"
    chgrp "$CACHE_GROUP" "$tmp" 2>/dev/null || log "groupe $CACHE_GROUP non applique sur $tmp"
    mv -f "$tmp" "$target" || { rm -f "$tmp"; return 1; }
    log "$sid : cache ecrit dans $target"
}

# ---------------------------------------------------------------------
main() {
    [ -r "$SQL_FILE" ] || die "script SQL illisible : $SQL_FILE"

    if [ "$DRY_RUN" = 0 ]; then
        mkdir -p "$CACHE_DIR" || die "creation impossible : $CACHE_DIR"
        chmod 0750 "$CACHE_DIR" 2>/dev/null
    fi

    host_block=`collect_host_cpu`

    inst_file=`mktemp "${TMP_PREFIX}.inst.XXXXXX"` || die "mktemp a echoue"
    discover_instances > "$inst_file"
    if [ ! -s "$inst_file" ]; then
        rm -f "$inst_file"
        die "aucune instance exploitable dans $ORATAB"
    fi
    log "`wc -l < "$inst_file" | tr -d ' '` instance(s) a traiter"

    ok=0; ko=0
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        sid=`echo "$entry" | cut -d: -f1`
        home=`echo "$entry" | cut -d: -f2-`

        if instance_is_running "$sid"; then started=1; else started=0; fi
        log "$sid : demarree=$started home=$home"

        header="# oracle-licensing cache v1 -- NE PAS EDITER
KV|collect.version|$VERSION
KV|collect.epoch|`date +%s`
KV|collect.date|`date '+%Y-%m-%d %H:%M:%S %z'`
KV|inst.sid|$sid
KV|inst.oracle_home|$home
KV|inst.running|$started"

        if [ "$started" = 0 ]; then
            # Instance a l'arret : on publie quand meme une fiche pour
            # que le plugin distingue "arretee" de "jamais collectee".
            content="$header
$host_block
KV|collect.status|instance_down"
            ko=`expr $ko + 1`
        elif db_block=`query_instance "$sid" "$home"`; then
            content="$header
$host_block
$db_block
KV|collect.status|ok"
            ok=`expr $ok + 1`
        else
            content="$header
$host_block
KV|collect.status|query_failed"
            ko=`expr $ko + 1`
        fi

        if [ "$DRY_RUN" = 1 ]; then
            printf '%s\n' "$content"
        else
            write_cache "$sid" "$content" || ko=`expr $ko + 1`
        fi
    done < "$inst_file"
    rm -f "$inst_file"

    log "termine : $ok succes, $ko echec(s)"
    [ "$ok" -gt 0 ] && [ "$ko" -eq 0 ] && return 0
    [ "$ok" -gt 0 ] && return 1
    return 2
}

main "$@"
