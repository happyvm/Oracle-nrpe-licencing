# Matrice de compatibilité

Périmètre visé : Windows Server 2003 → 2025, RHEL 5 → 9, Oracle 9i → 19c.

Ce document dit ce qui fonctionne, ce qui fonctionne en mode dégradé, et
ce qui ne peut pas fonctionner — cette dernière catégorie n'étant pas
vide, elle est énoncée en premier.

---

## Trois points structurants

### 1. Oracle 9i : contrôle partiel, par preuves structurelles

`DBA_FEATURE_USAGE_STATISTICS` n'existe **qu'à partir d'Oracle 10.1**.
Le relevé d'usage échantillonné par MMON n'est donc pas disponible.

Mais le **dictionnaire de données, lui, existe depuis 8i**. L'usage des
options *structurelles* s'y prouve directement, et de façon plus solide
qu'un relevé : une table partitionnée existe ou n'existe pas, là où
l'échantillonnage MMON peut manquer un usage survenu entre deux
instantanés.

| Contrôle | 9i | Source |
|---|---|---|
| Licences Processor | oui | inventaire OS, indépendant de la base |
| Sessions, high-water mark | oui | `V$LICENSE`, depuis 8i |
| Options liées au binaire | oui | `V$OPTION`, depuis 8i |
| **Partitioning** | **oui** | `DBA_PART_TABLES`, `DBA_PART_INDEXES` |
| **Spatial** | **oui** | colonnes `SDO_GEOMETRY` hors MDSYS |
| **OLAP** | **oui** | espaces de travail analytiques |
| **Label Security** | **oui** | `DBA_SA_POLICIES` |
| **RAC** | **oui** | `GV$INSTANCE` > 1 |
| Management packs Diagnostics / Tuning | non | passaient par EM Grid Control, rien en base |
| Usages sans objet persistant | non | compression RMAN, Data Guard, Data Pump |

Le mode `options` rend donc un **verdict réel** sur 9i, assorti de la
mention `[couverture partielle: analyse structurelle seule, relevé
d'usage absent avant Oracle 10.1]`. La sortie longue rappelle ce qui
n'est pas couvert.

**Conséquence pratique :** déclarez `Oracle-Lic-Options` aussi sur les
bases 9i. Il détecte le risque principal — Partitioning en tête, de loin
la première cause de redressement — sans prétendre à l'exhaustivité.

Ces mêmes preuves structurelles s'appliquent à **toutes** les versions,
en recoupement du relevé d'usage : `etc/structural-evidence.map`.

### 2. Windows Server 2003 : couvert par VBScript, et par lui seul

Windows Server 2003 est livré sans PowerShell. Plutôt que d'imposer
l'installation de WMF 2.0 sur un parc existant, le dépôt fournit une
implémentation **Windows Script Host (VBScript)** :

- `windows/check_oracle_licensing.vbs`
- `windows/oracle_licensing_collector.vbs`
- `windows/install.cmd` (installateur batch, sans PowerShell)
- `windows/nsclient-oracle-licensing-vbs.ini`

**PowerShell reste la voie principale.** VBScript ne sert que là où
PowerShell manque : Windows Server 2003, Windows Server 2008 resté en
PowerShell 1.0, et les serveurs où une stratégie de groupe interdit
l'exécution de scripts PowerShell.

Ce n'est pas qu'une consigne de documentation : `install.cmd` **détecte
PowerShell et refuse de s'exécuter** s'il en trouve une version 2.0 ou
supérieure, en renvoyant vers `install.ps1`. Microsoft a annoncé en 2023
la dépréciation de VBScript — livré jusqu'à Server 2025, puis
fonctionnalité à la demande — et lier un serveur moderne à un langage en
fin de vie serait une dette gratuite. `/Force` outrepasse le garde-fou
pour le cas des GPO restrictives.

Les deux variantes ont chacune leur fichier NSClient++, sans bloc
commenté à basculer : on copie celui qui correspond au serveur, et
jamais les deux, les noms de commandes étant identiques.

Windows Server 2003 reste hors support Microsoft depuis juillet 2015 :
ce dépôt le rend supervisable, il ne le rend pas sûr.

### 3. Trois moteurs implémentent la même logique

Windows n'a ni awk ni shell POSIX. La logique de conformité existe donc
en trois exemplaires :

| Moteur | Fichier | Cible |
|---|---|---|
| awk | `lib/licensing_eval.awk` | RHEL 5 → 9 |
| PowerShell | `windows/check_oracle_licensing.ps1` | Windows 2008 R2 → 2025 (voie principale) |
| VBScript | `windows/check_oracle_licensing.vbs` | uniquement les Windows sans PowerShell utilisable |

