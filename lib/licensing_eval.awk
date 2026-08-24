# =====================================================================
# licensing_eval.awk
#
# Moteur d'evaluation de la conformite des licences Oracle.
#
# POURQUOI AWK
#
# Le parc cible couvre RHEL 5 a 9, soit bash 3.2 a 5.1. Or les tableaux
# associatifs exigent bash 4.0 (donc RHEL 6+) et les references nommees
# bash 4.3 (donc RHEL 8+). Un moteur ecrit en bash moderne exclurait
# RHEL 5, 6 et 7 -- une grande partie d'un parc Oracle typique.
#
# awk est present sur toutes ces versions, sa syntaxe n'a pas bouge
# depuis POSIX 1992, et il offre nativement ce dont ce moteur a besoin.
# Le script appelant reste une glue mince compatible bash 3.2.
#
# Ce fichier s'en tient volontairement au POSIX awk : ni asort, ni
# length(tableau), ni gensub, ni delete d'un tableau entier -- toutes
# des extensions gawk absentes de nawk et des mawk anciens.
#
# Appel :
#   awk -v mode=... -v now=... [...] -f licensing_eval.awk MAP EVIDENCE CACHE
#
# Dans l'ordre : la table de correspondance des features, la table des
# preuves structurelles, puis le cache de l'instance.
# Code retour : convention Nagios (0/1/2/3).
# =====================================================================

# ---------------------------------------------------------------------
# Tri par insertion des cles d'un tableau, concatenees par ", ".
# Volume attendu : quelques dizaines d'entrees au plus.
# ---------------------------------------------------------------------
function join_sorted(arr,    i, j, n, k, tmp, v, s) {
    n = 0
    for (k in arr) { n++; tmp[n] = k }
    for (i = 2; i <= n; i++) {
        v = tmp[i]; j = i - 1
        while (j > 0 && tmp[j] > v) { tmp[j + 1] = tmp[j]; j-- }
        tmp[j + 1] = v
    }
    s = ""
    for (i = 1; i <= n; i++) s = s (i > 1 ? "," : "") tmp[i]
    return s
}

function count_keys(arr,    k, n) {
    n = 0
    for (k in arr) n++
    return n
}

# ---------------------------------------------------------------------
# Comparaison de versions Oracle : "19.22.0.0.0" >= "12.2" vaut vrai.
# Les composants absents comptent pour zero.
# ---------------------------------------------------------------------
function version_ge(a, b,    x, y, na, nb, i, k, u, v) {
    na = split(a, x, ".")
    nb = split(b, y, ".")
    k = (na > nb ? na : nb)
    for (i = 1; i <= k; i++) {
        u = (i <= na ? x[i] + 0 : 0)
        v = (i <= nb ? y[i] + 0 : 0)
        if (u > v) return 1
        if (u < v) return 0
    }
    return 1
}

function human_age(s) {
    if (s < 3600)   return int(s / 60)    " min"
    if (s < 172800) return int(s / 3600)  " h"
    return int(s / 86400) " j"
}

# ---------------------------------------------------------------------
# Une option est-elle declaree detenue ? Comparaison insensible a la
# casse et aux espaces de bord.
# ---------------------------------------------------------------------
function is_licensed(opt,    i, n, parts, want, have) {
    if (licensed_options == "") return 0
    want = tolower(opt)
    gsub(/^[ \t]+|[ \t]+$/, "", want)
    n = split(licensed_options, parts, ",")
    for (i = 1; i <= n; i++) {
        have = tolower(parts[i])
        gsub(/^[ \t]+|[ \t]+$/, "", have)
        if (have == want) return 1
    }
    return 0
}

BEGIN {
    FS = "|"
    OK = 0; WARNING = 1; CRITICAL = 2; UNKNOWN = 3
    nrules = 0
    nev = 0
    filenum = 0
}

FNR == 1 { filenum++ }

