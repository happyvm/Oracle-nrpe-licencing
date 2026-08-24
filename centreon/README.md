# Intégration Centreon

## 1. Commande

*Configuration > Commandes > Vérification* :

**`check_oracle_licensing`**
```
$USER1$/check_nrpe -H $HOSTADDRESS$ -t 30 -c $ARG1$ -a $ARG2$ $ARG3$ $ARG4$
```

Le `-t 30` est confortable : le plugin distant répond en moins de
100 ms, puisqu'il ne fait que lire un fichier. Cette marge ne couvre que
la latence réseau.

La même commande sert pour les hôtes Unix (agent NRPE) et Windows
(NSClient++). Côté Centreon, rien ne distingue un hôte Linux d'un hôte
Windows, ni un Windows moderne d'un Server 2003.

## 2. Services à déclarer

| Service | Commande NRPE | Arguments | Intervalle |
|---|---|---|---|
| `Oracle-Lic-Options` | `oracle_lic_options` | `SID` | 60 min |
| `Oracle-Lic-Processors` | `oracle_lic_processors` | `SID` | 60 min |
| `Oracle-Lic-Sessions` | `oracle_lic_sessions` | `SID`, `warn`, `crit` | 15 min |
| `Oracle-Lic-Freshness` | `oracle_lic_freshness` | `SID` | 30 min |
| `Oracle-Lic-Inventory` | `oracle_lic_inventory` | `SID` | 1440 min |

Un intervalle de 60 minutes est délibéré : la donnée sous-jacente ne
change qu'une fois par jour. Contrôler toutes les 5 minutes ne
produirait que du bruit et de la charge.

**`Oracle-Lic-Freshness` n'est pas optionnel.** Sans lui, une panne
silencieuse du collecteur figerait les données : tous les autres
services resteraient au vert sur un cache périmé, indéfiniment. C'est le
contrôle qui surveille les contrôles.

## 3. Modèle de service

| Champ | Valeur |
|---|---|
| Nom | `Oracle-Licensing-Options` |
| Commande | `check_oracle_licensing` |
| Arguments | `!oracle_lic_options!$_HOSTORACLE_SID$` |
| Période de contrôle | `24x7` |
| Intervalle normal | `60` (minutes) |
| Tentatives max | `2` |

## 4. Macro d'hôte

| Macro | Exemple |
|---|---|
| `_ORACLE_SID` | `ORCL` |

Pour un serveur hébergeant plusieurs instances, créer un service par SID
plutôt qu'une macro multivaluée : les statuts doivent rester
distinguables dans l'interface.

## 5. Cas des bases Oracle 9i

`Oracle-Lic-Options` **fonctionne** sur 9i, mais avec une couverture
partielle : `DBA_FEATURE_USAGE_STATISTICS` n'existe qu'à partir de 10.1,
et le verdict y repose sur les seules preuves structurelles du
dictionnaire.

La sortie porte la mention `[couverture partielle]`. Ne sont pas
couverts : les management packs, et les usages sans objet persistant
(compression RMAN, Data Guard, Data Pump).

Le service reste utile — il détecte Partitioning, de loin la première
cause de redressement. Prévoyez simplement que son OK ne vaut pas
attestation de conformité intégrale.

## 6. Données de performance

| Métrique | Mode | Lecture |
|---|---|---|
| `unlicensed_now` | options | options non détenues, en cours d'utilisation |
| `unlicensed_past` | options | options non détenues, usage historique |
| `wrong_edition` | options | options inutilisables dans l'édition installée |
| `exposed_packs` | options | management packs accessibles sans licence déclarée |
| `licensed_used` | options | options détenues effectivement utilisées |
| `processor_licenses` | processors | licences Processor requises par le matériel |
| `cpu_cores`, `cpu_sockets` | processors | inventaire matériel |
| `sessions_highwater` | sessions | pic de sessions, historique inclus |
| `nup_floor` | sessions | plancher NUP contractuel (25 × Processor) |
| `cache_age` | tous | âge de la collecte, en secondes |

`licensed_used` mérite une attention en revue annuelle : une option
détenue dont la valeur reste à zéro sur douze mois est une option payée
pour rien, et un levier de renégociation.

`exposed_packs` est le premier chiffre à faire tomber à zéro sur un parc
11g : c'est la valeur par défaut d'Oracle qui le fait remonter, pas un
usage.

## 7. Remontée d'alerte suggérée

| Statut | Signification | Destinataire |
|---|---|---|
| CRITICAL sur `unlicensed_now` | usage en cours non couvert | DBA **et** responsable des achats logiciels |
| CRITICAL sur `wrong_edition` | anomalie structurelle | DBA, traitement immédiat |
| WARNING sur `exposed_packs` | porte ouverte, pas d'usage constaté | DBA, correction de paramètre |
| WARNING sur `unlicensed_past` | usage passé à justifier | DBA, revue périodique |
| CRITICAL sur `freshness` | le contrôle ne fonctionne plus | équipe supervision |

La distinction entre les trois premières lignes compte :

- une option **non détenue mais achetable** se règle par un bon de
  commande ;
- une option **inutilisable dans l'édition installée** exige une
  correction technique, aucune commande Oracle ne la régularise ;
- un **pack accessible** se règle par un `ALTER SYSTEM`, sans dépense.
