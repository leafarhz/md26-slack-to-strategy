# DENUE Market Loader (MuleSoft 4)

Loads establishments from Mexico's national business directory
([INEGI DENUE](https://www.inegi.org.mx/servicios/api_denue.html)) into Snowflake
`MD26_DB.MARKET.ESTABLISHMENTS`, where Data Cloud reads them through Zero Copy.

```
POST /load → DENUE BuscarEntidad (4 states × 4 search terms × 300)
           → DataWeave (drops phone, email, website, legal name)
           → bulk insert ESTABLISHMENTS_STAGE
           → MERGE (dedupe) into ESTABLISHMENTS
```

States: Ciudad de México (Centro), Jalisco (Occidente), Nuevo León (Norte), Yucatán (Península).
Search terms: farmacia, restaurante, ferreteria, abarrotes.

## Run it

1. Run `snowflake/01_setup.sql` and `snowflake/03_market.sql`.
2. Create a key pair for `MD26_MULE_SVC` and register the public key
   (`ALTER USER MD26_MULE_SVC SET RSA_PUBLIC_KEY='...'`).
3. Copy `src/main/resources/local.properties.example` to `local.properties` and fill in
   your [DENUE token](https://www.inegi.org.mx/app/api/denue/v1/tokenVerify.aspx) and key path.
   Set `snowflake.account` in `config.properties`.
4. Build with Java 17 and **Maven 3.9.x** (mule-maven-plugin 4.7.0 fails on Maven 3.10):
   `mvn clean package -DskipTests`
5. Deploy the jar to a Mule 4.11 runtime (or run from Anypoint Code Builder) and
   `curl -X POST http://localhost:8081/load`.

Re-runs are safe: staging is cleared each run and the MERGE upserts on `DENUE_ID`.
