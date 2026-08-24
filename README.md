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

### Windows (voie principale, PowerShell)

Dans une console PowerShell **élevée** :

```powershell
.\windows\install.ps1
```

Puis fusionner `windows\nsclient-oracle-licensing.ini` dans
`nsclient.ini`.

### Windows sans PowerShell (Server 2003, ou 2008 en PowerShell 1.0)

Dans une invite de commandes **administrateur**, à la racine du dépôt :

```bat
windows\install.cmd
```

Batch et Windows Script Host uniquement, aucune dépendance à PowerShell.
Le script **détecte PowerShell et s'arrête** s'il en trouve une version
2.0 ou supérieure, en renvoyant vers `install.ps1` : VBScript étant
déprécié, il ne doit être déployé que là où il est indispensable.
`/Force` outrepasse ce garde-fou, pour le cas où une GPO interdit
l'exécution de scripts PowerShell.

Puis fusionner `windows\nsclient-oracle-licensing-vbs.ini` dans
`nsclient.ini` — jamais les deux fichiers à la fois, les noms de
commandes sont identiques.

Dans les deux cas, renseigner ensuite
`C:\ProgramData\oracle-licensing\oracle-licensing.conf` (même fichier
et même syntaxe que sous Unix) et redémarrer NSClient++.

Le compte exécutant la tâche planifiée doit appartenir au groupe local
**ORA_DBA**, sans quoi la connexion `/ as sysdba` échoue.

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
| WARNING | option non détenue dont l'usage est **seulement historique**, ou management pack **accessible** sans licence déclarée |
| OK | usage couvert, ou feature devenue gratuite dans cette version |

Sur Oracle 11.1 et au-delà, `CONTROL_MANAGEMENT_PACK_ACCESS` vaut
`DIAGNOSTIC+TUNING` par défaut en Enterprise Edition : une base neuve
autorise les management packs même sans les avoir achetés. Le plugin
signale cette **exposition** en WARNING (`exposed_packs`) — une porte
ouverte n'est pas un usage constaté — et indique la remédiation.

La distinction courant / historique évite de traiter au même niveau
d'urgence un `SQL Tuning Advisor` lancé une fois en 2021 et un
`Partitioning` actif en production.

## Table de correspondance

`etc/licensable-features.map` associe les noms de
`DBA_FEATURE_USAGE_STATISTICS` aux options commerciales. C'est de la
**donnée, pas du code** : elle se met à jour sans toucher aux scripts.

Elle est complétée par `etc/structural-evidence.map`, qui associe des
**preuves structurelles** — l'existence d'objets dans le dictionnaire —
aux options correspondantes. Une table partitionnée prouve l'usage de
Partitioning plus sûrement qu'un relevé MMON, qui échantillonne. C'est
la seule source disponible sur 9i, et un recoupement utile ailleurs.

La table des features gère notamment les pièges classiques :

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

# Pour couvrir aussi bash 3.2 (RHEL 5) et les deux moteurs Windows :
BASH32=/chemin/vers/bash-3.2 \
PWSH=$(command -v pwsh) \
WINE=$(command -v wine64) \
  ./tests/run_all.sh
