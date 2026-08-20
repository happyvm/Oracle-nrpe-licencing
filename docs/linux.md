# Linux deployment

## Supported target

The wrapper is written for `/bin/sh` and avoids modern Bash-only syntax so it can be deployed across RHEL 5 through RHEL 10 estates.

## Files

A typical installation is:

```text
/opt/oracle-nrpe-licensing/
  checks/
  config/
```

Make the wrapper executable:

```bash
chmod 0755 /opt/oracle-nrpe-licensing/checks/check_oracle_license.sh
```

## Instance discovery

The wrapper first checks `config/oracle_instances.conf`. If that file contains no active `SID|ORACLE_HOME` line, `/etc/oratab` is used.

ASM/APX instances are ignored because the check targets database instances.

## NRPE

Example:

```text
command[check_oracle_license]=/opt/oracle-nrpe-licensing/checks/check_oracle_license.sh
```

The NRPE service account must be able to execute SQL*Plus with local Oracle OS authentication. In many estates the cleanest model is a tightly scoped sudo rule that runs only this check as the Oracle software owner.

## Environment overrides

The following variables can override defaults:

```text
SQL_FILE
RULES_FILE
INSTANCES_FILE
ORATAB
TMPDIR
```

## Legacy NRPE packet sizes

Older NRPE implementations may truncate long multiline plugin output. Keep production rules focused so the first line contains the monitoring state and avoid relying on NRPE output as the only licensing audit trail.
