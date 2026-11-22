# Jira → Snowflake Sync (MuleSoft 4)

Syncs the Jira Cloud projects `PLAT` and `IMPL` into Snowflake `MD26_DB.JIRA.{EPICS, ISSUES}`
on demand, so Data Cloud can read them through Zero Copy. Jira stays the system of record.

```
POST /sync (or the 60 s scheduler, off by default)
  → Jira REST /search/jql (paged)
  → DataWeave: derive "Blocked" from live links and flags
  → bulk insert *_STAGE → INSERT OVERWRITE (atomic swap)
```

**Blocked is derived, not stored.** An issue is blocked when it has an *is blocked by* link to
an issue that is not Done, or (when it has no such link) the Flag. Move `PLAT-7` to Done and the
nine go-lives it blocks are unblocked on the next sync. That's the live moment in the demo.

## Run it

1. Run `snowflake/02_tables.sql` and `snowflake/05_jira_sync.sql`.
2. Copy `src/main/resources/local.properties.example` to `local.properties`: Jira email,
   classic API token, and the `MD26_MULE_SVC` private key path. Set `jira.host` in `config.properties`.
3. Build with Java 17 and Maven 3.9.x: `mvn clean package -DskipTests`
4. Deploy to a Mule 4.11 runtime and sync with `curl -X POST http://localhost:8082/sync`.

**Watch your Snowflake bill.** Every sync wakes the warehouse, and the warehouse bills a minimum of
60 seconds each time it resumes. A 60-second poll therefore keeps it running around the clock: on an
on-demand account, about 24 credits a day for an X-Small. That's why the scheduler ships stopped
(`sync.scheduler=stopped`). Set it to `started` only while you present, and put a resource monitor
on the warehouse.

## Gotchas we hit

- A 60-second scheduler never lets the warehouse auto-suspend. See *Watch your Snowflake bill* above.

- Jira's create-link API is counter-intuitive: `inwardIssue` receives the *outward* description.
  To make "PLAT-7 blocks IMPL-52", POST `inwardIssue: PLAT-7, outwardIssue: IMPL-52`.
- DataWeave `not` binds looser than `or`: `not isEmpty(a) or b` is `not (isEmpty(a) or b)`. Use `!`.
- The DB connector classifies `INSERT OVERWRITE` as an insert: use `db:insert`, not `db:update`.
