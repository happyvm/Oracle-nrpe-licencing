# Licensing interpretation

This project is a technical screening tool, not a substitute for Oracle licensing advice or your contracts.

## Evidence sources

### V$OPTION

`V$OPTION` is inventory evidence. A TRUE value tells you that an option/feature is available in the Oracle binary. It is useful for identifying exposure, but it does not prove that a separately licensable feature has been used.

### DBA_FEATURE_USAGE_STATISTICS

The collector reports rows where `DETECTED_USAGES > 0`, including `CURRENTLY_USED`, first usage and last usage when those columns exist on the installed release.

Treat this as stronger technical evidence than binary availability, but not as a standalone contractual conclusion. Feature names and licensing rules changed across Oracle releases.

### control_management_pack_access

The collector reports `control_management_pack_access` when the parameter exists. Values such as `DIAGNOSTIC+TUNING` are exposure signals that should be reconciled with your licensed management packs and with actual feature usage.

### Additional signals

The SQL collector also emits technical `SIGNAL` records:

- `RAC_CONFIGURED`
- `INMEMORY_SIZE`
- `PDB_COUNT`
- `TDE_ENCRYPTED_TABLESPACES`
- `TDE_WALLET_STATUS`
- `ACTIVE_DATA_GUARD_LIKE`

`ACTIVE_DATA_GUARD_LIKE=YES` currently means the database reports `PHYSICAL STANDBY` and `READ ONLY WITH APPLY`. It is deliberately named as a signal rather than a legal conclusion.

## Policy file

Rules are case-insensitive literal matches:

```text
SEVERITY|SOURCE|PATTERN
```

Example policy for features that are *not* licensed in a particular estate:

```text
CRITICAL|FEATURE|Partitioning
CRITICAL|FEATURE|Advanced Compression
WARNING|OPTION|Partitioning
WARNING|PARAM|DIAGNOSTIC+TUNING
WARNING|SIGNAL|RAC_CONFIGURED|TRUE
```

Do not copy example rules blindly. Build the policy from the entitlement owned by your organization and the exact Oracle release/edition in service.

## Audit trail

NRPE should be the alerting layer, not the only evidence store. For a large estate, pair this check with a scheduled export of the raw collector output to a central, timestamped inventory repository.
