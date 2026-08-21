-- =====================================================================
-- collect_licensing.sql
-- Extraction des donnees de conformite de licence Oracle Database.
--
-- Sortie : lignes structurees "TYPE|champ|champ|..." consommees par
--          bin/oracle_licensing_collector.sh (aucune dependance a jq).
--
-- Lecture seule stricte. Aucune ecriture, aucun DDL.
-- Requiert : SELECT_CATALOG_ROLE (ou SYSDBA).
--
-- ATTENTION : interroger DBA_FEATURE_USAGE_STATISTICS n'est PAS neutre du
-- point de vue Oracle LMS, mais la vue est alimentee par MMON (snapshot
-- hebdomadaire) : la lire ne declenche aucun usage de feature payante.
-- =====================================================================

SET LINESIZE   32767
SET PAGESIZE   0
SET FEEDBACK   OFF
SET HEADING    OFF
SET VERIFY     OFF
SET ECHO       OFF
SET TERMOUT    ON
SET TRIMSPOOL  ON
SET TRIMOUT    ON
SET NEWPAGE    NONE
SET SERVEROUTPUT OFF
SET NUMWIDTH   38
SET COLSEP     ''
WHENEVER SQLERROR EXIT 3
WHENEVER OSERROR  EXIT 3

ALTER SESSION SET NLS_DATE_FORMAT = 'YYYY-MM-DD';
ALTER SESSION SET NLS_NUMERIC_CHARACTERS = '.,';

-- ---------------------------------------------------------------------
-- 1. Identite de la base
-- ---------------------------------------------------------------------
SELECT 'KV|db.name|'         || d.name          FROM v$database d;
SELECT 'KV|db.unique_name|'  || d.db_unique_name FROM v$database d;
SELECT 'KV|db.dbid|'         || d.dbid          FROM v$database d;
SELECT 'KV|db.role|'         || d.database_role FROM v$database d;
SELECT 'KV|db.open_mode|'    || d.open_mode     FROM v$database d;
SELECT 'KV|db.log_mode|'     || d.log_mode      FROM v$database d;
SELECT 'KV|db.created|'      || TO_CHAR(d.created,'YYYY-MM-DD') FROM v$database d;
SELECT 'KV|db.platform|'     || d.platform_name FROM v$database d;

SELECT 'KV|inst.name|'       || i.instance_name FROM v$instance i;
SELECT 'KV|inst.host|'       || i.host_name     FROM v$instance i;
SELECT 'KV|inst.version|'    || i.version       FROM v$instance i;
SELECT 'KV|inst.status|'     || i.status        FROM v$instance i;
SELECT 'KV|inst.startup|'    || TO_CHAR(i.startup_time,'YYYY-MM-DD HH24:MI:SS') FROM v$instance i;

-- Nombre d'instances actives : > 1 implique Real Application Clusters.
SELECT 'KV|db.rac_instances|' || TO_CHAR(COUNT(*)) FROM gv$instance;

-- Edition : determinante, la plupart des options ne sont vendables qu'en EE.
SELECT 'KV|db.edition|' ||
       CASE WHEN banner LIKE '%Enterprise Edition%' THEN 'EE'
            WHEN banner LIKE '%Express Edition%'    THEN 'XE'
            WHEN banner LIKE '%Personal Edition%'   THEN 'PE'
            WHEN banner LIKE '%Standard Edition 2%' THEN 'SE2'
            WHEN banner LIKE '%Standard Edition%'   THEN 'SE'
            ELSE 'UNKNOWN' END
  FROM (SELECT banner FROM v$version WHERE banner LIKE 'Oracle Database%' AND ROWNUM = 1);

-- Multitenant : un CDB avec 2+ PDB utilisateur declenche l'option Multitenant
-- (1 seule PDB = "single-tenant", inclus en EE depuis 19c).
-- Colonne CDB absente avant 12.1 : l'echec est tolere et vaut "NO".
WHENEVER SQLERROR CONTINUE NONE
SELECT 'KV|db.cdb|' || NVL(MAX(cdb),'NO') FROM v$database;
WHENEVER SQLERROR EXIT 3

-- ---------------------------------------------------------------------
-- 2. Ressources CPU vues par l'instance
--    NUM_CPU_CORES / NUM_CPU_SOCKETS sont la base du calcul Processor.
--    Sur VM ces valeurs refletent le guest, pas l'hyperviseur : le
--    collecteur les recoupe avec lscpu/dmidecode cote OS.
-- ---------------------------------------------------------------------
SELECT 'KV|cpu.' || LOWER(stat_name) || '|' || TO_CHAR(value)
  FROM v$osstat
 WHERE stat_name IN ('NUM_CPUS','NUM_CPU_CORES','NUM_CPU_SOCKETS','PHYSICAL_MEMORY_BYTES');

