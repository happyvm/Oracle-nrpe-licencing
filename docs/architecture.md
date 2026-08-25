# Architecture

## 1. Pourquoi la collecte est locale

### La question d'origine

Faut-il exécuter les contrôles de licence **depuis le serveur qui héberge
la base**, ou **depuis un poller Centreon centralisé** en mode agentless
(connexion SQL\*Net à distance) ?

### La réponse

Collecte **locale**, sur le serveur de base de données, exposée par NRPE.
Non par habitude, mais parce qu'une partie déterminante de la donnée de
conformité **n'existe pas côté SQL**.

| Donnée | Source | Accessible via SQL\*Net distant |
|---|---|---|
| Options et packs utilisés | `DBA_FEATURE_USAGE_STATISTICS` | oui |
| High-water marks, sessions | `V$LICENSE`, `DBA_HIGH_WATER_MARK_STATISTICS` | oui |
| Options liées au binaire | `V$OPTION` | oui |
| Sockets et cœurs **physiques** | `lscpu`, `dmidecode`, WMI | **non** |
| Hyperviseur et règle de cluster | `systemd-detect-virt`, `Win32_ComputerSystem` | **non** |
| Inventaire des ORACLE_HOME | `/etc/oratab`, registre Windows | **non** |
| Instances arrêtées ou en MOUNT | processus `pmon`, services Windows | **non** |

Les quatre dernières lignes produisent les redressements en audit.

**Le comptage processeur est un problème d'OS, pas de base.** La
facturation en métrique Processor s'établit sur
`ceil(cœurs physiques × facteur de cœur)`. `V$OSSTAT` ne rapporte que ce
que l'hyperviseur expose au guest. Une VM à 8 vCPU sur un hôte bi-socket
de 32 cœurs se déclare à 8 — alors que la règle Oracle de *soft
partitioning* impose de licencier l'hôte entier, voire tout le cluster de
migration. Un contrôle centralisé rapporterait **8 au lieu de 32**, avec
un vert rassurant : le pire résultat possible, un contrôle faux qui
inspire confiance.

**Aucun secret à gérer.** En local, la connexion se fait en
`/ as sysdba` : l'authentification repose sur l'appartenance au groupe
OSDBA (Unix) ou ORA_DBA (Windows). Rien n'est stocké, rien ne transite.
Le mode centralisé imposerait sur *chaque* base un compte dédié,
`SELECT_CATALOG_ROLE`, un wallet sur le poller, et une rotation.

**Une seule ouverture de flux, déjà en place.** Le poller parle NRPE sur
5666. Le mode centralisé exigerait d'ouvrir 1521 vers toutes les
productions et d'installer un client Oracle sur le poller.

**Les instances qui ne répondent pas restent visibles.** Une base en
MOUNT ou arrêtée ne peut pas être interrogée. En local, le collecteur
voit `/etc/oratab` et les processus `pmon` : il publie une fiche marquée
`instance_down`, et le contrôle distingue *« arrêtée »* de *« jamais
collectée »*. À distance, les deux cas donnent le même timeout.

### Ce que le mode centralisé garderait pour lui

Il reste pertinent pour les **bases managées** (Autonomous, RDS Oracle),
où l'OS n'est pas accessible. Le résultat y est dégradé par
construction : ni comptage processeur, ni inventaire des ORACLE_HOME.

## 2. Les deux étages

La requête sur `DBA_FEATURE_USAGE_STATISTICS` dépasse couramment la
minute sur une base volumineuse. Le timeout NRPE par défaut est de
**10 secondes**. La brancher directement sur une commande NRPE produirait
un contrôle qui expire par intermittence, sous charge — c'est-à-dire
quand on en a besoin.

