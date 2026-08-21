# Matrice de compatibilité

Périmètre visé : Windows Server 2003 → 2025, RHEL 5 → 9, Oracle 9i → 19c.

Ce document dit ce qui fonctionne, ce qui fonctionne en mode dégradé, et
ce qui ne peut pas fonctionner. La troisième catégorie n'est pas vide, et
c'est délibérément la première chose énoncée.

---

## Les trois limites dures

### 1. Oracle 9i : le contrôle d'usage des options est impossible

`DBA_FEATURE_USAGE_STATISTICS` n'existe **qu'à partir d'Oracle 10.1**. En
9i, la base n'enregistre nulle part quelles options ont été utilisées.
Aucun outil, quel qu'il soit, ne peut reconstituer cette information a
posteriori.

Ce que 9i permet encore :

| Contrôle | 9i | Pourquoi |
|---|---|---|
| Options liées au binaire (`V$OPTION`) | oui | présent depuis 8i |
| Sessions, high-water mark (`V$LICENSE`) | oui | présent depuis 8i |
| Licences Processor (inventaire OS) | oui | ne dépend pas de la base |
| **Usage réel des options payantes** | **non** | vue inexistante |

Le mode `options` renvoie donc **UNKNOWN** sur 9i, avec un message
explicite. C'est volontaire : afficher OK laisserait croire à une
conformité qui n'a pas été vérifiée, ce qui est pire que pas de contrôle
du tout.

**Conséquence pratique :** ne déclarez pas le service `Oracle-Lic-Options`
dans Centreon pour les bases 9i — il resterait UNKNOWN en permanence.
Déclarez `inventory`, `sessions` et `processors`.

### 2. Windows Server 2003 n'embarque aucun PowerShell

Windows Server 2003 est livré sans PowerShell, et est en fin de support
depuis **juillet 2015**. PowerShell 2.0 y est installable manuellement
(via WMF 2.0 sur 2003 SP2), et le code de ce dépôt le vise explicitement.

Sans cette installation préalable, rien ne fonctionne sur 2003. Il n'y a
pas de solution de contournement raisonnable : réécrire les scripts en
VBScript ou en batch pour couvrir une plateforme hors support depuis dix
ans coûterait plus cher que d'installer WMF 2.0.

### 3. Le moteur Windows est une seconde implémentation

Windows n'a ni awk ni shell POSIX. La logique de conformité y est donc
réimplémentée en PowerShell. Deux implémentations d'une même règle
divergent toujours à terme.

La parade est `tests/run_parity_tests.sh` : 26 cas comparent le code
retour et la ligne de statut des deux moteurs sur des caches identiques.
**Toute modification de la logique doit passer ce test.**

---

## Systèmes d'exploitation

### Linux (Red Hat Enterprise Linux et dérivés)

| Version | bash | awk | Statut | Remarques |
|---|---|---|---|---|
| RHEL 5 | 3.2 | gawk 3.1 | supporté | pas de `lscpu` ni de `timeout` : replis intégrés |
| RHEL 6 | 4.1 | gawk 3.1 | supporté | `lscpu` présent, pas de systemd → cron |
| RHEL 7 | 4.2 | gawk 4.0 | supporté | systemd |
| RHEL 8 | 4.4 | gawk 4.2 | supporté | systemd |
| RHEL 9 | 5.1 | gawk 5.1 | supporté | systemd |

**Pourquoi le moteur est en awk.** Les tableaux associatifs exigent
bash 4.0 (RHEL 6+) et les références nommées bash 4.3 (RHEL 8+). Une
implémentation en bash moderne aurait exclu RHEL 5, 6 et 7 — soit la
majeure partie d'un parc Oracle typique. Les scripts sont donc en shell
POSIX strict et délèguent l'évaluation à `lib/licensing_eval.awk`.

Replis spécifiques aux versions anciennes :

| Absence | Version | Repli |
|---|---|---|
| `lscpu` | RHEL 5 | lecture de `/proc/cpuinfo` |
| `timeout` | RHEL 5 | chien de garde en arrière-plan intégré au collecteur |
| `systemd-detect-virt` | RHEL 5, 6 | `virt-what`, puis `dmidecode`, puis l'indicateur `hypervisor` de `/proc/cpuinfo` |
| `systemd` | RHEL 5, 6 | `/etc/cron.d/oracle-licensing` |
| `pgrep` | installations minimales | `ps -ef` |

Quand le comptage des cœurs ne peut être établi de façon fiable, le
collecteur pose `host.cpu.reliable=0` et le mode `processors` passe en
WARNING plutôt que d'affirmer un chiffre faux.

### Windows Server

| Version | PowerShell natif | Statut |
|---|---|---|
| 2003 / 2003 R2 | **aucun** | WMF 2.0 à installer au préalable ; hors support Microsoft depuis 2015 |
| 2008 | 1.0 | mettre à jour vers PowerShell 2.0 (WMF 2.0) |
| 2008 R2 | 2.0 | supporté |
| 2012 / 2012 R2 | 3.0 / 4.0 | supporté |
| 2016 | 5.1 | supporté |
| 2019 / 2022 / 2025 | 5.1 | supporté |

