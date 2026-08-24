-- =====================================================================
-- collect_licensing.sql
-- Extraction des donnees de conformite de licence Oracle Database.
--
-- Compatible Oracle 9.2 a 19c (et au-dela).
--
-- Sortie : lignes structurees "TYPE|champ|champ|..." consommees par
--          le collecteur (aucune dependance a jq).
--
-- POURQUOI DU PL/SQL DYNAMIQUE PLUTOT QUE DU SQL DIRECT
--
-- Les vues disponibles varient fortement selon la version :
--   9.2  : ni DBA_FEATURE_USAGE_STATISTICS, ni V$OSSTAT, ni
--          DBA_HIGH_WATER_MARK_STATISTICS, ni V$DATABASE.PLATFORM_NAME
--   10.1 : les trois premieres apparaissent ; V$OSSTAT sans les
--          colonnes de coeurs et de sockets
--   11.1 : V$OSSTAT.NUM_CPU_CORES / NUM_CPU_SOCKETS,
--          V$LICENSE.CPU_CORE_COUNT_HIGHWATER
--   12.1 : V$DATABASE.CDB et V$PDBS (multitenant)
--
-- Une requete statique referencant une vue absente echoue a l'analyse
-- syntaxique et interrompt tout le script. Le SQL dynamique deplace
-- cette resolution a l'execution, ce qui permet d'encadrer chaque bloc
-- par son propre gestionnaire d'exception : une section indisponible
-- est simplement omise, le reste du rapport est produit.
--
-- Lecture seule stricte. Aucune ecriture, aucun DDL.
-- Requiert SELECT_CATALOG_ROLE ou SYSDBA (les roles restent actifs dans
-- un bloc anonyme, qui s'execute en droits de l'appelant).
-- =====================================================================

SET SERVEROUTPUT ON SIZE 1000000 FORMAT WRAPPED
SET LINESIZE   32767
SET PAGESIZE   0
SET FEEDBACK   OFF
SET HEADING    OFF
SET VERIFY     OFF
SET ECHO       OFF
SET TERMOUT    ON
SET TRIMSPOOL  ON
SET DEFINE     OFF
-- Indispensable sur les SQL*Plus anciens : sans cela une ligne vide a
-- l'interieur du bloc PL/SQL peut etre prise pour une fin de commande.
SET SQLBLANKLINES ON
WHENEVER SQLERROR EXIT 3
WHENEVER OSERROR  EXIT 3

