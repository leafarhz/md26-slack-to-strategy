/**
 * Business logic behind the Mostrador operations agent (see docs/story.md).
 *
 * Reads:  ERP, Jira and market data through Data Cloud SQL (Zero Copy over Snowflake),
 *         support cases through SOQL. All CRM access runs in USER_MODE.
 * Writes: escalation Cases, follow-up Tasks and prospect Leads, in USER_MODE.
 *
 * The permission chain:
 *   Data Cloud does not know the Salesforce sharing model. So the scope of every federated
 *   answer is derived from what the running user can see in CRM: the regions of the
 *   Accounts visible to them. A rep who can only see Sur accounts only gets Sur numbers.
 */
public with sharing class MostradorOpsService {

    public static final List<String> REGIONS = new List<String>{ 'Centro', 'Occidente', 'Norte', 'Sur' };

    /** Activity families the agent may ask about, mapped to DENUE activity-class patterns. */
    public static final Map<String, String> FAMILIES = new Map<String, String>{
        'Farmacias'    => 'Farmacias%',
        'Restaurantes' => 'Restaurantes%',
        'Ferreterías'  => '%ferreter%',
        'Abarrotes'    => '%abarrotes%'
    };

    private static final Pattern ISSUE_KEY = Pattern.compile('^[A-Z][A-Z0-9]+-[0-9]+$');

    public class OpsException extends Exception {}

    // ───────────────────────────── Scope ─────────────────────────────

    public class Quarter {
        public String label;
        public Date startDate;
        public Date endDate;
        public Date asOf;
    }

    public static Quarter currentQuarter() {
        return quarterFor(Date.today());
    }

    @TestVisible
    private static Quarter quarterFor(Date d) {
        Integer q = (d.month() - 1) / 3 + 1;
        Quarter result = new Quarter();
        result.label = 'FY' + String.valueOf(d.year()).right(2) + '-Q' + q;
        result.startDate = Date.newInstance(d.year(), (q - 1) * 3 + 1, 1);
        result.endDate = result.startDate.addMonths(3).addDays(-1);
        result.asOf = d;
        return result;
    }

    /** Regions the running user may see: the regions of the Mostrador Accounts visible to them. */
    public static List<String> visibleRegions() {
        Set<String> seen = new Set<String>();
        try {
            for (AggregateResult ar : [
                SELECT Region__c region FROM Account
                WHERE ERP_Customer_Id__c != NULL AND Region__c != NULL
                WITH USER_MODE
                GROUP BY Region__c
            ]) {
                seen.add((String) ar.get('region'));
            }
        } catch (QueryException e) {
            // USER_MODE enforces field-level security: no access to the fields, no federated data
            throw new OpsException('No tienes permiso para consultar las cuentas de clientes de Mostrador '
                + '(falta el permiso "MD26 Mostrador Ops"). Pide acceso a tu administrador.');
        }
        List<String> ordered = new List<String>();
        for (String r : REGIONS) {
            if (seen.contains(r)) {
                ordered.add(r);
            }
        }
        return ordered;
    }

    /** Validates a requested region against the allow-list and the user's scope. Blank = all visible. */
    public static List<String> resolveRegions(String requested) {
        List<String> visible = visibleRegions();
        if (String.isBlank(requested)) {
            return visible;
        }
        String region = normalizeRegion(requested);
        if (!visible.contains(region)) {
            throw new OpsException('No tienes acceso a la región ' + region + '. Regiones visibles para ti: '
                + (visible.isEmpty() ? 'ninguna' : String.join(visible, ', ')) + '.');
        }
        return new List<String>{ region };
    }

    /** One region for a drill-down. Blank is fine when the user can only see one; otherwise ask. */
    public static String resolveOneRegion(String requested) {
        List<String> regions = resolveRegions(requested);
        if (regions.size() == 1) {
            return regions[0];
        }
        throw new OpsException(regions.isEmpty()
            ? 'No tienes acceso a cuentas de clientes de Mostrador.'
            : '¿De qué región? Puedes ver: ' + String.join(regions, ', ') + '.');
    }

    public static String normalizeRegion(String requested) {
        String wanted = requested.trim().toLowerCase();
        for (String r : REGIONS) {
            if (r.toLowerCase() == wanted) {
                return r;
            }
        }
        throw new OpsException('Región desconocida: "' + requested + '". Usa una de: ' + String.join(REGIONS, ', ') + '.');
    }

    private static String inList(List<String> values) {
        List<String> quoted = new List<String>();
        for (String v : values) {
            quoted.add(MostradorDataCloud.lit(v));
        }
        return '(' + String.join(quoted, ', ') + ')';
    }

    private static String dateLit(Date d) {
        return 'DATE ' + MostradorDataCloud.lit(String.valueOf(d));
    }

    // ─────────────────────── 1. ¿Vamos bien este trimestre? ───────────────────────

    public class RegionHealth {
        public String region;
        public Decimal target = 0;
        public Integer goLivesTarget = 0;
        public Decimal recognized = 0;
        public Decimal booked = 0;
        public Decimal delayed = 0;
        public Integer delayedOrders = 0;
        public Integer goLives = 0;

        public Decimal forecast() {
            return recognized + booked;
        }
        public Decimal forecastPct() {
            return target == 0 ? 0 : (100 * forecast() / target).setScale(1);
        }
        public Decimal pctWith(Decimal extra) {
            return target == 0 ? 0 : (100 * (forecast() + extra) / target).setScale(1);
        }
    }

    public static List<RegionHealth> quarterHealth(List<String> regions, Quarter q) {
        if (regions.isEmpty()) {
            return new List<RegionHealth>();
        }
        String sql =
            'SELECT t.region__c, t.bookings_target_mxn__c, t.go_lives_target__c, '
            + 'SUM(CASE WHEN o.status__c = \'Fulfilled\' THEN o.amount_mxn__c ELSE 0 END), '
            + 'SUM(CASE WHEN o.status__c = \'Booked\' THEN o.amount_mxn__c ELSE 0 END), '
            + 'SUM(CASE WHEN o.status__c = \'Delayed\' THEN o.amount_mxn__c ELSE 0 END), '
            + 'SUM(CASE WHEN o.status__c = \'Delayed\' THEN 1 ELSE 0 END), '
            + 'SUM(CASE WHEN o.status__c = \'Fulfilled\' THEN 1 ELSE 0 END) '
            + 'FROM ERP_Quarterly_Targets__dll t '
            + 'JOIN ERP_Customers__dll c ON c.region__c = t.region__c '
            + 'JOIN ERP_Sales_Orders__dll o ON o.customer_id__c = c.customer_id__c '
            + 'AND o.promised_date__c BETWEEN ' + dateLit(q.startDate) + ' AND ' + dateLit(q.endDate) + ' '
            + 'WHERE t.fiscal_quarter__c = ' + MostradorDataCloud.lit(q.label) + ' '
            + 'AND t.region__c IN ' + inList(regions) + ' '
            + 'GROUP BY t.region__c, t.bookings_target_mxn__c, t.go_lives_target__c';
        List<RegionHealth> result = new List<RegionHealth>();
        for (List<Object> row : MostradorDataCloud.query(sql)) {
            RegionHealth h = new RegionHealth();
            h.region = MostradorDataCloud.str(row[0]);
            h.target = MostradorDataCloud.dec(row[1]);
            h.goLivesTarget = MostradorDataCloud.num(row[2]);
            h.recognized = MostradorDataCloud.dec(row[3]);
            h.booked = MostradorDataCloud.dec(row[4]);
            h.delayed = MostradorDataCloud.dec(row[5]);
            h.delayedOrders = MostradorDataCloud.num(row[6]);
            h.goLives = MostradorDataCloud.num(row[7]);
            result.add(h);
        }
        return result;
    }

    // ─────────────────────── 2. ¿Por qué Sur? ───────────────────────

    public class AtRiskOrder {
        public String customerId;
        public String customerName;
        public String municipality;
        public String orderId;
        public Decimal amount = 0;
        public Date promised;
        public String epicKey;
        public String blockedIssueKey;
        public String blockerKey;
        public String blockerSummary;
        public String blockedReason;
        public Id accountId;
        public Id accountOwnerId;
        public Integer openCases = 0;
        public String topCasePriority;
        public String topCaseSubject;
    }

    public class Blocker {
        public String key;
        public String summary;
        public Integer customers = 0;
        public Decimal amount = 0;
        public Integer withOpenCases = 0;
        public Integer highPriorityCases = 0;
    }

    /** Delayed orders in a region this quarter, joined live to Jira blockers (Zero Copy) and CRM cases (SOQL). */
    public static List<AtRiskOrder> atRiskOrders(String region, Quarter q) {
        String sql =
            'SELECT c.customer_id__c, c.display_name__c, c.municipality__c, o.order_id__c, o.amount_mxn__c, '
            + 'o.promised_date__c, o.epic_key__c, i.issue_key__c, i.blocked_by__c, b.summary__c, i.blocked_reason__c '
            + 'FROM ERP_Sales_Orders__dll o '
            + 'JOIN ERP_Customers__dll c ON c.customer_id__c = o.customer_id__c '
            + 'LEFT JOIN Jira_Issues__dll i ON i.epic_key__c = o.epic_key__c AND i.status__c = \'Blocked\' '
            + 'LEFT JOIN Jira_Issues__dll b ON b.issue_key__c = i.blocked_by__c '
            + 'WHERE c.region__c = ' + MostradorDataCloud.lit(region) + ' AND o.status__c = \'Delayed\' '
            + 'AND o.promised_date__c BETWEEN ' + dateLit(q.startDate) + ' AND ' + dateLit(q.endDate) + ' '
            + 'ORDER BY o.amount_mxn__c DESC';
        Map<String, AtRiskOrder> byOrder = new Map<String, AtRiskOrder>();
        for (List<Object> row : MostradorDataCloud.query(sql)) {
            String orderId = MostradorDataCloud.str(row[3]);
            if (byOrder.containsKey(orderId)) {
                continue; // one row per order is enough; the first blocked task tells the story
            }
            AtRiskOrder o = new AtRiskOrder();
            o.customerId = MostradorDataCloud.str(row[0]);
            o.customerName = MostradorDataCloud.str(row[1]);
            o.municipality = MostradorDataCloud.str(row[2]);
            o.orderId = orderId;
            o.amount = MostradorDataCloud.dec(row[4]);
            o.promised = MostradorDataCloud.day(row[5]);
            o.epicKey = MostradorDataCloud.str(row[6]);
            o.blockedIssueKey = MostradorDataCloud.str(row[7]);
            o.blockerKey = MostradorDataCloud.str(row[8]);
            o.blockerSummary = MostradorDataCloud.str(row[9]);
            o.blockedReason = MostradorDataCloud.str(row[10]);
            byOrder.put(orderId, o);
        }
        attachCrm(byOrder.values());
        return byOrder.values();
    }

    /** Joins federated rows back to CRM. Customers the user cannot see in CRM are dropped. */
    private static void attachCrm(List<AtRiskOrder> orders) {
        Set<String> customerIds = new Set<String>();
        for (AtRiskOrder o : orders) {
            customerIds.add(o.customerId);
        }
        Map<String, Account> accounts = new Map<String, Account>();
        for (Account a : [
            SELECT Id, OwnerId, ERP_Customer_Id__c FROM Account
            WHERE ERP_Customer_Id__c IN :customerIds WITH USER_MODE
        ]) {
            accounts.put(a.ERP_Customer_Id__c, a);
        }
        Map<String, List<Case>> casesByCustomer = new Map<String, List<Case>>();
        for (Case c : [
            SELECT Account.ERP_Customer_Id__c, Subject, Priority FROM Case
            WHERE Account.ERP_Customer_Id__c IN :customerIds AND IsClosed = FALSE
            WITH USER_MODE
            ORDER BY CreatedDate
        ]) {
            String key = c.Account.ERP_Customer_Id__c;
            if (!casesByCustomer.containsKey(key)) {
                casesByCustomer.put(key, new List<Case>());
            }
            casesByCustomer.get(key).add(c);
        }
        for (Integer i = orders.size() - 1; i >= 0; i--) {
            AtRiskOrder o = orders[i];
            Account a = accounts.get(o.customerId);
            if (a == null) {
                orders.remove(i);
                continue;
            }
            o.accountId = a.Id;
            o.accountOwnerId = a.OwnerId;
            List<Case> cases = casesByCustomer.get(o.customerId);
            if (cases != null) {
                o.openCases = cases.size();
                for (Case c : cases) {
                    if (o.topCasePriority == null || c.Priority == 'High') {
                        o.topCasePriority = c.Priority;
                        o.topCaseSubject = c.Subject;
                    }
                }
            }
        }
    }

    public static List<Blocker> groupByBlocker(List<AtRiskOrder> orders) {
        Map<String, Blocker> byKey = new Map<String, Blocker>();
        for (AtRiskOrder o : orders) {
            String key = o.blockerKey == null ? '' : o.blockerKey;
            Blocker b = byKey.get(key);
            if (b == null) {
                b = new Blocker();
                b.key = o.blockerKey;
                b.summary = o.blockerKey == null ? o.blockedReason : o.blockerSummary;
                byKey.put(key, b);
            }
            b.customers++;
            b.amount += o.amount;
            if (o.openCases > 0) {
                b.withOpenCases++;
            }
            if (o.topCasePriority == 'High') {
                b.highPriorityCases++;
            }
        }
        // Shared Jira root causes first (most customers first), then everything else
        List<Blocker> result = new List<Blocker>();
        for (Blocker b : byKey.values()) {
            Integer i = 0;
            while (i < result.size() && rank(result[i]) >= rank(b)) {
                i++;
            }
            if (i == result.size()) {
                result.add(b);
            } else {
                result.add(i, b);
            }
        }
        return result;
    }

    private static Integer rank(Blocker b) {
        return (b.key != null ? 1000 : 0) + b.customers;
    }

    // ─────────────────────── 3. Escalar ───────────────────────

    public class EscalationResult {
        public List<Case> created = new List<Case>();
        public List<String> alreadyEscalated = new List<String>();
        public List<AtRiskOrder> pending = new List<AtRiskOrder>();
        public Integer tasks = 0;
    }

    public static String validateIssueKey(String key) {
        String k = key == null ? '' : key.trim().toUpperCase();
        if (!ISSUE_KEY.matcher(k).matches()) {
            throw new OpsException('Clave de Jira inválida: "' + key + '". Ejemplo: PLAT-7.');
        }
        return k;
    }

    /**
     * Re-reads the at-risk customers itself (never trusts a list from the model), then creates one
     * escalation Case per customer blocked by the given issue, plus a follow-up Task for the owner.
     * Idempotent: customers with an open escalation for the same issue are skipped.
     */
    public static EscalationResult escalate(String region, String blockerKey, Quarter q) {
        return escalate(region, blockerKey, q, true);
    }

    /** commit=false: same selection, nothing written. That is the preview the user confirms. */
    public static EscalationResult escalate(String region, String blockerKey, Quarter q, Boolean commitWrites) {
        List<AtRiskOrder> targets = new List<AtRiskOrder>();
        for (AtRiskOrder o : atRiskOrders(region, q)) {
            if (o.blockerKey == blockerKey) {
                targets.add(o);
            }
        }
        EscalationResult result = new EscalationResult();
        if (targets.isEmpty()) {
            return result;
        }
        Set<Id> already = new Set<Id>();
        for (Case c : [
            SELECT AccountId FROM Case
            WHERE Jira_Issue_Key__c = :blockerKey AND IsClosed = FALSE AND Status = 'Escalated'
            WITH USER_MODE
        ]) {
            already.add(c.AccountId);
        }
        List<Case> cases = new List<Case>();
        List<AtRiskOrder> escalating = new List<AtRiskOrder>();
        for (AtRiskOrder o : targets) {
            if (already.contains(o.accountId)) {
                result.alreadyEscalated.add(o.customerName);
                continue;
            }
            escalating.add(o);
            cases.add(new Case(
                AccountId = o.accountId,
                Subject = 'Escalación: go-live bloqueado por ' + blockerKey,
                Status = 'Escalated',
                Priority = 'High',
                Origin = 'Web',
                Jira_Issue_Key__c = blockerKey,
                ERP_Order_Id__c = o.orderId,
                Description = 'Escalado por el agente de operaciones de Mostrador.\n'
                    + 'Cliente: ' + o.customerName + ' (' + o.customerId + ')\n'
                    + 'Orden ERP: ' + o.orderId + ' · ' + mxn(o.amount) + ' MXN · prometida ' + iso(o.promised) + '\n'
                    + 'Jira: ' + o.epicKey + ' bloqueado por ' + blockerKey + ' (' + o.blockerSummary + ')\n'
                    + 'Casos abiertos del cliente: ' + o.openCases
            ));
        }
        if (cases.isEmpty()) {
            return result;
        }
        if (!commitWrites) {
            result.pending = escalating;
            return result;
        }
        insert as user cases;
        List<Task> tasks = new List<Task>();
        for (Integer i = 0; i < cases.size(); i++) {
            AtRiskOrder o = escalating[i];
            tasks.add(new Task(
                WhatId = o.accountId,
                OwnerId = o.accountOwnerId,
                Subject = 'Dar seguimiento: ' + o.customerName + ' bloqueado por ' + blockerKey,
                Priority = 'High',
                Status = 'Not Started',
                ActivityDate = Date.today().addDays(1),
                Description = 'Caso de escalación creado por el agente. Orden ' + o.orderId + ', ' + o.epicKey + '.'
            ));
        }
        insert as user tasks;
        result.created = [SELECT Id, CaseNumber, Account.Name FROM Case WHERE Id IN :cases WITH USER_MODE ORDER BY CaseNumber];
        result.tasks = tasks.size();
        return result;
    }

    // ─────────────────────── 4. ¿Dónde está la oportunidad? ───────────────────────

    public class FamilySpeed {
        public String family;
        public Integer goLives = 0;
        public Decimal avgDays = 0;
    }

    /** Average days from order to go-live per activity family, over the region's completed go-lives. */
    public static List<FamilySpeed> goLiveSpeed(String region) {
        String sql =
            'SELECT c.activity_class__c, o.order_date__c, o.delivered_date__c '
            + 'FROM ERP_Sales_Orders__dll o JOIN ERP_Customers__dll c ON c.customer_id__c = o.customer_id__c '
            + 'WHERE c.region__c = ' + MostradorDataCloud.lit(region) + ' AND o.status__c = \'Fulfilled\'';
        Map<String, List<Integer>> days = new Map<String, List<Integer>>();
        for (List<Object> row : MostradorDataCloud.query(sql)) {
            String family = familyOf(MostradorDataCloud.str(row[0]));
            Date ordered = MostradorDataCloud.day(row[1]);
            Date delivered = MostradorDataCloud.day(row[2]);
            if (family == null || ordered == null || delivered == null) {
                continue;
            }
            if (!days.containsKey(family)) {
                days.put(family, new List<Integer>());
            }
            days.get(family).add(ordered.daysBetween(delivered));
        }
        List<FamilySpeed> result = new List<FamilySpeed>();
        for (String family : days.keySet()) {
            FamilySpeed s = new FamilySpeed();
            s.family = family;
            s.goLives = days.get(family).size();
            Integer total = 0;
            for (Integer d : days.get(family)) {
                total += d;
            }
            s.avgDays = (Decimal.valueOf(total) / s.goLives).setScale(1);
            result.add(s);
        }
        return result;
    }

    /** Fastest family with at least three go-lives; falls back to the fastest overall. */
    public static FamilySpeed fastestFamily(List<FamilySpeed> speeds) {
        FamilySpeed best;
        for (FamilySpeed s : speeds) {
            if (s.goLives >= 3 && (best == null || s.avgDays < best.avgDays)) {
                best = s;
            }
        }
        if (best == null) {
            for (FamilySpeed s : speeds) {
                if (best == null || s.avgDays < best.avgDays) {
                    best = s;
                }
            }
        }
        return best;
    }

    public static String familyOf(String activityClass) {
        if (activityClass == null) {
            return null;
        }
        String c = activityClass.toLowerCase();
        if (c.startsWith('farmacias')) return 'Farmacias';
        if (c.startsWith('restaurantes')) return 'Restaurantes';
        if (c.contains('ferreter')) return 'Ferreterías';
        if (c.contains('abarrotes') || c.contains('minisuper')) return 'Abarrotes';
        return null;
    }

    public static String normalizeFamily(String requested) {
        if (String.isBlank(requested)) {
            return null;
        }
        String wanted = requested.trim().toLowerCase();
        for (String f : FAMILIES.keySet()) {
            String plain = f.toLowerCase().replace('í', 'i');
            if (f.toLowerCase() == wanted || plain == wanted || plain.startsWith(wanted.replace('í', 'i').removeEnd('s'))) {
                return f;
            }
        }
        throw new OpsException('Giro desconocido: "' + requested + '". Usa uno de: ' + String.join(new List<String>(FAMILIES.keySet()), ', ') + '.');
    }

    public class Prospect {
        public String denueId;
        public String name;
        public String activityClass;
        public String neighborhood;
        public String municipality;
        public String stateName;
        public String street;
        public String postalCode;
        public String stratum;
        public Decimal km;
    }

    /**
     * Real businesses from INEGI DENUE, in the given family and region, within radiusKm of at least one
     * current customer of that region, that are not already Leads. Nearest first.
     */
    public static List<Prospect> findProspects(String region, String family, Decimal radiusKm, Integer maxResults) {
        String distance =
            '6371 * 2 * ASIN(SQRT(POWER(SIN(RADIANS(e.latitude__c - c.latitude__c) / 2), 2) + '
            + 'COS(RADIANS(c.latitude__c)) * COS(RADIANS(e.latitude__c)) * '
            + 'POWER(SIN(RADIANS(e.longitude__c - c.longitude__c) / 2), 2)))';
        String sql =
            'SELECT e.denue_id__c, e.name__c, e.activity_class__c, e.neighborhood__c, e.municipality__c, '
            + 'e.state_name__c, e.street__c, e.ext_number__c, e.postal_code__c, e.stratum__c, MIN(' + distance + ') AS km '
            + 'FROM DENUE_Establishments__dll e JOIN ERP_Customers__dll c ON c.region__c = ' + MostradorDataCloud.lit(region) + ' '
            + 'WHERE e.region__c = ' + MostradorDataCloud.lit(region) + ' '
            + 'AND e.activity_class__c LIKE ' + MostradorDataCloud.lit(FAMILIES.get(family)) + ' '
            + 'AND ' + distance + ' <= ' + radiusKm.setScale(2) + ' '
            + 'GROUP BY e.denue_id__c, e.name__c, e.activity_class__c, e.neighborhood__c, e.municipality__c, '
            + 'e.state_name__c, e.street__c, e.ext_number__c, e.postal_code__c, e.stratum__c '
            + 'ORDER BY km LIMIT 500';
        List<Prospect> candidates = new List<Prospect>();
        Set<String> ids = new Set<String>();
        for (List<Object> row : MostradorDataCloud.query(sql)) {
            Prospect p = new Prospect();
            p.denueId = MostradorDataCloud.str(row[0]);
            p.name = MostradorDataCloud.str(row[1]);
            p.activityClass = MostradorDataCloud.str(row[2]);
            p.neighborhood = MostradorDataCloud.str(row[3]);
            p.municipality = MostradorDataCloud.str(row[4]);
            p.stateName = MostradorDataCloud.str(row[5]);
            String street = MostradorDataCloud.str(row[6]);
            String ext = MostradorDataCloud.str(row[7]);
            p.street = String.isBlank(ext) || ext == '0' ? street : street + ' ' + ext;
            p.postalCode = MostradorDataCloud.str(row[8]);
            p.stratum = MostradorDataCloud.str(row[9]);
            p.km = MostradorDataCloud.dec(row[10]).setScale(2);
            candidates.add(p);
            ids.add(p.denueId);
        }
        Set<String> existing = new Set<String>();
        for (Lead l : [SELECT DENUE_Id__c FROM Lead WHERE DENUE_Id__c IN :ids WITH USER_MODE]) {
            existing.add(l.DENUE_Id__c);
        }
        List<Prospect> result = new List<Prospect>();
        for (Prospect p : candidates) {
            if (!existing.contains(p.denueId) && result.size() < maxResults) {
                result.add(p);
            }
        }
        return result;
    }

    public static List<Lead> createLeads(List<Prospect> prospects, String family) {
        List<Lead> leads = new List<Lead>();
        for (Prospect p : prospects) {
            leads.add(new Lead(
                Company = p.name.left(255),
                LastName = 'Encargado(a)',
                DENUE_Id__c = p.denueId,
                LeadSource = 'Other',
                Industry = family == 'Farmacias' ? 'Healthcare' : (family == 'Restaurantes' ? 'Hospitality' : 'Retail'),
                Street = p.street,
                City = p.municipality,
                State = p.stateName,
                PostalCode = p.postalCode,
                Country = 'Mexico',
                Description = 'Prospecto de INEGI DENUE: ' + p.activityClass + ' · ' + p.stratum
                    + ' · colonia ' + p.neighborhood + ' · a ' + p.km + ' km de un cliente de Mostrador.'
            ));
        }
        if (!leads.isEmpty()) {
            Database.upsert(leads, Lead.DENUE_Id__c, true, AccessLevel.USER_MODE);
        }
        return leads;
    }

    // ───────────────────────────── Formatting ─────────────────────────────

    public static String mxn(Decimal amount) {
        return '$' + amount.setScale(0).format();
    }

    public static String iso(Date d) {
        return d == null ? '' : String.valueOf(d);
    }
}
