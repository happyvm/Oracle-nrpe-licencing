# Intégration Centreon

## 1. Commandes

Créer une commande générique s'appuyant sur `check_nrpe`
(*Configuration > Commandes > Vérification*) :

**`check_oracle_licensing`**
```
$USER1$/check_nrpe -H $HOSTADDRESS$ -t 30 -c $ARG1$ -a $ARG2$ $ARG3$ $ARG4$
```

Le `-t 30` est confortable : le plugin distant répond en moins de
100 ms puisqu'il ne fait que lire un fichier. Cette marge couvre
uniquement la latence réseau.

## 2. Modèle de service

*Configuration > Services > Modèles* :

| Champ | Valeur |
|---|---|
| Nom | `Oracle-Licensing-Options` |
| Commande | `check_oracle_licensing` |
| Arguments | `!oracle_lic_options!$_HOSTORACLE_SID$` |
| Période de contrôle | `24x7` |
| Intervalle normal | `60` (minutes) |
| Tentatives max | `2` |

Un intervalle de 60 minutes est délibéré : la donnée sous-jacente ne
change qu'une fois par jour. Contrôler toutes les 5 minutes ne
produirait que du bruit et de la charge.

## 3. Services à déclarer

| Service | Commande NRPE | Arguments | Intervalle |
|---|---|---|---|
| `Oracle-Lic-Options` | `oracle_lic_options` | `SID` | 60 min |
| `Oracle-Lic-Processors` | `oracle_lic_processors` | `SID` | 60 min |
| `Oracle-Lic-Sessions` | `oracle_lic_sessions` | `SID`, `warn`, `crit` | 15 min |
| `Oracle-Lic-Freshness` | `oracle_lic_freshness` | `SID` | 30 min |
| `Oracle-Lic-Inventory` | `oracle_lic_inventory` | `SID` | 1440 min |

**N'appliquez pas `Oracle-Lic-Options` aux bases Oracle 9i.** La vue
`DBA_FEATURE_USAGE_STATISTICS` n'existe qu'à partir de 10.1 : le service
resterait UNKNOWN en permanence. Créez pour ces hôtes un modèle de
service distinct, sans le contrôle d'options. Voir
[docs/compatibility.md](../docs/compatibility.md).

**Les hôtes Windows** utilisent les mêmes noms de commandes NRPE, servis
par NSClient++ au lieu de l'agent NRPE. La configuration Centreon est
identique — commandes, arguments, seuils et métriques ne changent pas.

**`Oracle-Lic-Freshness` n'est pas optionnel.** Sans lui, une panne
silencieuse du timer de collecte figerait les données : tous les autres
services resteraient au vert sur un cache périmé, indéfiniment. C'est le
contrôle qui surveille les contrôles.

## 4. Macro d'hôte

Définir sur chaque hôte de base de données :

| Macro | Exemple |
|---|---|
| `_ORACLE_SID` | `ORCL` |

Pour un serveur hébergeant plusieurs instances, créer un service par SID
plutôt qu'une macro multivaluée : les statuts doivent rester
distinguables dans l'interface.

## 5. Données de performance

Métriques exposées, exploitables en graphes et en rapports :

| Métrique | Mode | Lecture |
|---|---|---|
| `unlicensed_now` | options | options non détenues, en cours d'utilisation |
| `unlicensed_past` | options | options non détenues, usage historique |
| `wrong_edition` | options | options inutilisables dans l'édition installée |
| `licensed_used` | options | options détenues effectivement utilisées |
| `processor_licenses` | processors | licences Processor requises par le matériel |
| `cpu_cores`, `cpu_sockets` | processors | inventaire matériel |
| `sessions_highwater` | sessions | pic de sessions |
| `nup_floor` | sessions | plancher NUP contractuel (25 × Processor) |
| `cache_age` | tous | âge de la collecte, en secondes |

`licensed_used` mérite une attention particulière en revue annuelle : une
option détenue dont la valeur reste à zéro sur douze mois est une option
payée pour rien, et un levier de renégociation.

## 6. Remontée d'alerte suggérée

| Statut | Signification | Destinataire |
|---|---|---|
| CRITICAL sur `unlicensed_now` | usage en cours non couvert | DBA **et** responsable des achats logiciels |
| CRITICAL sur `wrong_edition` | anomalie structurelle | DBA, traitement immédiat |
| WARNING sur `unlicensed_past` | usage passé à justifier | DBA, revue périodique |
| CRITICAL sur `freshness` | le contrôle ne fonctionne plus | équipe supervision |

La distinction entre les deux premières lignes compte : une option non
détenue mais achetable se règle par un bon de commande, tandis qu'une
option inutilisable dans l'édition installée exige une correction
technique — aucune commande Oracle ne peut la régulariser.
