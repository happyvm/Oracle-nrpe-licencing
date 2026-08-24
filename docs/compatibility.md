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

### 2. Windows Server 2003 : résolu par VBScript, sans PowerShell

Windows Server 2003 est livré sans PowerShell. Plutôt que d'imposer
l'installation de WMF 2.0 sur un parc existant, le dépôt fournit une
implémentation **Windows Script Host (VBScript)**, présente nativement de
Windows 2000 à Server 2025 :

- `windows/check_oracle_licensing.vbs`
- `windows/oracle_licensing_collector.vbs`
- `windows/install.cmd` (installateur batch, sans PowerShell)

C'est la **variante par défaut** dans `nsclient-oracle-licensing.ini`.

Elle a un second avantage, valable sur tout le parc : PowerShell exige
souvent un `-ExecutionPolicy Bypass` que les stratégies de groupe
interdisent, là où `cscript` s'exécute sans aménagement. Et `cscript`
propage directement le code retour de `WScript.Quit`, sans la
construction `echo … | powershell -command -` nécessaire côté PowerShell.

**Réserve à connaître :** Microsoft a annoncé en 2023 la dépréciation de
VBScript. Le langage reste livré jusqu'à Server 2025, puis deviendra une
fonctionnalité à la demande. La variante PowerShell est conservée pour
cette échéance et pour les serveurs où WSH est désactivé par
durcissement ; les deux jeux de commandes sont dans le fichier
NSClient++, l'un actif, l'autre commenté.

Windows Server 2003 reste hors support Microsoft depuis juillet 2015 :
ce dépôt le rend supervisable, il ne le rend pas sûr.

### 3. Trois moteurs implémentent la même logique

Windows n'a ni awk ni shell POSIX. La logique de conformité existe donc
en trois exemplaires :

| Moteur | Fichier | Cible |
|---|---|---|
| awk | `lib/licensing_eval.awk` | RHEL 5 → 9 |
| VBScript | `windows/check_oracle_licensing.vbs` | Windows 2003 → 2025 |
| PowerShell | `windows/check_oracle_licensing.ps1` | Windows 2008 R2 → 2025 |

Trois implémentations d'une même règle divergent toujours à terme, et
une divergence signifierait que deux serveurs rendent des verdicts
différents sur des données identiques — ce qui ruine la crédibilité d'un
contrôle de licence.

La parade est `tests/run_parity_tests.sh` : 26 cas comparent le code
retour et la ligne de statut des **trois** moteurs sur des caches
identiques. **Toute modification de la logique doit passer ce test.**

Le test a été validé par injection : une divergence volontaire introduite
dans le moteur VBScript est bien détectée et rapportée.

---

## Windows sans PowerShell : options examinées

| Option | Verdict |
|---|---|
| **VBScript / Windows Script Host** | **retenu** — natif de Windows 2000 à Server 2025, aucune installation, aucun binaire à faire approuver, pas d'`ExecutionPolicy` à contourner |
| Batch pur (`.cmd`) | écarté — incapable de porter le matching par expression régulière et l'agrégation par option |
| awk embarqué (busybox-w32, gawk GnuWin32) | écarté — réutiliserait le moteur Linux *à l'identique*, donc zéro duplication, mais impose de faire approuver un binaire tiers (antivirus, liste blanche applicative), souvent bloquant en entreprise |
| Binaire compilé (Go) | écarté — Go ne cible plus Windows 2003 depuis la version 1.11 (Vista minimum) |
| JScript (WSH) | écarté — équivalent techniquement à VBScript, mais moins courant en exploitation Windows |

L'option awk embarqué reste la plus séduisante sur le plan technique :
elle supprimerait la duplication de logique et donc le besoin même du
test de parité. Elle redevient pertinente si votre politique interne
autorise la distribution d'un exécutable tiers signé.

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
| 2003 / 2003 R2 | aucun | **supporté via VBScript** ; hors support Microsoft depuis 2015 |
| 2008 | 1.0 | supporté via VBScript ; PowerShell 2.0 possible via WMF 2.0 |
| 2008 R2 | 2.0 | supporté par les deux moteurs |
| 2012 / 2012 R2 | 3.0 / 4.0 | supporté par les deux moteurs |
| 2016 | 5.1 | supporté par les deux moteurs |
| 2019 / 2022 | 5.1 | supporté par les deux moteurs |
| 2025 | 5.1 | supporté ; VBScript encore livré, appelé à devenir une fonctionnalité à la demande |

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
| Moteur VBScript | exécuté sous **cscript** (wine), les cinq modes |
| Parité des trois moteurs | 26 cas comparés, codes retour et ligne de statut, détection de divergence vérifiée par injection |

**Ce qui n'a pas pu être vérifié par exécution**, et doit l'être en
recette avant déploiement :

- Le chemin **WMI** du collecteur Windows (`Win32_Processor`,
  `Win32_Service`, registre `HKLM\SOFTWARE\ORACLE`) : ni WMI ni le
  registre n'existent hors de Windows.
- Le comportement réel sous **PowerShell 2.0** : seule la 7.4 était
  disponible. Le code évite les constructions postérieures à la 2.0,
  mais cela reste une revue, pas un test.
- Le chemin **WMI et registre** du collecteur VBScript
  (`Win32_Processor`, `StdRegProv`, `Win32_Service`) : wine exécute le
  langage, pas ces fournisseurs. Le moteur d'évaluation VBScript, lui,
  est bien exécuté de bout en bout.
- Le comportement sous le **WSH réel** de Windows : wine n'implémente
  qu'un sous-ensemble. Le code a été écrit pour ne dépendre que du
  sous-ensemble commun — `Join` et `DateDiff` sont volontairement évités
  au profit de constructions équivalentes — ce qui élargit la couverture
  du test plutôt que de la restreindre.
- Le **SQL** contre de vraies instances 9i, 10g, 11g, 12c et 19c :
  aucune base Oracle n'était disponible. La logique de dégradation par
  version est écrite et relue, non exécutée.

Ces trois points sont les premiers à couvrir en recette.
