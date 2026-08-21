# Architecture : pourquoi la collecte est locale

## La question

Faut-il exécuter les contrôles de licence **depuis le serveur qui héberge
la base**, ou **depuis un poller Centreon centralisé** en mode agentless
(connexion SQL*Net à distance) ?

## La réponse courte

Collecte **locale**, sur le serveur de base de données, exposée par NRPE.
Non par habitude, mais parce qu'une partie déterminante de la donnée de
conformité **n'existe pas côté SQL**.

## Ce qui décide

Le contrôle de licence Oracle repose sur trois familles de données. Seule
la première est accessible à distance.

| Donnée | Source | Accessible via SQL*Net distant |
|---|---|---|
| Options et packs utilisés | `DBA_FEATURE_USAGE_STATISTICS` | oui |
| High-water marks, sessions | `V$LICENSE`, `DBA_HIGH_WATER_MARK_STATISTICS` | oui |
| Options liées au binaire | `V$OPTION` | oui |
| Sockets et cœurs **physiques** | `lscpu`, `dmidecode` | **non** |
| Hyperviseur et règle de cluster | `systemd-detect-virt`, `virt-what` | **non** |
| Inventaire des ORACLE_HOME | `/etc/oratab`, `oraInventory` | **non** |
| Instances arrêtées ou en MOUNT | processus `ora_pmon_*` | **non** |

Les quatre dernières lignes ne sont pas des détails de confort : ce sont
elles qui produisent les redressements lors d'un audit Oracle LMS.

### 1. Le comptage processeur est un problème d'OS, pas de base

La facturation en métrique Processor s'établit sur
`ceil(cœurs physiques × facteur de cœur)`. `V$OSSTAT` ne rapporte que ce
que l'hyperviseur expose au guest. Une VM à 8 vCPU sur un hôte bi-socket
de 32 cœurs se déclare à 8 — alors que la règle Oracle de *soft
partitioning* impose de licencier l'hôte entier, voire l'ensemble du
cluster de migration.

Un contrôle centralisé rapporterait ici **8 au lieu de 32**, avec un vert
rassurant. C'est le pire résultat possible : un contrôle faux qui inspire
confiance.

### 2. Aucun secret à gérer

En local, la connexion se fait en `/ as sysdba` : l'authentification
repose sur l'appartenance au groupe OSDBA du compte qui exécute le
collecteur. Rien n'est stocké, rien ne transite.

Le mode centralisé imposerait, sur *chaque* base du parc : un compte
applicatif dédié, `SELECT_CATALOG_ROLE`, un coffre ou un wallet Oracle
sur le poller, et une procédure de rotation. Soit une surface de risque
nouvelle, créée pour un besoin de reporting.

### 3. Une seule ouverture de flux, déjà en place

Local : le poller parle NRPE sur 5666, port déjà ouvert pour le reste de
la supervision.

Centralisé : il faudrait ouvrir 1521 depuis le poller vers l'intégralité
des bases de production, et installer un client Oracle sur le poller.

### 4. Les instances qui ne répondent pas restent visibles

Une base en MOUNT (standby non ouverte) ou arrêtée ne peut pas être
interrogée. En local, le collecteur voit `/etc/oratab` et les processus
`pmon` : il publie une fiche marquée `instance_down`, et le contrôle
distingue *« arrêtée »* de *« jamais collectée »*. À distance, les deux
cas produisent le même timeout indifférencié.

## Le piège que l'architecture évite

La requête sur `DBA_FEATURE_USAGE_STATISTICS`, avec son agrégation sur
toutes les versions, prend couramment **30 à 60 secondes** sur une base
volumineuse. Le timeout NRPE par défaut est de **10 secondes**.

Brancher cette requête directement sur une commande NRPE produit un
contrôle qui expire de manière intermittente, sous charge — c'est-à-dire
exactement quand on en a besoin. D'où la séparation en deux étages :

