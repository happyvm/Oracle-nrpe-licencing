# Windows deployment

## Supported target

The wrapper is designed for Windows Server 2003 through Windows Server 2025 and deliberately does not require PowerShell.

Dependencies are limited to tools present on legacy Windows Server plus Oracle SQL*Plus:

```text
cmd.exe
sc.exe
findstr.exe
sqlplus.exe
```

`.gitattributes` requests CRLF checkout for `.cmd` files.

## NSClient++

Place the repository under an NSClient++ scripts location, for example:

```text
C:\Program Files\NSClient++\scripts\oracle-nrpe-licensing\
```

Expose:

```text
checks\check_oracle_license.cmd
```

The exact NSClient++ configuration syntax differs considerably between releases, especially versions old enough to run on Windows Server 2003.

## Instance discovery

If `config\oracle_instances.conf` contains active entries, those mappings are used.

Otherwise the wrapper enumerates `OracleService<SID>` services and derives `ORACLE_HOME` from `BINARY_PATH_NAME`.

For old or heavily customized Oracle homes, explicit configuration is recommended:

```text
ORCL|C:\oracle\product\19.0.0\dbhome_1
LEGACY|D:\oracle\product\10.2.0\db_1
```

## Authentication

The NSClient++ service account must be able to run:

```text
sqlplus -s "/ as sysdba"
```

That normally means the service identity has appropriate local Oracle DBA-group membership. Review this carefully before using a privileged domain service account.
