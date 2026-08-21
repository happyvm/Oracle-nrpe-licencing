# Oracle NRPE Licensing

Supervision de la **conformité des licences Oracle Database** via NRPE et
Centreon.

Détecte l'usage d'options et de management packs payants non couverts par
vos droits, calcule les licences Processor requises par le matériel, et
signale les dérives avant qu'un audit ne s'en charge.

## Principe

La collecte s'exécute **localement** sur le serveur de base de données,
en deux étages découplés :

```
Poller Centreon ──check_nrpe──> check_oracle_licensing.sh   (< 100 ms, lit le cache)
                                            ▲
                                            │
                                 /var/cache/oracle-licensing/SID.dat
                                            ▲
                                            │ timer systemd, 1×/jour
                                 oracle_licensing_collector.sh
                                 sqlplus / as sysdba + lscpu + dmidecode
```

Le découplage est structurant : la requête sur
`DBA_FEATURE_USAGE_STATISTICS` dépasse couramment la minute, alors que le
timeout NRPE est de 10 secondes.

Le choix de la collecte locale plutôt que d'un contrôle centralisé depuis
le poller est argumenté dans **[docs/architecture.md](docs/architecture.md)**.
En résumé : le comptage des cœurs physiques, la détection de
l'hyperviseur et l'inventaire des ORACLE_HOME n'existent pas côté SQL, et
c'est précisément là que se jouent les redressements d'audit.

## Installation

Sur chaque serveur de base de données, en root :

```bash
git clone https://github.com/happyvm/oracle-nrpe-licencing.git
cd oracle-nrpe-licencing
./bin/install.sh
```

Puis renseigner la **déclaration contractuelle** dans
`/etc/oracle-licensing/oracle-licensing.conf` :

```sh
LICENSED_OPTIONS="Partitioning,Diagnostics Pack,Tuning Pack"
LICENSED_PROCESSORS="16"
```

> Renseignez cette liste depuis vos **bons de commande Oracle**, jamais
> depuis ce qui est observé en base. Dans le second cas, l'outil
> validerait la dérive au lieu de la détecter.

Première collecte et vérification :

```bash
sudo -u oracle /usr/local/bin/oracle_licensing_collector.sh -v
/usr/lib/nagios/plugins/check_oracle_licensing.sh -s ORCL -m inventory -v
systemctl reload nrpe
```

Côté Centreon, suivre **[centreon/README.md](centreon/README.md)**.

## Modes de contrôle

| Mode | Objet |
|---|---|
| `options` | options et packs payants utilisés hors des droits déclarés |
| `processors` | licences Processor requises : `ceil(cœurs × facteur)` |
| `sessions` | high-water mark de sessions, plancher NUP |
| `freshness` | le collecteur tourne-t-il encore |
| `inventory` | restitution sans alerte, pour recensement |

Exemple :

```console
$ check_oracle_licensing.sh -s ORCL -m options
CRITICAL - ORCL/ORCL (EE 19.22.0.0.0): 4 option(s) non licenciee(s) en cours
d'utilisation: Advanced Compression,Diagnostics Pack,Multitenant,Partitioning;
1 option(s) non licenciee(s) avec usage historique: Tuning Pack
Options utilisees SANS licence declaree :
  Partitioning
    - Partitioning (user) (usages=3412, en cours=TRUE, dernier=2026-08-20 ;
      Tables ou index partitionnes crees par l'applicatif)
  Diagnostics Pack
    - AWR Report (usages=221, en cours=TRUE, dernier=2026-08-19)
    ...
```

La sortie longue nomme la feature exacte à l'origine du constat : le DBA
sait quoi corriger sans se reconnecter à la base.

## Niveaux de gravité

| Statut | Cas |
|---|---|
| CRITICAL | option non détenue **en cours d'utilisation**, ou option inutilisable dans l'édition installée |
| WARNING | option non détenue dont l'usage est **seulement historique** |
| OK | usage couvert, ou feature devenue gratuite dans cette version |

La distinction courant / historique évite de traiter au même niveau
d'urgence un `SQL Tuning Advisor` lancé une fois en 2021 et un
`Partitioning` actif en production.

## Table de correspondance

`etc/licensable-features.map` associe les noms de
`DBA_FEATURE_USAGE_STATISTICS` aux options commerciales. C'est de la
**donnée, pas du code** : elle se met à jour sans toucher aux scripts.

Elle gère notamment les pièges classiques :

- `Partitioning (system)` est gratuit, seul `(user)` engage la licence ;
- `SecureFiles (user)` est gratuit, seules la compression, la
  déduplication et le chiffrement sont payants ;
- `Spatial` et `Advanced Analytics` sont inclus sans supplément depuis
  décembre 2019 — signalés uniquement sur versions antérieures ;
- `Multitenant` n'est facturable qu'au-delà d'une PDB utilisateur (19c),
  via le seuil `AUX_COUNT`.

Référence : Oracle Support Doc ID 1317265.1 et le *Licensing Information
User Manual*.

## Tests

```bash
./tests/run_all.sh
```

63 tests s'exécutant **sans base Oracle**, plus l'analyse statique
`shellcheck` :

| Suite | Couverture |
|---|---|
| `run_tests.sh` (40) | les cinq modes, les seuils, l'absence de faux positifs, les cas limites — édition incompatible, instance arrêtée, cache périmé |
| `run_collector_tests.sh` (23) | découverte via `oratab`, nommage des caches, écriture atomique, filtres `--sid`/`EXCLUDE_SIDS`, `--dry-run`, instance arrêtée |

Le plugin est testé sur des caches de référence (`tests/fixtures/`), le
collecteur avec un `sqlplus` et un `oratab` simulés. C'est le bénéfice
direct de l'architecture en deux étages : la logique de conformité est
vérifiable hors production.

## Sécurité

- Le collecteur s'authentifie en `/ as sysdba` par appartenance au groupe
  OSDBA : **aucun mot de passe n'est stocké ni transmis**.
- Le compte NRPE n'a **aucun accès à la base**, seulement un droit de
  lecture sur le répertoire de cache.
- **Aucune entrée `sudoers` n'est requise.**
- Toutes les requêtes SQL sont en lecture seule.

## Prérequis

- Oracle Database 11.2 ou supérieur (testé jusqu'à 19c ; le SQL dégrade
  proprement sur les versions sans `V$PDBS` ni colonne `CDB`)
- Bash 4.2+, NRPE 3.x
- `lscpu` recommandé pour un comptage de cœurs fiable

## Licence

À définir avec l'équipe avant toute diffusion hors de l'organisation.
