whenever oserror exit 3
whenever sqlerror exit 3

set echo off
set heading off
set feedback off
set verify off
set pagesize 0
set linesize 300
set trimspool on
set serveroutput on size 1000000

declare
  type t_rc is ref cursor;
  c               t_rc;

  procedure p(s varchar2) is
  begin
    dbms_output.put_line(substr(replace(replace(s, chr(10), ' '), chr(13), ' '), 1, 300));
  end;

  procedure safe_close is
  begin
    begin
      if c%isopen then
        close c;
      end if;
    exception
      when others then null;
    end;
  end;

  v_instance      varchar2(128);
  v_host          varchar2(128);
  v_version       varchar2(64);
  v_status        varchar2(64);
  v_dbname        varchar2(128);
  v_dbid          varchar2(64);
  v_role          varchar2(64);
  v_open_mode     varchar2(64);
  v_cdb           varchar2(16);
  v_banner        varchar2(300);
  v_edition       varchar2(32);
  v_value         varchar2(256);
  v_count         number;

  f_name          varchar2(128);
  f_count         varchar2(32);
  f_current       varchar2(16);
  f_first         varchar2(32);
  f_last          varchar2(32);

  comp_id         varchar2(64);
  comp_name       varchar2(180);
  comp_version    varchar2(64);
  comp_status     varchar2(32);
