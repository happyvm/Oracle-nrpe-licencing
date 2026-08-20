#!/bin/sh
# Nagios/NRPE Oracle license-risk inventory check
# Compatible with old /bin/sh environments used on RHEL 5+.

PATH=/bin:/usr/bin:/sbin:/usr/sbin
export PATH

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd)
SQL_FILE="${SQL_FILE:-$SCRIPT_DIR/check_oracle_license.sql}"
RULES_FILE="${RULES_FILE:-$SCRIPT_DIR/../config/oracle_license.rules}"
INSTANCES_FILE="${INSTANCES_FILE:-$SCRIPT_DIR/../config/oracle_instances.conf}"
ORATAB="${ORATAB:-/etc/oratab}"

STATE=0
INSTANCES=0
QUERIED=0
VIOLATIONS=0
FAILURES=0

TMPBASE="${TMPDIR:-/tmp}/check_oracle_license.$$"
DETAILS="$TMPBASE.details"
: > "$DETAILS" || exit 3

cleanup() {
    rm -f "$TMPBASE".* 2>/dev/null
}
trap cleanup 0 1 2 3 15

set_state() {
    # Nagios: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN.
    case "$1" in
        CRITICAL) [ "$STATE" -lt 2 ] && STATE=2 ;;
        WARNING)  [ "$STATE" -lt 1 ] && STATE=1 ;;
        UNKNOWN)  [ "$STATE" -lt 3 ] && STATE=3 ;;
    esac
}

check_rules() {
    sid="$1"
    outfile="$2"

    [ -r "$RULES_FILE" ] || return 0

    while IFS='|' read severity source pattern rest
    do
        case "$severity" in
            ""|\#*) continue ;;
        esac

        case "$severity" in
            WARNING|CRITICAL) ;;
            *) continue ;;
        esac

        [ -n "$source" ] || source="ANY"
        [ -n "$pattern" ] || continue

        if [ "$source" = "ANY" ]; then
            matched=$(grep -Fi "$pattern" "$outfile" 2>/dev/null | head -1)
        else
            matched=$(grep -i "^$source|" "$outfile" 2>/dev/null | grep -Fi "$pattern" | head -1)
        fi

        if [ -n "$matched" ]; then
            VIOLATIONS=$((VIOLATIONS + 1))
            set_state "$severity"
            printf '%s\n' "$severity - $sid - rule [$source:$pattern] matched: $matched" >> "$DETAILS"
        fi
    done < "$RULES_FILE"
}

check_instance() {
    sid="$1"
    home="$2"

    [ -n "$sid" ] || return
    [ -n "$home" ] || return

    case "$sid" in
        \#*|"*"|+ASM*|+APX*) return ;;
    esac

    INSTANCES=$((INSTANCES + 1))

    sqlplus="$home/bin/sqlplus"
    if [ ! -x "$sqlplus" ]; then
        FAILURES=$((FAILURES + 1))
        set_state UNKNOWN
        printf '%s\n' "UNKNOWN - $sid - sqlplus not executable: $sqlplus" >> "$DETAILS"
        return
    fi

    out="$TMPBASE.$sid.out"
    ORACLE_SID="$sid"
    ORACLE_HOME="$home"
    PATH="$ORACLE_HOME/bin:/bin:/usr/bin:/sbin:/usr/sbin"
    export ORACLE_SID ORACLE_HOME PATH

    "$sqlplus" -s "/ as sysdba" @"$SQL_FILE" > "$out" 2>&1
    rc=$?

    if [ "$rc" -ne 0 ] || ! grep -Fq "META|CHECK_COMPLETE|YES" "$out" 2>/dev/null; then
        FAILURES=$((FAILURES + 1))
        set_state UNKNOWN
        err=$(grep -E '^(ORA-|SP2-|ERROR\|)' "$out" 2>/dev/null | head -1)
        [ -n "$err" ] || err="SQL*Plus returned rc=$rc"
        printf '%s\n' "UNKNOWN - $sid - $err" >> "$DETAILS"
        return
    fi

    QUERIED=$((QUERIED + 1))
    edition=$(grep -F "META|EDITION|" "$out" | head -1 | cut -d'|' -f3-)
    version=$(grep -F "META|VERSION|" "$out" | head -1 | cut -d'|' -f3-)
    dbname=$(grep -F "META|DATABASE|" "$out" | head -1 | cut -d'|' -f3-)
    pack=$(grep -F "PARAM|control_management_pack_access|" "$out" | head -1 | cut -d'|' -f3-)
    used=$(grep -c '^FEATURE|' "$out" 2>/dev/null)
    opts=$(grep -c '^OPTION|' "$out" 2>/dev/null)

    printf '%s\n' "INFO - $sid - db=$dbname edition=$edition version=$version packs=$pack installed_options=$opts used_features=$used" >> "$DETAILS"
    check_rules "$sid" "$out"
}

discover_from_file() {
    file="$1"
    while IFS='|' read sid home rest
    do
        case "$sid" in
            ""|\#*) continue ;;
        esac
        check_instance "$sid" "$home"
    done < "$file"
}

discover_from_oratab() {
    file="$1"
    while IFS=: read sid home autostart rest
    do
        case "$sid" in
            ""|\#*|"*"|+ASM*|+APX*) continue ;;
        esac
        check_instance "$sid" "$home"
    done < "$file"
}

if [ ! -r "$SQL_FILE" ]; then
    echo "UNKNOWN - Oracle license check SQL file not readable: $SQL_FILE"
    exit 3
fi

if [ -r "$INSTANCES_FILE" ] && grep -Eq '^[[:space:]]*[^#[:space:]][^|]*\|[^|[:space:]]+' "$INSTANCES_FILE" 2>/dev/null; then
    discover_from_file "$INSTANCES_FILE"
elif [ -r "$ORATAB" ]; then
    discover_from_oratab "$ORATAB"
else
    echo "UNKNOWN - no $INSTANCES_FILE and no readable $ORATAB"
    exit 3
fi

if [ "$INSTANCES" -eq 0 ]; then
    echo "UNKNOWN - no Oracle database instances discovered"
    exit 3
fi

case "$STATE" in
    0) status="OK" ;;
    1) status="WARNING" ;;
    2) status="CRITICAL" ;;
    *) status="UNKNOWN" ;;
esac

echo "$status - Oracle license inventory: discovered=$INSTANCES queried=$QUERIED violations=$VIOLATIONS failures=$FAILURES | instances=$INSTANCES queried=$QUERIED violations=$VIOLATIONS failures=$FAILURES"
cat "$DETAILS"
exit "$STATE"
