# Oracle NRPE Licensing

Supervision de la **conformité des licences Oracle Database** via NRPE et
Centreon.

Détecte l'usage d'options et de management packs payants non couverts par
vos droits, calcule les licences Processor requises par le matériel, et
signale les dérives avant qu'un audit ne s'en charge.

**Périmètre** : Oracle 9i → 21c · RHEL 5 → 9 · Windows Server 2003 → 2025.

## Principe

La collecte s'exécute **localement** sur le serveur de base de données,
en deux étages découplés :

```
Poller Centreon ──check_nrpe──> check_oracle_licensing   (< 100 ms, lit le cache)
                                            ▲
                                            │
                                 /var/cache/oracle-licensing/SID.dat
                                            ▲
                                            │ timer systemd / tâche planifiée, 1×/jour
                                 oracle_licensing_collector
                                 sqlplus / as sysdba + inventaire matériel
```

Le découplage est structurant : la requête sur
`DBA_FEATURE_USAGE_STATISTICS` dépasse couramment la minute, alors que le
timeout NRPE est de 10 secondes.

Le choix de la collecte locale plutôt que d'un contrôle centralisé depuis
le poller est argumenté dans **[docs/architecture.md](docs/architecture.md)**.
En résumé : le comptage des cœurs physiques, la détection de
l'hyperviseur et l'inventaire des ORACLE_HOME n'existent pas côté SQL, et
c'est précisément là que se jouent les redressements d'audit.

## Deux sources de détection

| Source | Couvre | Disponible |
|---|---|---|
| **Relevé d'usage** — `DBA_FEATURE_USAGE_STATISTICS` | management packs, usages transitoires (compression RMAN, Data Guard…) | Oracle 10.1+ |
| **Preuves structurelles** — dictionnaire de données | Partitioning, Spatial, In-Memory, TDE, RAC, OLAP… | Oracle 8i+ |

Les preuves structurelles sont **plus fortes** pour ce qu'elles couvrent :
une table partitionnée existe ou n'existe pas, là où l'échantillonnage
MMON peut manquer un usage entre deux instantanés. C'est la seule source
sur 9i, et un recoupement utile ailleurs — les jeux de référence 11g et
12c contiennent des options qu'aucun relevé d'usage ne remonte.

S'y ajoutent trois **règles produit**, qui croisent des paramètres et la
version : seuil Multitenant, In-Memory Base Level, et exposition des
management packs via `CONTROL_MANAGEMENT_PACK_ACCESS`.

## Installation

### Unix

Sur chaque serveur de base de données, en root :

```bash
git clone https://github.com/happyvm/oracle-nrpe-licencing.git
cd oracle-nrpe-licencing
./bin/install.sh
```

### Windows (voie principale, PowerShell)

Dans une console PowerShell **élevée** :

```powershell
.\windows\install.ps1
```

Puis fusionner `windows\nsclient-oracle-licensing.ini` dans
`nsclient.ini`.

### Windows sans PowerShell (Server 2003, ou 2008 en PowerShell 1.0)

Dans une invite de commandes **administrateur** :

```bat
windows\install.cmd
```

Batch et Windows Script Host uniquement. Le script **détecte PowerShell
et s'arrête** s'il en trouve une version 2.0 ou supérieure, en renvoyant
vers `install.ps1` : VBScript étant déprécié, il ne doit être déployé que
là où il est indispensable. `/Force` outrepasse ce garde-fou pour le cas
d'une GPO restrictive.

Puis fusionner `windows\nsclient-oracle-licensing-vbs.ini` — jamais les
deux fichiers `.ini` à la fois, les noms de commandes sont identiques.

### Déclaration contractuelle

Dans tous les cas, renseigner ensuite le fichier de configuration
(`/etc/oracle-licensing/oracle-licensing.conf` ou
`C:\ProgramData\oracle-licensing\oracle-licensing.conf`, même syntaxe) :

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

Exemple sur une base 11g restée en configuration d'usine :

```console
$ check_oracle_licensing.sh -s DB11G -m options --licensed-options "Partitioning"
CRITICAL - DB11G/DB11G (EE 11.2.0.4.0): 1 option(s) non licenciee(s) en cours
d'utilisation: Advanced Compression; 2 pack(s) accessible(s) sans licence declaree
(CONTROL_MANAGEMENT_PACK_ACCESS=DIAGNOSTIC+TUNING): Diagnostics Pack,Tuning Pack
Options utilisees SANS licence declaree :
  Advanced Compression
    - oltp_compressed_tables : 12 objet(s) [preuve structurelle]
    - securefile_compressed : 4 objet(s) [preuve structurelle]
Packs accessibles sans licence declaree (aucun usage constate a ce jour) :
  Diagnostics Pack
  Tuning Pack
  CONTROL_MANAGEMENT_PACK_ACCESS=DIAGNOSTIC+TUNING autorise leur usage a tout moment.
  Si ces packs ne sont pas detenus, positionnez le parametre a NONE.
```

La sortie longue nomme la preuve exacte : le DBA sait quoi corriger sans
se reconnecter à la base.

## Niveaux de gravité

| Statut | Cas |
|---|---|
| CRITICAL | option non détenue **en cours d'utilisation**, ou option inutilisable dans l'édition installée |
| WARNING | usage **seulement historique**, ou pack **accessible** sans licence déclarée, ou cache périmé |
| OK | usage couvert, ou feature devenue gratuite dans cette version |
| UNKNOWN | cache **inexploitable** — collecte en échec, instance arrêtée, rapport tronqué — ou entrée invalide |

**Un OK signifie « vérifié et conforme », jamais « rien trouvé ».** Si la
collecte a échoué ou si le rapport est tronqué, le plugin rend UNKNOWN
plutôt qu'un vert trompeur.