Trois implémentations d'une même règle divergent toujours à terme, et
une divergence signifierait que deux serveurs rendent des verdicts
différents sur des données identiques — ce qui ruine la crédibilité d'un
contrôle de licence.

La parade est `tests/run_parity_tests.sh` : 37 cas comparent le code
retour et la ligne de statut des **trois** moteurs sur des caches
identiques. **Toute modification de la logique doit passer ce test.**

Le test a été validé par injection : une divergence volontaire introduite
dans le moteur VBScript est bien détectée et rapportée.

---

## Windows sans PowerShell : options examinées

| Option | Verdict |
|---|---|
| **VBScript / Windows Script Host** | **retenu pour les seuls serveurs sans PowerShell** — natif de Windows 2000 à Server 2025, aucune installation, aucun binaire à faire approuver, pas d'`ExecutionPolicy` à contourner ; déprécié depuis 2023, donc cantonné aux machines qui n'ont pas le choix |
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

| Version | PowerShell natif | Variante déployée |
|---|---|---|
| 2003 / 2003 R2 | aucun | **VBScript** (seule option) ; hors support Microsoft depuis 2015 |
| 2008 | 1.0 | **VBScript**, ou PowerShell après installation de WMF 2.0 |
| 2008 R2 | 2.0 | **PowerShell** |
| 2012 / 2012 R2 | 3.0 / 4.0 | **PowerShell** |
| 2016 | 5.1 | **PowerShell** |
| 2019 / 2022 / 2025 | 5.1 | **PowerShell** |

VBScript reste utilisable partout, mais `install.cmd` s'y oppose dès que
PowerShell 2.0+ est présent. La seule exception prévue est une stratégie
de groupe interdisant PowerShell, auquel cas `/Force` débloque
l'installation.

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

| Version | Relevé d'usage | HWM | Cœurs `V$OSSTAT` | Packs contrôlables | Multitenant | Statut |
|---|---|---|---|---|---|---|
| 9.2 | non | non | non | non | non | partiel — preuves structurelles seules |
| 10.1 / 10.2 | oui | oui | non | non | non | supporté |
| 11.1 / 11.2 | oui | oui | oui | **oui** | non | supporté |
| 12.1 / 12.2 | oui | oui | oui | oui | oui | supporté |
| 18c | oui | oui | oui | oui | oui | supporté — **règles de 12.2** |
| 19c | oui | oui | oui | oui | oui | supporté |
| 21c | oui | oui | oui | oui | oui | supporté |

### Ce qui distingue 10g de 11g

**`CONTROL_MANAGEMENT_PACK_ACCESS` (11.1+).** Ce paramètre commande
l'accès aux management packs Diagnostics et Tuning. Sa valeur par défaut
en Enterprise Edition est `DIAGNOSTIC+TUNING` : **une base neuve autorise
leur usage même si le client ne les a pas achetés.** Oracle recommande
`NONE` dans ce cas.

Le plugin le contrôle et signale les packs accessibles non déclarés en
**WARNING**, sous la métrique `exposed_packs` — une porte ouverte n'est
pas un usage constaté, et le CRITICAL reste réservé aux usages avérés.
La sortie longue donne la remédiation.

Sur 10g le paramètre n'existe pas : les packs y étaient contrôlés par
Enterprise Manager, sans trace exploitable en base. Seul le relevé
d'usage les révèle.

**Preuves structurelles propres à 11.1+ :**

| Preuve | Option | Pourquoi pas avant 11.1 |
|---|---|---|
| `oltp_compressed_tables` | Advanced Compression | `COMPRESS_FOR` n'existe pas avant : BASIC (incluse) et OLTP (payante) sont indiscernables |
| `hcc_compressed_tables` | Advanced Compression | idem ; incluse sur Exadata, ZFSSA et Pillar — à vérifier à la main |
| `securefile_compressed` / `_deduplicated` | Advanced Compression | SecureFiles apparaît en 11.1 |
| `securefile_encrypted` | Advanced Security | idem |
| `adg_readonly_apply` | Active Data Guard | l'option apparaît en 11.1 |
| `flashback_archives` | Advanced Compression | Total Recall en 11g, inclus depuis 12.1.0.2 |

Sur 9i et 10g, le collecteur n'émet pas ces clés et les règles restent
sans effet : pas de faux positif, mais pas de détection non plus. La
compression payante y est indétectable de façon fiable — c'est une
limite assumée plutôt qu'un constat que l'on ne saurait étayer.

Vues apparues au fil des versions :

| Vue ou colonne | Depuis |
|---|---|
| `V$OPTION`, `V$LICENSE` | 8i |
| `DBA_PART_TABLES`, `DBA_PART_INDEXES` | 8i |
| `DBA_SA_POLICIES` (Label Security) | 8i |
| `DBA_FEATURE_USAGE_STATISTICS` | 10.1 |
| `DBA_MINING_MODELS` | 10.1 |
| `DBA_ENCRYPTED_COLUMNS` (TDE) | 10.2 |
| `DBA_DV_REALM` (Database Vault) | 10.2 |
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