begin
  begin
    select instance_name, host_name, version, status
      into v_instance, v_host, v_version, v_status
      from v$instance;

    p('META|INSTANCE|' || v_instance);
    p('META|HOST|' || v_host);
    p('META|VERSION|' || v_version);
    p('META|INSTANCE_STATUS|' || v_status);
  exception
    when others then
      p('ERROR|INSTANCE|' || sqlcode || ' ' || sqlerrm);
  end;

  begin
    execute immediate
      'select name, to_char(dbid), database_role, open_mode from v$database'
      into v_dbname, v_dbid, v_role, v_open_mode;
  exception
    when others then
      begin
        execute immediate
          'select name, to_char(dbid) from v$database'
          into v_dbname, v_dbid;
        v_role := 'UNKNOWN';
        v_open_mode := 'UNKNOWN';
      exception
        when others then
          v_dbname := 'UNKNOWN';
          v_dbid := 'UNKNOWN';
          v_role := 'UNKNOWN';
          v_open_mode := 'UNKNOWN';
      end;
  end;

  p('META|DATABASE|' || v_dbname);
  p('META|DBID|' || v_dbid);
  p('META|DATABASE_ROLE|' || v_role);
  p('META|OPEN_MODE|' || v_open_mode);

  if upper(v_role) = 'PHYSICAL STANDBY' and upper(v_open_mode) = 'READ ONLY WITH APPLY' then
    p('SIGNAL|ACTIVE_DATA_GUARD_LIKE|YES');
  else
    p('SIGNAL|ACTIVE_DATA_GUARD_LIKE|NO');
  end if;

  begin
    execute immediate 'select cdb from v$database' into v_cdb;
  exception
    when others then
      v_cdb := 'NO_OR_PRE12C';
  end;
  p('META|CDB|' || v_cdb);

  begin
    execute immediate 'select count(*) from v$pdbs' into v_count;
    p('SIGNAL|PDB_COUNT|' || to_char(v_count));
  exception
    when others then
      p('SIGNAL|PDB_COUNT|NOT_AVAILABLE');
  end;

  begin
    select banner
      into v_banner
      from v$version
     where banner like 'Oracle%'
       and rownum = 1;
  exception
    when others then
      v_banner := 'UNKNOWN';
  end;

  v_edition := 'UNKNOWN';
  if instr(upper(v_banner), 'ENTERPRISE EDITION') > 0 then
    v_edition := 'EE';
  elsif instr(upper(v_banner), 'STANDARD EDITION 2') > 0 then
    v_edition := 'SE2';
  elsif instr(upper(v_banner), 'STANDARD EDITION ONE') > 0 then
    v_edition := 'SE1';
  elsif instr(upper(v_banner), 'STANDARD EDITION') > 0 then
    v_edition := 'SE';
  elsif instr(upper(v_banner), 'EXPRESS EDITION') > 0 then
    v_edition := 'XE';
  elsif instr(upper(v_banner), 'PERSONAL EDITION') > 0 then
    v_edition := 'PE';
  elsif instr(upper(v_banner), 'DATABASE FREE') > 0
     or instr(upper(v_banner), ' FREE ') > 0 then
    v_edition := 'FREE';
  end if;

  p('META|EDITION|' || v_edition);
  p('META|BANNER|' || replace(v_banner, '|', '/'));

  begin
    select value
      into v_value
      from v$parameter
     where name = 'control_management_pack_access';
    p('PARAM|control_management_pack_access|' || v_value);
  exception
    when no_data_found then
      p('PARAM|control_management_pack_access|NOT_AVAILABLE');
    when others then
      p('PARAM|control_management_pack_access|NOT_AVAILABLE');
  end;

  begin
    select value
      into v_value
      from v$parameter
     where name = 'cluster_database';
    p('SIGNAL|RAC_CONFIGURED|' || v_value);
  exception
    when others then
      p('SIGNAL|RAC_CONFIGURED|NOT_AVAILABLE');
  end;

  begin
    select value
      into v_value
      from v$parameter
     where name = 'inmemory_size';
    p('SIGNAL|INMEMORY_SIZE|' || v_value);
  exception
    when others then
      p('SIGNAL|INMEMORY_SIZE|NOT_AVAILABLE');
  end;

  begin
    execute immediate 'select count(*) from v$encrypted_tablespaces' into v_count;
    p('SIGNAL|TDE_ENCRYPTED_TABLESPACES|' || to_char(v_count));
  exception
    when others then
      p('SIGNAL|TDE_ENCRYPTED_TABLESPACES|NOT_AVAILABLE');
  end;

  begin
    execute immediate 'select status from v$encryption_wallet where rownum = 1' into v_value;
    p('SIGNAL|TDE_WALLET_STATUS|' || replace(v_value, '|', '/'));
  exception
    when others then
      p('SIGNAL|TDE_WALLET_STATUS|NOT_AVAILABLE');
  end;

  begin
    for r in (select parameter, value
                from v$option
               where value = 'TRUE'
               order by parameter)
    loop
      p('OPTION|' || replace(r.parameter, '|', '/') || '|TRUE');
    end loop;
  exception
    when others then
      p('INFO|V_OPTION_UNAVAILABLE|' || sqlcode);
  end;

  /*
   * DBA_FEATURE_USAGE_STATISTICS is used as technical evidence only.
   * It is not a contractual entitlement source and its interpretation is
   * release-dependent. Dynamic SQL keeps this collector usable on older DBs.
   */
  begin
    open c for
      'select replace(name,''|'',''/''), ' ||
      '       to_char(detected_usages), ' ||
      '       nvl(currently_used,''?''), ' ||
      '       nvl(to_char(first_usage_date,''YYYY-MM-DD HH24:MI:SS''),''-''), ' ||
      '       nvl(to_char(last_usage_date,''YYYY-MM-DD HH24:MI:SS''),''-'') ' ||
      '  from dba_feature_usage_statistics ' ||
      ' where detected_usages > 0 ' ||
      ' order by name';

    loop
      fetch c into f_name, f_count, f_current, f_first, f_last;
      exit when c%notfound;
      p('FEATURE|' || f_name || '|' || f_count || '|' || f_current ||
        '|' || f_first || '|' || f_last);
    end loop;
    safe_close;
  exception
    when others then
      safe_close;
      begin
        open c for
          'select replace(name,''|'',''/''), ' ||
          '       to_char(detected_usages) ' ||
          '  from dba_feature_usage_statistics ' ||
          ' where detected_usages > 0 ' ||
          ' order by name';

        loop
          fetch c into f_name, f_count;
          exit when c%notfound;
          p('FEATURE|' || f_name || '|' || f_count || '|?| - | -');
        end loop;
        safe_close;
      exception
        when others then
          safe_close;
          p('INFO|FEATURE_USAGE_UNAVAILABLE|' || sqlcode);
      end;
  end;

  begin
    open c for
      'select replace(comp_id,''|'',''/''), ' ||
      '       replace(comp_name,''|'',''/''), ' ||
      '       version, status ' ||
      '  from dba_registry ' ||
      ' order by comp_id';

    loop
      fetch c into comp_id, comp_name, comp_version, comp_status;
      exit when c%notfound;
      p('COMPONENT|' || comp_id || '|' || comp_name || '|' ||
        comp_version || '|' || comp_status);
    end loop;
    safe_close;
  exception
    when others then
      safe_close;
      p('INFO|DBA_REGISTRY_UNAVAILABLE|' || sqlcode);
  end;

  p('META|CHECK_COMPLETE|YES');
end;
/
exit 0