La distinction courant / historique évite de traiter au même niveau
d'urgence un `SQL Tuning Advisor` lancé une fois en 2021 et un
`Partitioning` actif en production.

## Compatibilité

Détail complet dans **[docs/compatibility.md](docs/compatibility.md)**.

| Plateforme | Statut |
|---|---|
| RHEL 5 → 9 | supporté (shell POSIX + awk ; replis pour `lscpu`, `timeout`, `systemd`) |
| Windows Server 2008 R2 → 2025 | supporté (PowerShell 2.0+, NSClient++) |
| Windows Server 2003, et 2008 en PowerShell 1.0 | supporté via VBScript / Windows Script Host |
| Oracle 10.1 → 21c | supporté |
| Oracle 9i | partiel — preuves structurelles seules |

**Points de vigilance par version :**

1. **Oracle 9i** : pas de relevé d'usage. Le verdict repose sur les
   preuves structurelles et porte la mention `[couverture partielle]`.
   Hors de portée : management packs et usages sans objet persistant.
2. **Oracle 11.1+** : `CONTROL_MANAGEMENT_PACK_ACCESS` vaut
   `DIAGNOSTIC+TUNING` par défaut en EE — une base neuve autorise les
   management packs sans les avoir achetés.
3. **Oracle 18c** suit les règles de **12.2**, pas de 19c : une seule PDB
   incluse, Privilege Analysis encore payant.
4. **Oracle 19c+** : 3 PDB incluses, et Column Store jusqu'à 16 Go inclus
   au titre du Base Level depuis 19.8.
5. **VBScript** est déprécié depuis 2023 : à réserver aux serveurs sans
   PowerShell.

## Tables de correspondance

Deux fichiers, en **donnée et non en code**, mis à jour sans toucher aux
scripts :

| Fichier | Contenu |
|---|---|
| `etc/licensable-features.map` | 69 règles associant les noms de `DBA_FEATURE_USAGE_STATISTICS` aux options commerciales |
| `etc/structural-evidence.map` | 20 règles associant les preuves du dictionnaire aux options |

Les pièges classiques sont gérés :

- `Partitioning (system)` est gratuit, seul `(user)` engage la licence ;
- `SecureFiles (user)` est gratuit, seules la compression, la
  déduplication et le chiffrement sont payants ;
- MDSYS est exclu du comptage Spatial — c'est le schéma de l'option ;
- la compression n'est détectée qu'à partir de 11.1, où `COMPRESS_FOR`
  distingue BASIC (incluse) d'OLTP (payante) ;
- les gratuités par version sont appliquées : Spatial et Advanced
  Analytics depuis 12.2, Flashback Data Archive depuis 12.1.0.2,
  Privilege Analysis depuis 19c.

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

**Sans aucune base Oracle**, ni machine Windows :

| Suite | Cas | Couverture |
|---|---|---|
| `run_tests.sh` | 106 | les cinq modes, les seuils, l'absence de faux positifs, et les particularités de chaque version — 9i à 21c |
| `run_collector_tests.sh` | 28 | découverte via `oratab`, nommage des caches, écriture atomique, filtres, `--dry-run`, instance arrêtée |
| `run_parity_tests.sh` | 42 | verdicts identiques entre les trois moteurs |

Les deux premières suites sont rejouées **sous chaque shell disponible**
(`dash`, `bash 3.2`, `bash 5.x`), et le moteur awk est vérifié sous
`gawk`, `mawk` et `nawk` — soit **444 exécutions de test**. S'y ajoute
`shellcheck -S warning`, sans avertissement.

Neuf jeux de référence dans `tests/fixtures/`, un par cas
caractéristique : 9i, 10g, 11g, 12c, 18c, 19c, 21c, SE2 hors édition, et
instance arrêtée. Le moteur VBScript est exercé via `cscript` sous wine.

Quelques éléments **n'ont pas pu être vérifiés par exécution** et sont à
couvrir en recette : les accès WMI et registre des collecteurs Windows,
le comportement sous PowerShell 2.0 et sous le WSH réel, et le SQL contre
de vraies instances. Le détail est dans
[docs/compatibility.md](docs/compatibility.md).

## Structure

```
bin/          collecteur, plugin et installateur Unix (shell POSIX)
lib/          licensing_eval.awk — moteur d'évaluation Unix
sql/          collect_licensing.sql — extraction PL/SQL, 9i → 21c
etc/          configuration, tables de correspondance, NRPE, cron
systemd/      unité et timer du collecteur
windows/      collecteurs et plugins PowerShell et VBScript, NSClient++
centreon/     guide d'intégration côté poller
docs/         architecture et matrice de compatibilité
tests/        suites de tests et jeux de référence
```

## Sécurité

- Le collecteur s'authentifie en `/ as sysdba` par appartenance au groupe
  OSDBA (Unix) ou ORA_DBA (Windows) : **aucun mot de passe n'est stocké
  ni transmis**.
- Le compte NRPE n'a **aucun accès à la base**, seulement un droit de
  lecture sur le répertoire de cache.
- **Aucune entrée `sudoers` n'est requise.**
- Le fichier de configuration est analysé, jamais exécuté, côté Windows.
- Toutes les requêtes SQL sont en lecture seule.

## Prérequis

- Oracle Database 9.2 ou supérieur (fonctionnalités selon la version)
- Unix : shell POSIX et awk — aucune dépendance à bash 4
- Windows : PowerShell 2.0+, ou Windows Script Host
- NRPE 3.x (Unix) ou NSClient++ (Windows)
- `lscpu` (Unix) ou WMI (Windows) recommandés pour un comptage de cœurs
  fiable ; sinon renseigner `CORE_FACTOR`

## Licence

À définir avec l'équipe avant toute diffusion hors de l'organisation.