```
  ┌──────────────────┐        check_nrpe (5666)        ┌──────────────────────────┐
  │  Poller Centreon │ ──────────────────────────────> │  Serveur Oracle          │
  └──────────────────┘                                 │                          │
                                                       │  check_oracle_licensing  │
                                                       │  < 100 ms, lecture seule │
                                                       │            ▲             │
                                                       │            │ lit         │
                                                       │  /var/cache/oracle-      │
                                                       │       licensing/SID.dat  │
                                                       │            ▲             │
                                                       │            │ écrit       │
                                                       │  oracle_licensing_       │
                                                       │       collector.sh       │
                                                       │  timer systemd, 03h17    │
                                                       │      │            │      │
                                                       │      ▼            ▼      │
                                                       │  sqlplus       lscpu     │
                                                       │  / as sysdba   dmidecode │
                                                       └──────────────────────────┘
```

L'étage lent tourne une fois par jour, en `Nice=19` et E/S `idle`.
L'étage rapide ne fait que lire un fichier plat.

Ce découplage a un second bénéfice, moins évident et tout aussi
important : **la logique de conformité devient testable hors
production**. Les 40 tests de `tests/run_tests.sh` s'exécutent sur des
caches de référence, sans la moindre base Oracle.

## Fréquence de collecte : pourquoi une fois par jour suffit

`DBA_FEATURE_USAGE_STATISTICS` est alimentée par MMON selon un
échantillonnage **hebdomadaire**. Collecter toutes les heures
n'apporterait aucune fraîcheur : on relirait la même valeur. Le rythme
quotidien laisse simplement une marge confortable si un run échoue.

En corollaire : **une option activée puis désactivée dans l'intervalle
entre deux snapshots MMON peut passer inaperçue.** Ce dispositif détecte
une dérive installée, pas un usage furtif. Un audit contractuel reste un
exercice distinct.

## Ce que le mode centralisé garderait pour lui

Il n'est pas sans mérite, et un mode distant pourra être ajouté pour les
cas où l'OS n'est pas accessible :

- **DBaaS et bases managées** (Autonomous, RDS Oracle) : pas d'OS, donc
  pas de collecteur possible. La collecte distante est alors le seul
  chemin.
- **Parc très étendu sans gestion de configuration** : un déploiement
  unique sur le poller au lieu de N installations.

Dans les deux cas, le résultat est **dégradé par construction** : sans
accès à l'OS, ni le comptage processeur ni l'inventaire des ORACLE_HOME
ne sont fiables. Le contrôle porte alors sur les options seulement, et
doit être présenté comme tel.

## Répartition des responsabilités

| Composant | Compte | Fréquence | Accès base |
|---|---|---|---|
| `oracle_licensing_collector.sh` | `oracle` (groupe OSDBA) | 1×/jour | lecture seule, `/ as sysdba` |
| `check_oracle_licensing.sh` | `nagios` (via NRPE) | à chaque contrôle | **aucun** |

Le compte de supervision n'a **jamais** accès à la base, et n'a que le
droit de lecture sur le répertoire de cache. Aucune entrée `sudoers`
n'est nécessaire — c'est volontaire, et cela doit le rester.

## Limites connues

- Le facteur de cœur est déduit de l'architecture (0,5 en x86_64). Sur
  SPARC ou POWER, il doit être fixé explicitement via `CORE_FACTOR`.
- La détection de virtualisation identifie l'hyperviseur, pas la
  topologie du cluster. La règle Oracle de licence du cluster entier
  reste une décision humaine : l'outil la signale, il ne la tranche pas.
- `LICENSED_OPTIONS` doit être renseigné depuis les **bons de commande**.
  Le renseigner depuis ce qui est observé en base transformerait le
  contrôle en validation automatique de la dérive.
- Le comptage Named User Plus ne peut pas être automatisé : l'outil
  calcule le plancher contractuel (25 NUP par Processor en EE) à partir
  du matériel, mais le décompte réel des utilisateurs relève de
  l'organisation.
