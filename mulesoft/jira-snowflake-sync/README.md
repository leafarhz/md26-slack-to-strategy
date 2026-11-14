# Jira → Snowflake Sync (MuleSoft 4)

Syncs the Jira Cloud projects `PLAT` and `IMPL` into Snowflake `MD26_DB.JIRA.{EPICS, ISSUES}`
every minute, so Data Cloud can read them through Zero Copy. Jira stays the system of record.

```
Scheduler (60 s) or POST /sync
  → Jira REST /search/jql (paged)
  → DataWeave: derive "Blocked" from live links and flags
  → bulk insert *_STAGE → INSERT OVERWRITE (atomic swap)
```

**Blocked is derived, not stored.** An issue is blocked when it has an *is blocked by* link to
an issue that is not Done, or (when it has no such link) the Flag. Move `PLAT-7` to Done and the
nine go-lives it blocks are unblocked on the next run. That's the live moment in the demo.

## Run it

1. Run `snowflake/02_tables.sql` and `snowflake/05_jira_sync.sql`.
2. Copy `src/main/resources/local.properties.example` to `local.properties`: Jira email,
   classic API token, and the `MD26_MULE_SVC` private key path. Set `jira.host` in `config.properties`.
3. Build with Java 17 and Maven 3.9.x: `mvn clean package -DskipTests`
4. Deploy to a Mule 4.11 runtime; it syncs every minute, or `curl -X POST http://localhost:8082/sync`.

## Gotchas we hit

- Jira's create-link API is counter-intuitive: `inwardIssue` receives the *outward* description.
  To make "PLAT-7 blocks IMPL-52", POST `inwardIssue: PLAT-7, outwardIssue: IMPL-52`.
- DataWeave `not` binds looser than `or`: `not isEmpty(a) or b` is `not (isEmpty(a) or b)`. Use `!`.
- The DB connector classifies `INSERT OVERWRITE` as an insert: use `db:insert`, not `db:update`.