```
  ┌──────────────────┐      check_nrpe (5666)       ┌───────────────────────────┐
  │  Poller Centreon │ ───────────────────────────> │  Serveur de base          │
  └──────────────────┘                              │                           │
                                                    │  ÉTAGE RAPIDE             │
                                                    │  check_oracle_licensing   │
                                                    │  < 100 ms, lecture seule  │
                                                    │            ▲              │
                                                    │            │ lit          │
                                                    │  cache/<SID>.dat          │
                                                    │            ▲              │
                                                    │            │ écrit        │
                                                    │  ÉTAGE LENT               │
                                                    │  collector, 1×/jour       │
                                                    │  Nice=19, E/S idle        │
                                                    │      │            │       │
                                                    │      ▼            ▼       │
                                                    │  sqlplus       lscpu /    │
                                                    │  / as sysdba   WMI        │
                                                    └───────────────────────────┘
```

Bénéfice second, aussi important : **la logique de conformité devient
testable hors production**. Les suites de tests s'exécutent sur des
caches de référence, sans la moindre base Oracle.

### Fréquence

`DBA_FEATURE_USAGE_STATISTICS` est alimentée par MMON selon un
échantillonnage **hebdomadaire**. Collecter toutes les heures ne
donnerait aucune fraîcheur supplémentaire. Le rythme quotidien laisse une
marge si un run échoue.

Corollaire : **une option activée puis désactivée entre deux snapshots
MMON peut échapper au relevé d'usage.** C'est une des raisons d'être des
preuves structurelles (§4).

## 3. Trois moteurs, une seule logique

Le parc va de RHEL 5 à RHEL 9 et de Windows Server 2003 à 2025. Aucun
langage ne couvre tout cela nativement.

| Moteur | Fichier | Cible | Pourquoi |
|---|---|---|---|
| awk | `lib/licensing_eval.awk` | RHEL 5 → 9 | tableaux associatifs = bash 4.0, références nommées = bash 4.3 : un moteur en bash moderne exclurait RHEL 5, 6 et 7 |
| PowerShell | `windows/check_oracle_licensing.ps1` | Windows 2008 R2 → 2025 | voie principale sous Windows |
| VBScript | `windows/check_oracle_licensing.vbs` | Windows sans PowerShell | 2003 n'embarque aucun PowerShell ; WSH est natif de 2000 à 2025 |

Les scripts appelants sont en **shell POSIX** (Unix) et ne dépendent
d'aucune fonctionnalité bash.

**Trois implémentations d'une même règle divergent toujours à terme**, et
une divergence signifierait que deux serveurs rendent des verdicts
différents sur des données identiques. `tests/run_parity_tests.sh`
compare les trois sur des caches identiques : code retour et ligne de
statut. Sa capacité à détecter une divergence a été vérifiée par
injection volontaire.

## 4. Deux sources de détection

### Le relevé d'usage

`DBA_FEATURE_USAGE_STATISTICS` (Oracle 10.1+), agrégée sur toutes les
versions du DBID courant. `etc/licensable-features.map` associe les noms
de features aux options commerciales.

Ses angles morts : elle n'existe pas avant 10.1, et son échantillonnage
MMON peut manquer un usage survenu entre deux instantanés.

### Les preuves structurelles

Interrogation directe du dictionnaire : l'existence d'un objet atteste
l'usage. `etc/structural-evidence.map` porte la correspondance.

C'est **plus fort** qu'un relevé pour ce qu'elles couvrent : une table
partitionnée existe ou n'existe pas. C'est la seule source disponible sur
9i, et un recoupement utile partout ailleurs — les fixtures 11g et 12c
montrent des options qu'aucun relevé d'usage ne remonte.

Seul l'incontestable y figure : un objet dont l'existence même suppose
l'option. Les schémas livrés par Oracle sont exclus — MDSYS *est* le
schéma Spatial, et le compter ferait apparaître une option payante sur
toute base neuve.

Un objet qui existe atteste un usage **courant** : ces constats vont donc
en infraction courante, jamais en historique.

### Les règles produit

Trois contrôles ne se réduisent ni à un motif de feature, ni à un compte
d'objets : ils croisent des paramètres et la version. Ils vivent dans le
moteur, commentés, plutôt que dans une table à six champs.

