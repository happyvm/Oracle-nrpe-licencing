# Oracle NRPE Licensing

Nagios/NRPE-style Oracle Database licensing-risk inventory for mixed legacy and modern estates.

Target operating systems:

- Windows Server 2003 through Windows Server 2025
- Red Hat Enterprise Linux 5 through RHEL 10

The Windows wrapper intentionally uses `cmd.exe`, `sc.exe`, `findstr.exe` and SQL*Plus only. PowerShell is not required, which keeps the check usable on Windows Server 2003.

## What the check collects

For every local Oracle database instance it can query:

- SID, host, DB name and DBID
- Oracle version and detected edition: EE, SE, SE1, SE2, XE, PE or Free
- database role and open mode
- CDB/PDB information when available
- `control_management_pack_access`
- TRUE entries from `V$OPTION`
- detected feature usage from `DBA_FEATURE_USAGE_STATISTICS`
- installed components from `DBA_REGISTRY`
- technical risk signals for RAC configuration, In-Memory sizing, TDE encrypted tablespaces/wallet state, PDB count and a standby opened `READ ONLY WITH APPLY`

Nagios exit codes are standard:

- `0` OK
- `1` WARNING
- `2` CRITICAL
- `3` UNKNOWN

## Important: this is not an Oracle entitlement oracle

Oracle Database does not expose your commercial contract or entitlement as a license key. This project collects technical evidence and compares it with a local policy file.

`V$OPTION=TRUE` means a capability is available/enabled in the binary. It does not by itself prove separately licensable usage. `DBA_FEATURE_USAGE_STATISTICS` is useful evidence, but its interpretation is version-dependent and still has to be reconciled with the Oracle licensing guide and your contract.

No alert rule is enabled by default.

## Repository layout

```text
checks/
  check_oracle_license.sql
  check_oracle_license.sh
  check_oracle_license.cmd
config/
  oracle_license.rules
  oracle_instances.conf
docs/
  linux.md
  windows.md
  licensing.md
```

## Quick start - Linux

```bash
chmod 0755 checks/check_oracle_license.sh
./checks/check_oracle_license.sh
```

By default the wrapper uses active entries from `config/oracle_instances.conf`; if none exist it falls back to `/etc/oratab`.

Typical NRPE command:

```text
command[check_oracle_license]=/opt/oracle-nrpe-licensing/checks/check_oracle_license.sh
```

## Quick start - Windows

Place the repository under the NSClient++ scripts tree and expose:

```text
checks\check_oracle_license.cmd
```

If `config\oracle_instances.conf` has no active entry, the batch wrapper discovers `OracleService<SID>` services and derives `ORACLE_HOME` from their executable paths.

For very old Windows/NSClient++ deployments, an explicit `oracle_instances.conf` is recommended because it avoids unusual service-path parsing edge cases.

## Authentication

The wrappers currently connect locally with:

```text
sqlplus -s "/ as sysdba"
```

This avoids a monitoring password, but the NRPE/NSClient++ operating-system account must be authorized for Oracle OS authentication. A dedicated least-privilege database account can be used instead, but the exact grants differ between Oracle releases.

## Example output

```text
WARNING - Oracle license inventory: discovered=2 queried=2 violations=1 failures=0 | instances=2 queried=2 violations=1 failures=0
INFO - ORCL - db=ORCL edition=EE version=19.0.0.0.0 packs=DIAGNOSTIC+TUNING installed_options=42 used_features=18
WARNING - ORCL - rule [PARAM:DIAGNOSTIC+TUNING] matched: PARAM|control_management_pack_access|DIAGNOSTIC+TUNING
```

See `docs/licensing.md` before enabling production policy rules.
