/**
 * Thin gateway to Data Cloud SQL (Query API v2).
 *
 * Every federated read the agent makes goes through here. The Data Cloud objects
 * (*__dll) are external Data Lake Objects over Snowflake via Zero Copy: nothing is
 * copied into Salesforce, each query runs live against the system of record.
 *
 * Callers must only pass SQL built from validated values (see MostradorOpsService);
 * agent input never reaches this class unchecked.
 */
public with sharing class MostradorDataCloud {

    public interface Runner {
        List<List<Object>> run(String sql);
    }

    @TestVisible
    private static Runner runner = new QueryApiRunner();

    public static List<List<Object>> query(String sql) {
        return runner.run(sql);
    }

    private class QueryApiRunner implements Runner {
        public List<List<Object>> run(String sql) {
            ConnectApi.CdpQueryInput input = new ConnectApi.CdpQueryInput();
            input.sql = sql;
            ConnectApi.CdpQueryOutputV2 output = ConnectApi.CdpQuery.queryAnsiSqlV2(input);
            List<List<Object>> rows = new List<List<Object>>();
            for (ConnectApi.CdpQueryV2Row row : output.data) {
                rows.add(row.rowData);
            }
            return rows;
        }
    }

    // ── Value helpers: the Query API returns decimals as strings and dates as ISO text ──

    public static Decimal dec(Object value) {
        return value == null ? 0 : Decimal.valueOf(String.valueOf(value));
    }

    public static Integer num(Object value) {
        return dec(value).intValue();
    }

    public static String str(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    public static Date day(Object value) {
        return value == null ? null : Date.valueOf(String.valueOf(value).left(10));
    }

    /** Escapes a literal for SQL. Only ever used on values already validated against an allow-list. */
    public static String lit(String value) {
        return '\'' + value.replace('\'', '\'\'') + '\'';
    }
}
