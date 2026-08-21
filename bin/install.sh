#!/usr/bin/env bash
#
# Installe le collecteur, le plugin NRPE et leurs donnees sur un serveur
# de base de donnees Oracle. A executer en root.
#
set -o errexit
set -o nounset
set -o pipefail

SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd); readonly SRC

PLUGIN_DIR=${PLUGIN_DIR:-/usr/lib/nagios/plugins}
CONF_DIR=${CONF_DIR:-/etc/oracle-licensing}
LIB_DIR=${LIB_DIR:-/usr/lib/oracle-licensing}
CACHE_DIR=${CACHE_DIR:-/var/cache/oracle-licensing}
NRPE_DIR=${NRPE_DIR:-/etc/nrpe.d}
BIN_DIR=${BIN_DIR:-/usr/local/bin}
ORACLE_USER=${ORACLE_USER:-oracle}
ORACLE_GROUP=${ORACLE_GROUP:-dba}
NRPE_GROUP=${NRPE_GROUP:-nagios}

[[ $(id -u) -eq 0 ]] || { echo "ce script doit tourner en root" >&2; exit 1; }

echo "== Repertoires"
install -d -m 0755 "$PLUGIN_DIR" "$CONF_DIR" "$LIB_DIR" "$BIN_DIR"

# Le cache appartient a Oracle, qui l'ecrit, et est lisible par NRPE,
# qui ne fait que le lire. Aucun droit d'ecriture cote supervision.
install -d -m 0750 -o "$ORACLE_USER" -g "$NRPE_GROUP" "$CACHE_DIR"

echo "== Collecteur"
install -m 0755 -o root -g root "$SRC/bin/oracle_licensing_collector.sh" "$BIN_DIR/"
install -m 0644 -o root -g root "$SRC/sql/collect_licensing.sql"         "$LIB_DIR/"

echo "== Plugin NRPE"
install -m 0755 -o root -g root "$SRC/bin/check_oracle_licensing.sh" "$PLUGIN_DIR/"

echo "== Donnees de reference"
install -m 0644 -o root -g root "$SRC/etc/licensable-features.map" "$CONF_DIR/"

# La configuration porte la declaration contractuelle : on ne l'ecrase
# jamais lors d'une mise a jour.
if [[ -f $CONF_DIR/oracle-licensing.conf ]]; then
    echo "   configuration existante conservee : $CONF_DIR/oracle-licensing.conf"
    install -m 0644 "$SRC/etc/oracle-licensing.conf.example" "$CONF_DIR/oracle-licensing.conf.example"
else
    install -m 0644 "$SRC/etc/oracle-licensing.conf.example" "$CONF_DIR/oracle-licensing.conf"
    echo "   configuration initiale deposee -- A RENSEIGNER : LICENSED_OPTIONS"
fi

echo "== Declenchement periodique"
if [[ -d /run/systemd/system ]]; then
    install -m 0644 "$SRC/systemd/oracle-licensing-collector.service" /etc/systemd/system/
    install -m 0644 "$SRC/systemd/oracle-licensing-collector.timer"   /etc/systemd/system/
    sed -i "s/^User=oracle$/User=$ORACLE_USER/;s/^Group=dba$/Group=$ORACLE_GROUP/" \
        /etc/systemd/system/oracle-licensing-collector.service
    systemctl daemon-reload
    systemctl enable --now oracle-licensing-collector.timer
    echo "   timer actif : $(systemctl show -p NextElapseUSecRealtime --value oracle-licensing-collector.timer)"
else
    install -m 0644 "$SRC/etc/cron.d-oracle-licensing" /etc/cron.d/oracle-licensing
    echo "   cron installe (systemd absent)"
fi

echo "== Commandes NRPE"
if [[ -d $NRPE_DIR ]]; then
    install -m 0644 "$SRC/etc/nrpe.d/oracle-licensing.cfg" "$NRPE_DIR/"
    echo "   pensez a recharger NRPE : systemctl reload nrpe"
else
    echo "   $NRPE_DIR absent : copiez etc/nrpe.d/oracle-licensing.cfg a la main" >&2
fi

cat <<EOF

Installation terminee.

Etapes suivantes :
  1. Renseignez la declaration contractuelle dans
     $CONF_DIR/oracle-licensing.conf
     (LICENSED_OPTIONS et LICENSED_PROCESSORS, depuis vos bons de
     commande Oracle -- pas depuis ce qui est observe en base).
  2. Lancez une premiere collecte :
     sudo -u $ORACLE_USER $BIN_DIR/oracle_licensing_collector.sh -v
  3. Verifiez le rendu :
     $PLUGIN_DIR/check_oracle_licensing.sh -s <SID> -m inventory -v
  4. Declarez les services cote Centreon (voir centreon/README.md).
EOF