```

Le moteur VBScript est exercé via `cscript` sous wine, ce qui permet de
le tester sans machine Windows.

**Sans aucune base Oracle**, ni machine Windows :

| Suite | Couverture |
|---|---|
| `run_tests.sh` (53) | les cinq modes, les seuils, l'absence de faux positifs, les cas limites — édition incompatible, instance arrêtée, cache périmé, Oracle 9i et 10g |
| `run_collector_tests.sh` (23) | découverte via `oratab`, nommage des caches, écriture atomique, filtres `--sid`/`EXCLUDE_SIDS`, `--dry-run`, instance arrêtée |
| `run_parity_tests.sh` (26) | verdicts identiques entre les trois moteurs : awk, VBScript et PowerShell |

Les deux premières suites sont rejouées **sous chaque shell disponible**
(`dash`, `bash 3.2`, `bash 5.x`), et le moteur awk est vérifié sous
`gawk`, `mawk` et `nawk` — soit 254 exécutions de test au total.
S'y ajoute `shellcheck -S warning`, sans avertissement.

Le plugin est testé sur des caches de référence (`tests/fixtures/`), le
collecteur avec un `sqlplus` et un `oratab` simulés. C'est le bénéfice
direct de l'architecture en deux étages : la logique de conformité est
vérifiable hors production.

Quelques éléments **n'ont pas pu être vérifiés par exécution** et sont à
couvrir en recette : les accès WMI et registre des collecteurs Windows,
le comportement sous PowerShell 2.0 et sous le WSH réel de Windows, et
le SQL contre de vraies instances 9i à 19c. Le détail est dans
[docs/compatibility.md](docs/compatibility.md).

## Sécurité

- Le collecteur s'authentifie en `/ as sysdba` par appartenance au groupe
  OSDBA : **aucun mot de passe n'est stocké ni transmis**.
- Le compte NRPE n'a **aucun accès à la base**, seulement un droit de
  lecture sur le répertoire de cache.
- **Aucune entrée `sudoers` n'est requise.**
- Toutes les requêtes SQL sont en lecture seule.

## Compatibilité

Périmètre couvert : **Windows Server 2003 → 2025**, **RHEL 5 → 9**,
**Oracle 9i → 19c**. Détail complet dans
**[docs/compatibility.md](docs/compatibility.md)**.

| Plateforme | Statut |
|---|---|
| RHEL 5 → 9 | supporté (shell POSIX + awk ; replis pour `lscpu`, `timeout`, `systemd`) |
| Windows Server 2008 R2 → 2025 | supporté via **PowerShell 2.0+** (voie principale) |
| Windows Server 2003, et 2008 en PowerShell 1.0 | supporté via **VBScript / Windows Script Host**, uniquement là où PowerShell manque |
| Oracle 10.1 → 21c | supporté |
| Oracle 9i | **dégradé** — voir ci-dessous |

**Trois limites à connaître avant de déployer :**

1. **Sur Oracle 9i, le contrôle d'usage est partiel.**
   `DBA_FEATURE_USAGE_STATISTICS` n'existe qu'à partir de 10.1, mais le
   dictionnaire permet de prouver directement l'usage des options
   structurelles — Partitioning, Spatial, OLAP, Label Security, RAC. Le
   mode `options` rend donc un verdict réel, assorti de la mention
   `[couverture partielle]`. Restent hors de portée sur 9i : les
   management packs et les usages sans objet persistant.
2. **VBScript n'est déployé que là où PowerShell manque.** Le langage
   est déprécié depuis 2023 (livré jusqu'à Server 2025, puis
   fonctionnalité à la demande) : l'installateur batch refuse de
   s'exécuter s'il détecte PowerShell 2.0 ou supérieur, pour ne pas lier
   un serveur moderne à un langage en fin de vie.
3. **Trois moteurs implémentent la même logique** (awk, VBScript,
   PowerShell). `tests/run_parity_tests.sh` les compare sur des données
   identiques ; toute modification de la logique doit le faire passer.

**Pourquoi le moteur est en awk plutôt qu'en bash.** Les tableaux
associatifs exigent bash 4.0 et les références nommées bash 4.3 : un
moteur en bash moderne aurait exclu RHEL 5, 6 et 7. Les scripts sont
donc en shell POSIX et délèguent l'évaluation à
`lib/licensing_eval.awk`.

## Prérequis

- Oracle Database 9.2 ou supérieur (fonctionnalités selon la version)
- Unix : shell POSIX et awk — aucune dépendance à bash 4
- Windows : PowerShell 2.0 ou supérieur, NSClient++
- NRPE 3.x
- `lscpu` (Unix) ou WMI (Windows) recommandés pour un comptage de cœurs
  fiable ; sinon renseigner `CORE_FACTOR` et le nombre de cœurs

## Licence

À définir avec l'équipe avant toute diffusion hors de l'organisation.