Le code Windows vise **PowerShell 2.0** et évite donc :
`[pscustomobject]`, `[ordered]`, `Get-CimInstance`, l'opérateur `-in`,
`Get-Content -Raw`, les opérateurs `??` et `?.`.

`Get-WmiObject` ayant été supprimé en PowerShell 6, l'accès WMI passe par
une fonction qui choisit `Get-CimInstance` ou `Get-WmiObject` selon ce
qui est réellement disponible.

NRPE sous Windows passe par **NSClient++** : il n'existe pas d'agent NRPE
natif Microsoft. Le poller Centreon interroge le port 5666 exactement
comme sous Linux.

## Oracle Database

| Version | Usage options | HWM | Cœurs `V$OSSTAT` | Multitenant | Statut |
|---|---|---|---|---|---|
| 9.2 | **non** | non | non | non | dégradé — voir limite 1 |
| 10.1 / 10.2 | oui | oui | non | non | supporté |
| 11.1 / 11.2 | oui | oui | oui | non | supporté |
| 12.1 / 12.2 | oui | oui | oui | oui | supporté |
| 18c / 19c | oui | oui | oui | oui | supporté |

Vues apparues au fil des versions :

| Vue ou colonne | Depuis |
|---|---|
| `V$OPTION`, `V$LICENSE` | 8i |
| `DBA_FEATURE_USAGE_STATISTICS` | 10.1 |
| `DBA_HIGH_WATER_MARK_STATISTICS` | 10.1 |
| `V$OSSTAT` | 10.1 |
| `V$DATABASE.PLATFORM_NAME` | 10.1 |
| `V$OSSTAT.NUM_CPU_CORES` / `NUM_CPU_SOCKETS` | 11.1 |
| `V$LICENSE.CPU_CORE_COUNT_HIGHWATER` | 11.1 |
| `V$DATABASE.CDB`, `V$PDBS` | 12.1 |

`sql/collect_licensing.sql` est un bloc **PL/SQL dynamique** pour cette
raison précise : une requête statique référençant une vue absente échoue
à l'analyse syntaxique et interrompt tout le script. Le SQL dynamique
reporte cette résolution à l'exécution, ce qui permet d'encadrer chaque
section par son propre gestionnaire d'exception. Une section
indisponible est omise ; le reste du rapport est produit.

Le collecteur publie ce qu'il a pu obtenir sous forme d'indicateurs
`collect.cap.*`, que le plugin lit pour distinguer *« vérifié et
conforme »* de *« non vérifiable »*.

Deux détails qui piègent sur les versions anciennes :

- La bannière de version diffère : `Oracle9i Enterprise Edition` contre
  `Oracle Database 19c Enterprise Edition`. Le filtre couvre les deux.
- `SET SQLBLANKLINES ON` est indispensable : sans lui, une ligne vide à
  l'intérieur d'un bloc PL/SQL est prise pour une fin de commande par les
  SQL\*Plus anciens.

## Éditions

| Édition | Limite matérielle | Contrôlée |
|---|---|---|
| Enterprise Edition | aucune | — |
| Standard Edition 2 | 2 sockets | oui |
| Standard Edition One | 2 sockets | oui |
| Standard Edition | 4 sockets | oui |

Une option Enterprise utilisée sur une édition Standard produit un
CRITICAL distinct : c'est une anomalie structurelle qu'aucun bon de
commande ne peut régulariser, contrairement à une option simplement non
détenue. Le cas se rencontre après une restauration depuis un serveur
Enterprise Edition vers une plateforme Standard.

## Ce qui a été vérifié, et comment

| Élément | Vérification |
|---|---|
| Moteur awk | exécuté sous **gawk, mawk, nawk** |
| Scripts shell | exécutés sous **bash 3.2** (compilé pour ce test), **dash**, **bash 5.2** |
| Suites Unix | 76 tests, rejoués sous chacun des trois shells |
| Analyse statique | `shellcheck -S warning`, sans avertissement |
| Moteur PowerShell | exécuté sous **PowerShell 7.4** |
| Parité Unix/Windows | 26 cas comparés, codes retour et ligne de statut |

**Ce qui n'a pas pu être vérifié par exécution**, et doit l'être en
recette avant déploiement :

- Le chemin **WMI** du collecteur Windows (`Win32_Processor`,
  `Win32_Service`, registre `HKLM\SOFTWARE\ORACLE`) : ni WMI ni le
  registre n'existent hors de Windows.
- Le comportement réel sous **PowerShell 2.0** : seule la 7.4 était
  disponible. Le code évite les constructions postérieures à la 2.0,
  mais cela reste une revue, pas un test.
- Le **SQL** contre de vraies instances 9i, 10g, 11g, 12c et 19c :
  aucune base Oracle n'était disponible. La logique de dégradation par
  version est écrite et relue, non exécutée.

Ces trois points sont les premiers à couvrir en recette.