DECLARE
    -- 9i plafonne DBMS_OUTPUT.PUT_LINE a 255 octets. On s'y tient sur
    -- toutes les versions : aucun enregistrement legitime n'approche
    -- cette taille, et cela evite un comportement different selon la
    -- version sur les noms de features les plus longs.
    c_maxline  CONSTANT PLS_INTEGER := 255;

    -- Schemas livres par Oracle. Les objets qu'ils contiennent
    -- appartiennent au produit, pas a l'applicatif : les compter
    -- ferait apparaitre une option payante sur toute base neuve.
    -- MDSYS notamment EST le schema de Spatial.
    c_sys CONSTANT VARCHAR2(2000) :=
        '''SYS'',''SYSTEM'',''OUTLN'',''DBSNMP'',''WMSYS'',''ORDSYS'',' ||
        '''ORDPLUGINS'',''ORDDATA'',''MDSYS'',''CTXSYS'',''XDB'',''ANONYMOUS'',' ||
        '''OLAPSYS'',''ODM'',''ODM_MTR'',''DMSYS'',''SYSMAN'',''EXFSYS'',' ||
        '''TSMSYS'',''LBACSYS'',''PERFSTAT'',''SI_INFORMTN_SCHEMA'',''MDDATA'',' ||
        '''SPATIAL_CSW_ADMIN_USR'',''SPATIAL_WFS_ADMIN_USR'',''OWBSYS'',' ||
        '''APPQOSSYS'',''AUDSYS'',''GSMADMIN_INTERNAL'',''OJVMSYS'',''DVSYS'',' ||
        '''DVF'',''GGSYS'',''REMOTE_SCHEDULER_AGENT'',''SYSBACKUP'',''SYSDG'',' ||
        '''SYSKM'',''SYSRAC'',''SYS$UMF'',''DBSFWUSER'',''XS$NULL'',''FLOWS_FILES''';

    v_major    PLS_INTEGER;
    v_version  VARCHAR2(64);
    v_count    PLS_INTEGER;
    v_val      VARCHAR2(4000);

    TYPE t_cur IS REF CURSOR;

    -- ----------------------------------------------------------------
    -- Emission
    -- ----------------------------------------------------------------
    PROCEDURE emit(p_line IN VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(SUBSTR(p_line, 1, c_maxline));
    END emit;

    PROCEDURE kv(p_key IN VARCHAR2, p_val IN VARCHAR2) IS
    BEGIN
        -- Le separateur ne doit jamais apparaitre dans une valeur, sous
        -- peine de decaler tous les champs a la lecture.
        emit('KV|' || p_key || '|' || REPLACE(NVL(p_val, '-'), '|', '/'));
    END kv;

    -- Compte des objets et publie le resultat sous forme de preuve
    -- structurelle. Une vue absente laisse simplement la cle non emise :
    -- c'est le cas normal des options non installees.
    PROCEDURE obj_dyn(p_key IN VARCHAR2, p_sql IN VARCHAR2) IS
        l_n NUMBER;
    BEGIN
        EXECUTE IMMEDIATE p_sql INTO l_n;
        emit('OBJ|' || p_key || '|' || TO_CHAR(NVL(l_n, 0)));
    EXCEPTION
        WHEN OTHERS THEN NULL;
    END obj_dyn;

    -- Execute un SELECT scalaire et publie le resultat. Une vue ou une
    -- colonne absente laisse simplement la cle non emise.
    PROCEDURE kv_dyn(p_key IN VARCHAR2, p_sql IN VARCHAR2) IS
        l_val VARCHAR2(4000);
    BEGIN
        EXECUTE IMMEDIATE p_sql INTO l_val;
        kv(p_key, l_val);
    EXCEPTION
        WHEN OTHERS THEN NULL;
    END kv_dyn;

BEGIN
    -- ----------------------------------------------------------------
    -- Version : elle commande tout le reste du script.
    -- ----------------------------------------------------------------
    BEGIN
        EXECUTE IMMEDIATE 'SELECT version FROM v$instance' INTO v_version;
        v_major := TO_NUMBER(SUBSTR(v_version, 1, INSTR(v_version, '.') - 1));
    EXCEPTION
        WHEN OTHERS THEN
            v_version := 'unknown';
            v_major   := 0;
    END;
    kv('inst.version',   v_version);
    kv('db.version_major', TO_CHAR(v_major));

    -- Capacites reellement disponibles sur cette version. Le plugin s'en
    -- sert pour ne pas afficher un vert rassurant la ou le controle
    -- d'usage est simplement impossible.
    kv('collect.cap.feature_usage', CASE WHEN v_major >= 10 THEN '1' ELSE '0' END);
    kv('collect.cap.hwm',           CASE WHEN v_major >= 10 THEN '1' ELSE '0' END);
    kv('collect.cap.osstat_cores',  CASE WHEN v_major >= 11 THEN '1' ELSE '0' END);
    kv('collect.cap.multitenant',   CASE WHEN v_major >= 12 THEN '1' ELSE '0' END);

    -- ----------------------------------------------------------------
    -- Identite de la base
    -- ----------------------------------------------------------------
    kv_dyn('db.name',        'SELECT name            FROM v$database');
    kv_dyn('db.unique_name', 'SELECT db_unique_name  FROM v$database');
    kv_dyn('db.dbid',        'SELECT TO_CHAR(dbid)   FROM v$database');
    kv_dyn('db.role',        'SELECT database_role   FROM v$database');
    kv_dyn('db.open_mode',   'SELECT open_mode       FROM v$database');
    kv_dyn('db.log_mode',    'SELECT log_mode        FROM v$database');
    kv_dyn('db.created',     'SELECT TO_CHAR(created,''YYYY-MM-DD'') FROM v$database');
    -- PLATFORM_NAME n'existe qu'a partir de 10.1.
    kv_dyn('db.platform',    'SELECT platform_name   FROM v$database');

    kv_dyn('inst.name',    'SELECT instance_name FROM v$instance');
    kv_dyn('inst.host',    'SELECT host_name     FROM v$instance');
    kv_dyn('inst.status',  'SELECT status        FROM v$instance');
    kv_dyn('inst.startup', 'SELECT TO_CHAR(startup_time,''YYYY-MM-DD HH24:MI:SS'') FROM v$instance');

    -- Plus d'une instance active implique Real Application Clusters.
    kv_dyn('db.rac_instances', 'SELECT TO_CHAR(COUNT(*)) FROM gv$instance');

    -- Edition. La banniere 9i est "Oracle9i Enterprise Edition ...",
    -- celle des versions modernes "Oracle Database 19c Enterprise
    -- Edition ...". Le filtre doit couvrir les deux formes.
    kv_dyn('db.edition',
        'SELECT CASE ' ||
        '  WHEN banner LIKE ''%Enterprise Edition%''   THEN ''EE''  ' ||
        '  WHEN banner LIKE ''%Express Edition%''      THEN ''XE''  ' ||
        '  WHEN banner LIKE ''%Personal Edition%''     THEN ''PE''  ' ||
        '  WHEN banner LIKE ''%Standard Edition 2%''   THEN ''SE2'' ' ||
        '  WHEN banner LIKE ''%Standard Edition One%'' THEN ''SE1'' ' ||
        '  WHEN banner LIKE ''%Standard Edition%''     THEN ''SE''  ' ||
        '  ELSE ''UNKNOWN'' END ' ||
        'FROM (SELECT banner FROM v$version WHERE banner LIKE ''Oracle%'' AND ROWNUM = 1)');

    -- ----------------------------------------------------------------
    -- Multitenant (12.1+)
    -- ----------------------------------------------------------------
    IF v_major >= 12 THEN
        kv_dyn('db.cdb',       'SELECT cdb FROM v$database');
        kv_dyn('db.pdb_count', 'SELECT TO_CHAR(COUNT(*)) FROM v$pdbs WHERE name <> ''PDB$SEED''');
    ELSE
        kv('db.cdb',       'NO');
        kv('db.pdb_count', '0');
    END IF;

    -- ----------------------------------------------------------------
    -- Ressources CPU vues par l'instance (V$OSSTAT : 10.1+)
    --
    -- Ces valeurs refletent le guest, pas l'hyperviseur : le collecteur
    -- les recoupe avec l'inventaire OS, qui fait foi pour le calcul des
    -- licences Processor.
    -- ----------------------------------------------------------------
    IF v_major >= 10 THEN
        BEGIN
            FOR r IN (SELECT stat_name, value FROM v$osstat
                       WHERE stat_name IN ('NUM_CPUS', 'NUM_CPU_CORES',
                                           'NUM_CPU_SOCKETS', 'PHYSICAL_MEMORY_BYTES'))
            LOOP
                kv('cpu.' || LOWER(r.stat_name), TO_CHAR(r.value));
            END LOOP;
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;
    END IF;
    kv_dyn('param.cpu_count', 'SELECT value FROM v$parameter WHERE name = ''cpu_count''');

    -- ----------------------------------------------------------------
    -- V$LICENSE
    -- Les colonnes de coeurs et de sockets n'existent qu'a partir de 11.1.
    -- ----------------------------------------------------------------
    kv_dyn('license.sessions_max',       'SELECT TO_CHAR(sessions_max)       FROM v$license');
    kv_dyn('license.sessions_warning',   'SELECT TO_CHAR(sessions_warning)   FROM v$license');
    kv_dyn('license.sessions_current',   'SELECT TO_CHAR(sessions_current)   FROM v$license');
    kv_dyn('license.sessions_highwater', 'SELECT TO_CHAR(sessions_highwater) FROM v$license');
    kv_dyn('license.users_max',          'SELECT TO_CHAR(users_max)          FROM v$license');
    IF v_major >= 11 THEN
        kv_dyn('license.cpu_core_highwater',
               'SELECT TO_CHAR(NVL(cpu_core_count_highwater,0))   FROM v$license');
        kv_dyn('license.cpu_socket_highwater',
               'SELECT TO_CHAR(NVL(cpu_socket_count_highwater,0)) FROM v$license');
    END IF;

    -- ----------------------------------------------------------------
    -- V$OPTION : options liees au binaire, presente depuis 8i.
    -- Reflete l'etat de "chopt" : une option a FALSE ne peut pas etre
    -- utilisee, donc ne presente aucun risque de licence.
    -- ----------------------------------------------------------------
    BEGIN
        FOR r IN (SELECT parameter, value FROM v$option ORDER BY parameter) LOOP
            emit('OPT|' || REPLACE(r.parameter, '|', '/') || '|' || r.value);
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN NULL;
    END;

    -- ----------------------------------------------------------------
    -- Usage des features : le coeur du controle de conformite.
    --
    -- DBA_FEATURE_USAGE_STATISTICS n'existe qu'a partir de 10.1. Sur 9i
    -- il n'existe AUCUNE source d'usage des options : le controle de
    -- derive y est structurellement impossible, et le plugin doit le
    -- dire plutot que de conclure a la conformite.
    --
    -- L'agregation porte sur toutes les versions du DBID courant : une
    -- option utilisee avant une montee de version reste un usage a
    -- justifier. MAX() sur CURRENTLY_USED fonctionne car 'TRUE' > 'FALSE'.
    -- ----------------------------------------------------------------
    IF v_major >= 10 THEN
        DECLARE
            l_cur   t_cur;
            l_name  VARCHAR2(128);
            l_used  VARCHAR2(10);
            l_det   NUMBER;
            l_last  VARCHAR2(10);
            l_first VARCHAR2(10);
            l_aux   NUMBER;
        BEGIN
            OPEN l_cur FOR
                'SELECT name, currently_used, detected_usages, last_usage_date,
                        first_usage_date, aux_count
                   FROM ( SELECT f.name                  AS name,
                                 MAX(f.currently_used)   AS currently_used,
                                 SUM(f.detected_usages)  AS detected_usages,
                                 TO_CHAR(MAX(f.last_usage_date),''YYYY-MM-DD'')  AS last_usage_date,
                                 TO_CHAR(MIN(f.first_usage_date),''YYYY-MM-DD'') AS first_usage_date,
                                 MAX(f.aux_count)        AS aux_count
                            FROM dba_feature_usage_statistics f
                           WHERE f.dbid = (SELECT dbid FROM v$database)
                           GROUP BY f.name )
                  WHERE detected_usages > 0
                  ORDER BY name';
            LOOP
                FETCH l_cur INTO l_name, l_used, l_det, l_last, l_first, l_aux;
                EXIT WHEN l_cur%NOTFOUND;
                emit('FEAT|' || REPLACE(l_name, '|', '/')
                     || '|' || l_used
                     || '|' || TO_CHAR(l_det)
                     || '|' || NVL(l_last,  '-')
                     || '|' || NVL(l_first, '-')
                     || '|' || TO_CHAR(NVL(l_aux, 0)));
            END LOOP;
            CLOSE l_cur;
        EXCEPTION
            WHEN OTHERS THEN
                -- Base en MOUNT, ou droits insuffisants : le rapport
                -- reste exploitable pour l'identite et V$OPTION.
                kv('collect.feature_usage_error', SUBSTR(SQLERRM, 1, 120));
        END;
    END IF;

    -- ----------------------------------------------------------------
    -- High-water marks (10.1+). Sert au dimensionnement NUP et a la
    -- detection des depassements de limites d'edition.
    -- ----------------------------------------------------------------
    IF v_major >= 10 THEN
        DECLARE
            l_cur  t_cur;
            l_name VARCHAR2(128);
            l_hw   NUMBER;
            l_last NUMBER;
        BEGIN
            OPEN l_cur FOR
                'SELECT name, highwater, NVL(last_value,0)
                   FROM dba_high_water_mark_statistics
                  WHERE dbid = (SELECT dbid FROM v$database)
                    AND name IN (''SESSIONS'',''CPU_COUNT'',''USER_TABLES'',
                                 ''SEGMENT_SIZE'',''DATAFILES'',''TABLESPACES'',
                                 ''SERVICES'',''DB_SIZE'')
                  ORDER BY name';
            LOOP
                FETCH l_cur INTO l_name, l_hw, l_last;
                EXIT WHEN l_cur%NOTFOUND;
                emit('HWM|' || l_name || '|' || TO_CHAR(l_hw) || '|' || TO_CHAR(l_last));
            END LOOP;
            CLOSE l_cur;
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;
    END IF;

    -- ----------------------------------------------------------------
    -- Preuves structurelles d'usage des options
    --
    -- Interrogation directe du dictionnaire, disponible depuis 8i. Deux
    -- raisons d'en passer par la :
    --
    --   1. Sur Oracle 9i, DBA_FEATURE_USAGE_STATISTICS n'existe pas :
    --      c'est la seule source d'usage exploitable.
    --   2. Sur toutes les versions, c'est une preuve plus forte que
    --      l'echantillonnage MMON, qui peut manquer un usage survenu
    --      entre deux instantanes. Une table partitionnee existe ou
    --      n'existe pas.
    --
    -- On ne retient que l'incontestable : un objet dont l'existence
    -- meme suppose l'option. La compression de table en est exclue a
    -- dessein -- BASIC est incluse, OLTP est payante, et la distinction
    -- n'est lisible qu'a partir de 11g.
    -- ----------------------------------------------------------------
    obj_dyn('part_tables',
        'SELECT COUNT(*) FROM dba_part_tables WHERE owner NOT IN (' || c_sys || ')');
    obj_dyn('part_indexes',
        'SELECT COUNT(*) FROM dba_part_indexes WHERE owner NOT IN (' || c_sys || ')');

    -- Spatial : une colonne SDO_GEOMETRY dans un schema applicatif.
    -- MDSYS est exclu, c'est le schema de l'option elle-meme.
    obj_dyn('sdo_columns',
        'SELECT COUNT(*) FROM dba_tab_columns WHERE data_type = ''SDO_GEOMETRY''' ||
        ' AND owner NOT IN (' || c_sys || ')');

    -- OLAP : espaces de travail analytiques.
    obj_dyn('olap_aws',
        'SELECT COUNT(*) FROM dba_aws WHERE owner NOT IN (' || c_sys || ')');

    -- Label Security : une politique definie suppose l'option installee
    -- et utilisee.
    obj_dyn('ols_policies', 'SELECT COUNT(*) FROM dba_sa_policies');

    -- Advanced Analytics : modeles de fouille de donnees (10g et suivants).
    obj_dyn('mining_models',
        'SELECT COUNT(*) FROM dba_mining_models WHERE owner NOT IN (' || c_sys || ')');

    -- Database Vault : realms definis (10.2 et suivants).
    obj_dyn('dv_realms', 'SELECT COUNT(*) FROM dba_dv_realm');

    -- Advanced Security : colonnes chiffrees (TDE, 10.2 et suivants).
    obj_dyn('encrypted_columns',
        'SELECT COUNT(*) FROM dba_encrypted_columns WHERE owner NOT IN (' || c_sys || ')');
    obj_dyn('encrypted_tablespaces',
        'SELECT COUNT(*) FROM v$encrypted_tablespaces');

    -- Real Application Clusters : plus d'une instance ouverte sur la
    -- meme base. Emis en preuve structurelle, comme les autres, pour que
    -- le moteur n'ait qu'un seul mecanisme a appliquer.
    obj_dyn('rac_instances', 'SELECT COUNT(*) FROM gv$instance');

    -- Sentinelle : son absence signale un rapport tronque.
    kv('collect.sql_complete', '1');
END;
/

EXIT 0