| Règle | Pourquoi dans le code |
|---|---|
| **Multitenant** | 1 PDB incluse de 12.1 à 18c, 3 à partir de 19c — un seuil fixe accuserait à tort une 19c |
| **Database In-Memory** | croise `INMEMORY_FORCE`, `INMEMORY_SIZE` et la version (Base Level ≤ 16 Go inclus depuis 19.8) |
| **Exposition des packs** | `CONTROL_MANAGEMENT_PACK_ACCESS` vaut `DIAGNOSTIC+TUNING` par défaut en EE : une porte ouverte, pas un usage |

Les deux premières sont surchargeables par configuration, car les
limites Oracle ont déjà évolué.

**Articulation avec les tables.** Une règle produit et une règle de table
peuvent porter sur la même option sans faire double emploi : la table
reflète le **relevé d'usage**, y compris historique, tandis que la règle
produit juge l'**état actuel** de la configuration. Pour Database
In-Memory, un usage passé reste visible par la table après désactivation
du Column Store, que le moteur ne verrait plus. Quand la règle produit
conclut à une inclusion — Base Level, ou PDB sous le seuil — elle retire
explicitement l'option des constats : elle prime, sinon la table
accuserait une base qui n'a rien à licencier.

## 5. Niveaux de gravité

| Statut | Cas |
|---|---|
| CRITICAL | option non détenue **en cours d'utilisation**, ou option inutilisable dans l'édition installée |
| WARNING | usage **seulement historique**, ou pack **accessible** sans licence déclarée, ou cache périmé |
| OK | usage couvert, ou feature devenue gratuite dans cette version |
| UNKNOWN | cache absent ou **inexploitable**, entrée invalide, table illisible, mode inconnu |

**L'absence de constat ne vaut pas absence de dérive.** Avant de rendre
un verdict, le mode `options` vérifie que le cache est exploitable :
collecte réussie, rapport complet (sentinelle `collect.sql_complete`
posée en fin de script SQL), identité présente. Une collecte en échec,
une instance arrêtée ou un rapport tronqué donnent UNKNOWN, jamais OK.
Le mode `processors` applique le même principe à l'inventaire matériel :
zéro cœur détecté signifie « comptage indisponible », pas « aucune
licence requise ».

Les entrées sont validées avant usage. Le SID sert à construire le
chemin du cache et arrive du réseau via `$ARG1$` : il est restreint aux
identifiants Oracle légitimes. Les seuils doivent être des entiers
positifs — un seuil non numérique valait zéro à la comparaison et
produisait un WARNING permanent sans cause visible.

Une option inutilisable dans l'édition installée est traitée à part :
aucun bon de commande ne la régularise, contrairement à une option
simplement non détenue. Le cas se rencontre après restauration d'une base
Enterprise Edition sur une plateforme Standard.

## 6. Responsabilités

| Composant | Compte | Fréquence | Accès base |
|---|---|---|---|
| Collecteur | `oracle` (OSDBA / ORA_DBA) | 1×/jour | lecture seule, `/ as sysdba` |
| Plugin | `nagios` (via NRPE / NSClient++) | à chaque contrôle | **aucun** |

Le compte de supervision n'a **jamais** accès à la base, et n'a que le
droit de lecture sur le répertoire de cache. Aucune entrée `sudoers`
n'est nécessaire — c'est volontaire, et cela doit le rester.

## 7. Limites connues

- Le facteur de cœur est déduit de l'architecture (0,5 en x86_64). Sur
  SPARC ou POWER, il doit être fixé via `CORE_FACTOR`.
- La détection de virtualisation identifie l'hyperviseur, pas la
  topologie du cluster. La règle Oracle de licence du cluster entier
  reste une décision humaine : l'outil la signale, il ne la tranche pas.
- `LICENSED_OPTIONS` doit être renseigné depuis les **bons de commande**.
  Le renseigner depuis ce qui est observé en base transformerait le
  contrôle en validation automatique de la dérive.
- Le comptage Named User Plus ne peut pas être automatisé : l'outil
  calcule le plancher contractuel (25 NUP par Processor en EE) à partir
  du matériel, le décompte réel relève de l'organisation.
- Les seuils Multitenant et In-Memory Base Level reposent sur des règles
  Oracle qui ont déjà changé. Confrontez-les au *Licensing Information
  User Manual* de votre version.

Le détail par version est dans [compatibility.md](compatibility.md).