### Ce qui distingue 12c de 19c

**Le seuil Multitenant dépend de la version.** Oracle inclut **une seule
PDB** utilisateur de 12.1 à 18c, et **trois** à partir de 19c. Un seuil
fixe accuserait à tort une 19c à trois PDB.

C'est pour cette raison que Multitenant est traité par le moteur et non
par `licensable-features.map` : un champ fixe ne sait pas exprimer une
règle qui varie avec la version. Le seuil est surchargeable par
`MULTITENANT_INCLUDED_PDBS`.

> Cette limite a déjà évolué et peut encore changer. Vérifiez-la dans le
> *Licensing Information User Manual* de votre version exacte avant de
> vous fier au défaut.

**Preuves structurelles propres à 12.1+ :**

| Preuve | Option |
|---|---|
| `inmemory_tables`, `param.inmemory_size` | Database In-Memory (12.1.0.2+) |
| `redaction_policies` | Advanced Security (Data Redaction) |
| `ilm_policies`, `param.heat_map` | Advanced Compression (ADO) |
| `priv_captures` | Database Vault ; **inclus en EE depuis 19c** |

**Devenu gratuit en cours de route** — le plugin en tient compte par la
version, donc ne signale que là où c'était encore payant :

| Feature | Payante jusqu'à | Incluse depuis |
|---|---|---|
| Spatial | 12.1 | 12.2 (annonce déc. 2019) |
| Advanced Analytics / Data Mining | 12.1 | 12.2 (annonce déc. 2019) |
| Flashback Data Archive (Total Recall) | 12.1.0.1 | 12.1.0.2 |
| Privilege Analysis | 18c | 19c |
| Database In-Memory (≤ 16 Go, Base Level) | 19.7 | 19.8 |
| ASO network encryption | 11.2 | 12.1 |

### 18c n'est pas « presque 19c »

Oracle 18c est techniquement **12.2.0.2 renuméroté**. Ses règles de
licence sont celles de 12.2, pas celles de 19c :

| Règle | 12.2 / 18c | 19c |
|---|---|---|
| PDB incluses | **1** | 3 |
| Privilege Analysis | payant (Database Vault) | **inclus en EE** |

Le numéro 18 induit en erreur : une base 18c à deux PDB requiert
Multitenant, là où la même configuration est incluse en 19c. Le moteur
compare les versions numériquement, donc traite 18c correctement — mais
c'est le genre de détail sur lequel un raisonnement humain se trompe.

### 21c : In-Memory Base Level

Depuis **19.8** et en 21c, Oracle inclut en Enterprise Edition un Column
Store limité à **16 Go**, activé par `INMEMORY_FORCE=BASE_LEVEL`. Au-delà
de cette taille, ou sans ce réglage, l'usage relève de l'option payante.

Une règle fondée sur le seul comptage de tables `INMEMORY` accuserait à
tort toute base utilisant le Base Level — même catégorie d'erreur que le
seuil Multitenant fixe. Le moteur croise donc trois éléments :

```
INMEMORY_FORCE = BASE_LEVEL  ET  INMEMORY_SIZE ≤ 16 Go  ET  version ≥ 19.8
        → inclus, aucun constat
sinon, si le Column Store est actif
        → option Database In-Memory requise
```

Le relevé d'usage remonte `In-Memory Column Store` dès que le Column
Store sert, sans distinguer le Base Level : ce constat est donc
explicitement retiré quand la règle produit s'applique, faute de quoi la
table des features accuserait une base qui n'a rien à licencier.

**Détail d'implémentation qui compte** : `INMEMORY_SIZE` s'exprime en
octets, et 16 Go valent 17 179 869 184 — au-delà d'un entier 32 bits.
`CLng` (VBScript) et `[int]::TryParse` (PowerShell) y échouent en
rendant zéro, silencieusement : une base In-Memory passerait pour
inactive. Les deux moteurs Windows utilisent donc `CDbl` et
`[long]::TryParse` pour cette valeur.

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
| Suites Unix | 85 + 23 tests, rejoués sous chacun des trois shells |
| Analyse statique | `shellcheck -S warning`, sans avertissement |
| Moteur PowerShell | exécuté sous **PowerShell 7.4** |
| Moteur VBScript | exécuté sous **cscript** (wine), les cinq modes |
| Volume total | **361 exécutions de test**, neuf jeux de référence (9i à 21c) |
| Parité des trois moteurs | 37 cas comparés, codes retour et ligne de statut, détection de divergence vérifiée par injection |

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