# ---------------------------------------------------------------------
# Premier fichier : correspondance features -> options payantes.
# ---------------------------------------------------------------------
filenum == 1 {
    if ($0 ~ /^[ \t]*(#|$)/) next
    if (NF != 6) next                     # ligne malformee : ignoree
    nrules++
    r_pat[nrules]  = $1
    r_opt[nrules]  = $2
    r_eds[nrules]  = $3
    r_aux[nrules]  = $4 + 0
    r_free[nrules] = $5
    r_note[nrules] = $6
    next
}

# ---------------------------------------------------------------------
# Second fichier : preuves structurelles.
# ---------------------------------------------------------------------
filenum == 2 {
    if ($0 ~ /^[ \t]*(#|$)/) next
    if (NF != 6) next
    nev++
    e_key[nev]  = $1
    e_opt[nev]  = $2
    e_eds[nev]  = $3
    e_min[nev]  = $4 + 0
    e_free[nev] = $5
    e_note[nev] = $6
    next
}

# ---------------------------------------------------------------------
# Second fichier : le cache de l'instance.
# ---------------------------------------------------------------------
$1 == "KV"   { kv[$2] = $3; next }
$1 == "OPT"  { optv[$2] = $3; next }
$1 == "FEAT" {
    feat_used[$2]  = $3
    feat_det[$2]   = $4
    feat_last[$2]  = $5
    feat_first[$2] = $6
    feat_aux[$2]   = $7
    nfeat++
    next
}
$1 == "HWM"  { hwm[$2] = $3; next }
$1 == "OBJ"  { objv[$2] = $3; next }

# =====================================================================
END {
    db_name    = (kv["db.name"]    != "" ? kv["db.name"]    : sid)
    edition    = (kv["db.edition"] != "" ? kv["db.edition"] : "UNKNOWN")
    version    = (kv["inst.version"] != "" ? kv["inst.version"] : "0")
    vmajor     = kv["db.version_major"] + 0
    cstatus    = (kv["collect.status"] != "" ? kv["collect.status"] : "unknown")
    cepoch     = kv["collect.epoch"] + 0
    age        = now - cepoch

    # Capacite de collecte : absente des caches produits par une version
    # anterieure du collecteur, auquel cas on se rabat sur la version
    # majeure de la base.
    if (kv["collect.cap.feature_usage"] != "")
        cap_usage = kv["collect.cap.feature_usage"] + 0
    else
        cap_usage = (vmajor == 0 || vmajor >= 10) ? 1 : 0

    if      (mode == "options")    rc = mode_options()
    else if (mode == "processors") rc = mode_processors()
    else if (mode == "sessions")   rc = mode_sessions()
    else if (mode == "freshness")  rc = mode_freshness()
    else if (mode == "inventory")  rc = mode_inventory()
    else {
        printf "UNKNOWN - mode inconnu : %s (options|processors|sessions|freshness|inventory)\n", mode
        rc = UNKNOWN
    }
    exit rc
}

# =====================================================================
# Mode "options" : detection de derive de conformite.
#
# Regroupement par OPTION et non par feature : on achete une option, pas
# une feature. Une option est retenue des lors qu'au moins une de ses
# features est utilisee.
#
#   CRITICAL  option non detenue et en cours d'utilisation, ou option
#             inutilisable dans l'edition installee
#   WARNING   option non detenue dont l'usage est seulement historique
#   OK        usage couvert, ou feature devenue gratuite dans la version
# =====================================================================
# Packs exposes par CONTROL_MANAGEMENT_PACK_ACCESS.
#
# Ce parametre (11.1 et suivants) commande l'acces aux management packs.
# Sa valeur par defaut en Enterprise Edition est DIAGNOSTIC+TUNING : une
# base neuve autorise donc leur usage, meme sans les avoir achetes.
# Oracle recommande NONE dans ce cas.
#
# Une base exposee n'est pas une base en infraction : c'est une porte
# ouverte, pas un usage constate. D'ou une categorie distincte, en
# WARNING, qui laisse le CRITICAL aux usages averes.
#
# La correspondance est une regle du produit Oracle, pas une donnee
# susceptible d'evoluer avec le contrat : elle reste dans le code.
function packs_exposed(value, arr,    v, n) {
    n = 0
    v = toupper(value)
    gsub(/[ \t]/, "", v)
    if (v == "" || v == "NONE") return 0
    if (v == "DIAGNOSTIC" || v == "DIAGNOSTIC+TUNING") { arr["Diagnostics Pack"] = 1; n++ }
    if (v == "DIAGNOSTIC+TUNING")                      { arr["Tuning Pack"] = 1;      n++ }
    return n
}

function mode_options(    i, f, det, used, aux, opt, matched, lf, lp,
                          status, label, parts, np, stale, o, grp, msg,
                          cnt, nstruct, partial, cmpa, n_exp) {
    if (nrules == 0) {
        printf "UNKNOWN - table de correspondance vide ou illisible\n"
        return UNKNOWN
    }

    for (f in feat_det) {
        det = feat_det[f] + 0
        if (det <= 0) continue

        matched = 0
        for (i = 1; i <= nrules; i++) {
            # Regex dynamique : la valeur lue est compilee comme ERE, donc
            # "\(" y designe une parenthese litterale.
            if (tolower(f) ~ tolower(r_pat[i])) { matched = i; break }
        }
        if (!matched) continue           # feature non payante

        opt  = r_opt[matched]
        used = toupper(feat_used[f])
        aux  = feat_aux[f] + 0
        lf   = r_free[matched]
        lp   = r_aux[matched]

        # Seuil AUX_COUNT : Multitenant n'est facturable qu'au-dela d'une
        # PDB, l'usage en deca est inclus dans l'edition.
        if (lp > 0 && aux <= lp) continue

        # Feature devenue gratuite dans cette version.
        if (lf != "-" && version_ge(version, lf)) { freed[opt] = 1; continue }

        detail[opt] = detail[opt] sprintf("\n    - %s (usages=%d, en cours=%s, depuis=%s, dernier=%s%s)", \
                      f, det, used, \
                      (feat_first[f] != "" ? feat_first[f] : "-"), \
                      (feat_last[f]  != "" ? feat_last[f]  : "-"), \
                      (r_note[matched] != "" ? " ; " r_note[matched] : ""))

        # Option non vendable dans cette edition : anomalie structurelle
        # qu'aucun bon de commande ne peut regulariser.
        if (r_eds[matched] != "ALL" && edition != "UNKNOWN" \
            && index("," r_eds[matched] ",", "," edition ",") == 0) {
            wrong_edition[opt] = 1
            continue
        }

        if (is_licensed(opt))        covered[opt]  = 1
        else if (used == "TRUE")     viol_now[opt] = 1
        else                         viol_past[opt] = 1
    }

    # ------------------------------------------------------------------
    # Preuves structurelles.
    #
    # Un objet qui existe atteste un usage COURANT : ces constats vont
    # donc toujours en infraction courante, jamais en historique.
    # C'est la seule source disponible sur Oracle 9i, et un recoupement
    # utile ailleurs -- l'echantillonnage MMON peut manquer un usage,
    # une table partitionnee ne se cache pas.
    # ------------------------------------------------------------------
    for (i = 1; i <= nev; i++) {
        cnt = objv[e_key[i]]
        if (cnt == "") continue           # preuve non collectee
        cnt = cnt + 0
        if (cnt <= e_min[i]) continue

        opt = e_opt[i]
        if (e_free[i] != "-" && version_ge(version, e_free[i])) { freed[opt] = 1; continue }

        detail[opt] = detail[opt] sprintf("\n    - %s : %d objet(s) [preuve structurelle]%s", \
                      e_key[i], cnt, (e_note[i] != "" ? " ; " e_note[i] : ""))
        nstruct++

        if (e_eds[i] != "ALL" && edition != "UNKNOWN" \
            && index("," e_eds[i] ",", "," edition ",") == 0) {
            wrong_edition[opt] = 1
            continue
        }
        if (is_licensed(opt)) covered[opt] = 1
        else                  viol_now[opt] = 1
    }

    # Une option deja en infraction courante ne doit pas etre recomptee.
    for (o in viol_now)      delete viol_past[o]
    for (o in wrong_edition) { delete viol_now[o]; delete viol_past[o]; delete covered[o] }

    # ------------------------------------------------------------------
    # Exposition aux management packs (11.1 et suivants).
    #
    # On ne signale que ce qui n'est pas deja constate : une option deja
    # en infraction n'a pas besoin d'etre annoncee comme "exposee".
    # ------------------------------------------------------------------
    cmpa = kv["param.control_management_pack_access"]
    if (packs_exposed(cmpa, exposed) > 0) {
        for (o in exposed) {
            if (is_licensed(o) || (o in viol_now) || (o in viol_past) || (o in wrong_edition))
                delete exposed[o]
        }
    }

    n_now = count_keys(viol_now)
    n_past = (ignore_historical ? 0 : count_keys(viol_past))
    n_cov = count_keys(covered)
    n_edt = count_keys(wrong_edition)
    n_exp = count_keys(exposed)

    status = OK; label = "OK"
    if (n_edt > 0 || n_now > 0)      { status = CRITICAL; label = "CRITICAL" }
    else if (n_past > 0 || n_exp > 0) { status = WARNING;  label = "WARNING"  }

    # Un cache perime rend le verdict caduc, sans masquer une infraction
    # deja constatee.
    stale = ""
    if (age > max_cache_age) {
        stale = sprintf(" [cache perime: %s]", human_age(age))
        if (status == OK) { status = WARNING; label = "WARNING" }
    }

    msg = ""; np = 0
    if (n_edt > 0)
        { msg = msg (np++ ? "; " : "") sprintf("%d option(s) incompatible(s) avec l'edition %s: %s", n_edt, edition, join_sorted(wrong_edition)) }
    if (n_now > 0)
        { msg = msg (np++ ? "; " : "") sprintf("%d option(s) non licenciee(s) en cours d'utilisation: %s", n_now, join_sorted(viol_now)) }
    if (n_past > 0)
        { msg = msg (np++ ? "; " : "") sprintf("%d option(s) non licenciee(s) avec usage historique: %s", n_past, join_sorted(viol_past)) }
    if (n_exp > 0)
        { msg = msg (np++ ? "; " : "") sprintf("%d pack(s) accessible(s) sans licence declaree (CONTROL_MANAGEMENT_PACK_ACCESS=%s): %s", n_exp, cmpa, join_sorted(exposed)) }
    if (np == 0)
        { msg = sprintf("aucune derive detectee sur %d option(s) declaree(s)", n_cov) }

    # Sans DBA_FEATURE_USAGE_STATISTICS (avant Oracle 10.1), seules les
    # preuves structurelles sont disponibles. Le verdict reste valable
    # pour ce qu'il couvre, mais ne doit pas se faire passer pour complet.
    partial = ""
    if (!cap_usage)
        partial = " [couverture partielle: analyse structurelle seule, releve d'usage absent avant Oracle 10.1]"

    printf "%s - %s/%s (%s %s): %s%s%s", label, db_name, sid, edition, version, msg, stale, partial
    printf "|unlicensed_now=%d;;1;0 unlicensed_past=%d;1;;0 wrong_edition=%d;;1;0 exposed_packs=%d;1;;0 licensed_used=%d;;;0 cache_age=%ds;;%d;0\n", \
           n_now, n_past, n_edt, n_exp, n_cov, age, max_cache_age

    # Sortie longue : elle permet au DBA d'agir sans se reconnecter.
    if (verbose || status != OK) {
        if (n_edt > 0)  print_group("Options incompatibles avec l'edition installee :", wrong_edition)
        if (n_now > 0)  print_group("Options utilisees SANS licence declaree :", viol_now)
        if (n_past > 0) print_group("Options non licenciees, usage historique uniquement :", viol_past)
        if (n_exp > 0) {
            printf "Packs accessibles sans licence declaree (aucun usage constate a ce jour) :\n"
            for (o in exposed) printf "  %s\n", o
            printf "  CONTROL_MANAGEMENT_PACK_ACCESS=%s autorise leur usage a tout moment.\n", cmpa
            printf "  Si ces packs ne sont pas detenus, positionnez le parametre a NONE.\n"
        }
        if (verbose && n_cov > 0) print_group("Options couvertes par la declaration :", covered)
        if (verbose && count_keys(freed) > 0)
            printf "Features payantes par le passe, incluses en %s : %s\n", version, join_sorted(freed)
        if (!cap_usage) {
            printf "Oracle %s : DBA_FEATURE_USAGE_STATISTICS n'existe qu'a partir de 10.1.\n", version
            printf "Ce verdict repose sur les seules preuves structurelles du dictionnaire.\n"
            printf "Non couverts sur cette version : management packs Diagnostics et Tuning,\n"
            printf "et les usages sans objet persistant (compression RMAN, Data Guard, Data Pump).\n"
        }
    }
    return status
}

function print_group(title, arr,    i, n, k, tmp, v, j) {
    print title
    n = 0
    for (k in arr) { n++; tmp[n] = k }
    for (i = 2; i <= n; i++) {
        v = tmp[i]; j = i - 1
        while (j > 0 && tmp[j] > v) { tmp[j + 1] = tmp[j]; j-- }
        tmp[j + 1] = v
    }
    for (i = 1; i <= n; i++) printf "  %s%s\n", tmp[i], detail[tmp[i]]
}

# =====================================================================
# Mode "processors" : licences Processor requises par le materiel.
#
# ceil(coeurs physiques x facteur de coeur). En virtualisation dite
# "soft partitioning" (VMware, KVM, Hyper-V), Oracle considere que tout
# hote ou la VM peut migrer doit etre licencie : le chiffre est donc un
# PLANCHER, jamais un plafond.
# =====================================================================
function mode_processors(    cores, sockets, factor, required, virt,
                             reliable, status, label, msg) {
    cores    = kv["host.cpu.cores"] + 0
    sockets  = kv["host.cpu.sockets"] + 0
    factor   = (kv["host.core_factor"] != "" ? kv["host.core_factor"] : "1.0")
    required = kv["host.processor_licenses"] + 0
    virt     = (kv["host.virt"] != "" ? kv["host.virt"] : "none")
    reliable = (kv["host.cpu.reliable"] != "" ? kv["host.cpu.reliable"] + 0 : 1)

    status = OK; label = "OK"
    msg = sprintf("%d licence(s) Processor requise(s) (%d coeurs x facteur %s, %d socket(s))", \
                  required, cores, factor, sockets)

    if (licensed_processors != "") {
        if (required > licensed_processors + 0) {
            status = CRITICAL; label = "CRITICAL"
            msg = msg sprintf(", %d detenue(s) -- deficit de %d", \
                              licensed_processors + 0, required - (licensed_processors + 0))
        } else {
            msg = msg sprintf(", %d detenue(s)", licensed_processors + 0)
        }
    } else {
        msg = msg ", aucune declaration de reference"
    }

    # SE2 est plafonnee a 2 sockets ; SE1 et SE l'etaient a 2 et 4.
    # Au-dela, l'installation est non conforme quel que soit le nombre
    # de licences detenues.
    if (edition == "SE2" && sockets > 2) {
        status = CRITICAL; label = "CRITICAL"
        msg = msg sprintf(" ; SE2 limitee a 2 sockets, %d detectes", sockets)
    } else if (edition == "SE1" && sockets > 2) {
        status = CRITICAL; label = "CRITICAL"
        msg = msg sprintf(" ; SE1 limitee a 2 sockets, %d detectes", sockets)
    } else if (edition == "SE" && sockets > 4) {
        status = CRITICAL; label = "CRITICAL"
        msg = msg sprintf(" ; SE limitee a 4 sockets, %d detectes", sockets)
    }

    if (!reliable) {
        if (status == OK) { status = WARNING; label = "WARNING" }
        msg = msg " ; comptage de coeurs non fiable (lscpu indisponible)"
    }

    if (virt != "none" && virt != "kvm-guest") {
        msg = msg sprintf(" ; hyperviseur '%s' detecte : verifier la regle de licence du cluster", virt)
        if (status == OK) { status = WARNING; label = "WARNING" }
    }

    printf "%s - %s/%s: %s", label, db_name, sid, msg
    printf "|processor_licenses=%d;;%s;0 cpu_cores=%d;;;0 cpu_sockets=%d;;;0 cache_age=%ds;;%d;0\n", \
           required, licensed_processors, cores, sockets, age, max_cache_age
    return status
}

# =====================================================================
# Mode "sessions" : high-water mark de sessions.
#
# Sert au dimensionnement Named User Plus. Le minimum contractuel Oracle
# est de 25 NUP par licence Processor en Enterprise Edition.
# =====================================================================
function mode_sessions(    inst_hwm, hist_hwm, peak, current, maxs,
                           procs, nup_floor, status, label, msg) {
    inst_hwm  = kv["license.sessions_highwater"] + 0
    hist_hwm  = hwm["SESSIONS"] + 0
    current   = kv["license.sessions_current"] + 0
    maxs      = kv["license.sessions_max"] + 0
    procs     = kv["host.processor_licenses"] + 0
    nup_floor = procs * 25

    # V$LICENSE.sessions_highwater repart de zero a chaque redemarrage de
    # l'instance ; DBA_HIGH_WATER_MARK_STATISTICS conserve le pic
    # historique. Retenir le plus eleve des deux, sans quoi un simple
    # redemarrage effacerait le pic reel du dimensionnement.
    peak = (hist_hwm > inst_hwm ? hist_hwm : inst_hwm)

    status = OK; label = "OK"
    msg = sprintf("high-water mark %d session(s), %d en cours", peak, current)
    if (maxs > 0) msg = msg sprintf(", plafond sessions_max=%d", maxs)
    if (hist_hwm > inst_hwm)
        msg = msg sprintf(" (pic historique %d > pic depuis demarrage %d)", hist_hwm, inst_hwm)
    msg = msg sprintf(" ; plancher NUP contractuel: %d (25 x %d Processor)", nup_floor, procs)

    if (crit != "" && peak >= crit + 0)      { status = CRITICAL; label = "CRITICAL" }
    else if (warn != "" && peak >= warn + 0) { status = WARNING;  label = "WARNING"  }

    printf "%s - %s/%s: %s", label, db_name, sid, msg
    printf "|sessions_highwater=%d;%s;%s;0 sessions_current=%d;;;0 sessions_hwm_instance=%d;;;0 nup_floor=%d;;;0\n", \
           peak, warn, crit, current, inst_hwm, nup_floor
    return status
}

# =====================================================================
# Mode "freshness" : le collecteur tourne-t-il encore ?
#
# A superviser en propre : sans lui, une panne silencieuse du declencheur
# figerait les donnees et tous les autres controles resteraient au vert.
# =====================================================================
function mode_freshness(    status, label, msg) {
    status = OK; label = "OK"
    msg = sprintf("derniere collecte il y a %s (%s), statut=%s", \
                  human_age(age), \
                  (kv["collect.date"] != "" ? kv["collect.date"] : "inconnue"), \
                  cstatus)

    if (cepoch == 0) {
        status = UNKNOWN; label = "UNKNOWN"
        msg = "horodatage de collecte absent du cache"
    } else if (age > max_cache_age * 2) {
        status = CRITICAL; label = "CRITICAL"
    } else if (age > max_cache_age) {
        status = WARNING; label = "WARNING"
    }

    if (cstatus == "instance_down") {
        if (status == OK) { status = WARNING; label = "WARNING" }
        msg = msg " (instance arretee lors de la derniere collecte)"
    } else if (cstatus == "query_failed") {
        status = CRITICAL; label = "CRITICAL"
        msg = msg " (l'interrogation SQL a echoue)"
    }

    printf "%s - %s/%s: %s|cache_age=%ds;%d;%d;0\n", \
           label, db_name, sid, msg, age, max_cache_age, max_cache_age * 2
    return status
}

# =====================================================================
# Mode "inventory" : restitution sans alerte, pour la documentation et
# les campagnes de recensement avant negociation contractuelle.
# =====================================================================
function mode_inventory(    k, nopt, n, i, tmp, v, j) {
    nopt = 0
    for (k in optv) if (toupper(optv[k]) == "TRUE") nopt++

    printf "OK - %s/%s: %s %s, %s, %d coeurs/%d sockets, %d option(s) liee(s), %d feature(s) tracee(s)", \
           db_name, sid, edition, version, \
           (kv["db.role"] != "" ? kv["db.role"] : "-"), \
           kv["host.cpu.cores"] + 0, kv["host.cpu.sockets"] + 0, nopt, nfeat + 0
    printf "|linked_options=%d;;;0 tracked_features=%d;;;0 processor_licenses=%d;;;0 cache_age=%ds;;;0\n", \
           nopt, nfeat + 0, kv["host.processor_licenses"] + 0, age

    printf "Hote          : %s (%s, %s)\n", \
           (kv["host.name"] != "" ? kv["host.name"] : "-"), \
           (kv["host.cpu.model"] != "" ? kv["host.cpu.model"] : "-"), \
           (kv["host.virt"] != "" ? kv["host.virt"] : "none")
    printf "Base          : %s / DBID %s / role %s / mode %s\n", \
           db_name, \
           (kv["db.dbid"] != "" ? kv["db.dbid"] : "-"), \
           (kv["db.role"] != "" ? kv["db.role"] : "-"), \
           (kv["db.open_mode"] != "" ? kv["db.open_mode"] : "-")
    printf "ORACLE_HOME   : %s\n", (kv["inst.oracle_home"] != "" ? kv["inst.oracle_home"] : "-")
    printf "RAC           : %s instance(s)\n", (kv["db.rac_instances"] != "" ? kv["db.rac_instances"] : "1")
    printf "Multitenant   : CDB=%s, %d PDB utilisateur\n", \
           (kv["db.cdb"] != "" ? kv["db.cdb"] : "NO"), kv["db.pdb_count"] + 0
    printf "Facteur coeur : %s -> %d licence(s) Processor\n", \
           (kv["host.core_factor"] != "" ? kv["host.core_factor"] : "-"), \
           kv["host.processor_licenses"] + 0

    # Sur les versions anterieures a 10.1, l'absence de controle d'usage
    # doit apparaitre dans l'inventaire : c'est une limite structurelle,
    # pas un defaut de collecte.
    if (!cap_usage)
        printf "Usage options : INDISPONIBLE sur Oracle %s (requiert 10.1+)\n", version

    if (verbose) {
        print "Options liees au binaire (V$OPTION = TRUE) :"
        n = 0
        for (k in optv) if (toupper(optv[k]) == "TRUE") { n++; tmp[n] = k }
        for (i = 2; i <= n; i++) {
            v = tmp[i]; j = i - 1
            while (j > 0 && tmp[j] > v) { tmp[j + 1] = tmp[j]; j-- }
            tmp[j + 1] = v
        }
        for (i = 1; i <= n; i++) printf "  - %s\n", tmp[i]
    }
    return OK
}