SELECT 'KV|param.cpu_count|' || value FROM v$parameter WHERE name = 'cpu_count';

-- ---------------------------------------------------------------------
-- 3. V$LICENSE : plafonds de sessions et high-water marks CPU
-- ---------------------------------------------------------------------
SELECT 'KV|license.sessions_max|'        || TO_CHAR(sessions_max)        FROM v$license;
SELECT 'KV|license.sessions_warning|'    || TO_CHAR(sessions_warning)    FROM v$license;
SELECT 'KV|license.sessions_current|'    || TO_CHAR(sessions_current)    FROM v$license;
SELECT 'KV|license.sessions_highwater|'  || TO_CHAR(sessions_highwater)  FROM v$license;
SELECT 'KV|license.users_max|'           || TO_CHAR(users_max)           FROM v$license;
SELECT 'KV|license.cpu_core_highwater|'  || TO_CHAR(NVL(cpu_core_count_highwater,0))   FROM v$license;
SELECT 'KV|license.cpu_socket_highwater|'|| TO_CHAR(NVL(cpu_socket_count_highwater,0)) FROM v$license;

-- ---------------------------------------------------------------------
-- 4. V$OPTION : options liees au binaire.
--    Refletent l'etat de "chopt" : une option a FALSE ne peut pas etre
--    utilisee, donc pas de risque de licence, quoi que dise l'inventaire.
-- ---------------------------------------------------------------------
SELECT 'OPT|' || parameter || '|' || value
  FROM v$option
 ORDER BY parameter;

-- A partir d'ici les vues DBA_* exigent une base OPEN et, pour V$PDBS,
-- une version >= 12.1. Une base en MOUNT (standby non ouverte) doit
-- produire un rapport partiel plutot qu'aucun rapport : le plugin
-- distingue les deux via l'absence d'enregistrements FEAT.
WHENEVER SQLERROR CONTINUE NONE

-- ---------------------------------------------------------------------
-- 5. Usage des features -- le coeur du controle de conformite.
--    Agrege toutes versions confondues pour le DBID courant :
--    une option utilisee avant un upgrade reste un usage a justifier.
--    MAX() sur currently_used fonctionne : 'TRUE' > 'FALSE'.
-- ---------------------------------------------------------------------
SELECT 'FEAT|' || name
       || '|' || currently_used
       || '|' || TO_CHAR(detected_usages)
       || '|' || NVL(TO_CHAR(last_usage_date,'YYYY-MM-DD'),'-')
       || '|' || NVL(TO_CHAR(first_usage_date,'YYYY-MM-DD'),'-')
       || '|' || TO_CHAR(NVL(aux_count,0))
  FROM ( SELECT f.name                     AS name,
                MAX(f.currently_used)      AS currently_used,
                SUM(f.detected_usages)     AS detected_usages,
                MAX(f.last_usage_date)     AS last_usage_date,
                MIN(f.first_usage_date)    AS first_usage_date,
                MAX(f.aux_count)           AS aux_count
           FROM dba_feature_usage_statistics f
          WHERE f.dbid = (SELECT dbid FROM v$database)
          GROUP BY f.name )
 WHERE detected_usages > 0
 ORDER BY name;

-- ---------------------------------------------------------------------
-- 6. High-water marks : sert au dimensionnement NUP et a la detection
--    de depassement de limites d'edition (SE2 : 16 threads CPU max).
-- ---------------------------------------------------------------------
SELECT 'HWM|' || name || '|' || TO_CHAR(highwater) || '|' || TO_CHAR(NVL(last_value,0))
  FROM dba_high_water_mark_statistics
 WHERE dbid = (SELECT dbid FROM v$database)
   AND name IN ('SESSIONS','CPU_COUNT','USER_TABLES','SEGMENT_SIZE',
                'DATAFILES','TABLESPACES','SERVICES','DB_SIZE')
 ORDER BY name;

-- ---------------------------------------------------------------------
-- 7. Comptage des PDB utilisateur (option Multitenant au-dela de 1 PDB
--    en 19c, au-dela de 3 en 21c+). PDB$SEED exclu.
-- ---------------------------------------------------------------------
SELECT 'KV|db.pdb_count|' || TO_CHAR(COUNT(*))
  FROM v$pdbs
 WHERE name <> 'PDB$SEED';

SELECT 'KV|collect.sql_complete|1' FROM dual;

EXIT 0
