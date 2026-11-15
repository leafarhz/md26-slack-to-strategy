/**
 * Agent action 4 · "¿Dónde está la oportunidad?"
 * Sizes the remaining gap to target, finds the family of business with the fastest go-lives
 * in the region, and returns real businesses from INEGI DENUE (Zero Copy) near current
 * customers that are not yet Leads.
 */
public with sharing class FindProspectsAction {

    public class Request {
        @InvocableVariable(label='Región' description='Centro, Occidente, Norte o Sur.')
        public String region;
        @InvocableVariable(label='Giro' description='Opcional: Farmacias, Restaurantes, Ferreterías o Abarrotes. Vacío = el giro con go-lives más rápidos en la región.')
        public String family;
        @InvocableVariable(label='Radio en km' description='Opcional. Distancia máxima a un cliente actual. Por defecto 2.')
        public Decimal radiusKm;
        @InvocableVariable(label='Máximo de prospectos' description='Opcional. Por defecto 40.')
        public Integer maxResults;
    }

    public class Response {
        @InvocableVariable(label='Resumen' description='Brecha contra la meta, giro recomendado y prospectos reales cercanos a clientes actuales.')
        public String summary;
    }

    @InvocableMethod(label='Buscar oportunidad en una región' description='Calcula cuánto falta para la meta aun resolviendo los bloqueos, identifica el giro con go-lives más rápidos y busca negocios reales (INEGI DENUE) de ese giro cerca de clientes actuales que todavía no son prospectos. Úsala para "¿nos alcanza?", "¿dónde está la oportunidad?" o "¿a quién le vendemos?".')
    public static List<Response> run(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            Response res = new Response();
            try {
                res.summary = summarize(criteria(req.region, req.family, req.radiusKm, req.maxResults));
            } catch (MostradorOpsService.OpsException e) {
                res.summary = e.getMessage();
            }
            responses.add(res);
        }
        return responses;
    }

    /** Shared by FindProspectsAction and CreateProspectLeadsAction so both act on the same list. */
    public class Criteria {
        public String region;
        public String family;
        public MostradorOpsService.FamilySpeed speed;
        public Decimal radiusKm;
        public Integer maxResults;
    }

    public static Criteria criteria(String region, String family, Decimal radiusKm, Integer maxResults) {
        Criteria c = new Criteria();
        c.region = MostradorOpsService.resolveOneRegion(region);
        c.radiusKm = radiusKm == null || radiusKm <= 0 ? 2 : Math.min(radiusKm, 10);
        c.maxResults = maxResults == null || maxResults <= 0 ? 40 : Math.min(maxResults, 100);
        List<MostradorOpsService.FamilySpeed> speeds = MostradorOpsService.goLiveSpeed(c.region);
        c.family = MostradorOpsService.normalizeFamily(family);
        for (MostradorOpsService.FamilySpeed s : speeds) {
            if (s.family == c.family) {
                c.speed = s;
            }
        }
        if (c.family == null) {
            c.speed = MostradorOpsService.fastestFamily(speeds);
            c.family = c.speed == null ? 'Farmacias' : c.speed.family;
        }
        return c;
    }

    @TestVisible
    private static String summarize(Criteria c) {
        MostradorOpsService.Quarter q = MostradorOpsService.currentQuarter();
        List<String> lines = new List<String>();

        List<MostradorOpsService.RegionHealth> health = MostradorOpsService.quarterHealth(new List<String>{ c.region }, q);
        if (!health.isEmpty()) {
            MostradorOpsService.RegionHealth h = health[0];
            Decimal gap = h.target - h.forecast() - h.delayed;
            lines.add(c.region + ' ' + q.label + ': hoy ' + h.forecastPct() + '% de la meta. Aunque todas las órdenes retrasadas '
                + 'salieran a producción, llegaría a ' + h.pctWith(h.delayed) + '%'
                + (gap > 0 ? ': faltarían ' + MostradorOpsService.mxn(gap) + ' MXN de negocio nuevo.' : ' y alcanzaría la meta.'));
        }
        if (c.speed != null) {
            lines.add('Giro: ' + c.family + '. En ' + c.region + ' sus go-lives tardan en promedio ' + c.speed.avgDays
                + ' días desde la orden (' + c.speed.goLives + ' go-lives completados), así que es negocio que puede facturarse rápido.');
        }
        List<MostradorOpsService.Prospect> prospects = MostradorOpsService.findProspects(c.region, c.family, c.radiusKm, c.maxResults);
        if (prospects.isEmpty()) {
            lines.add('No encontré negocios de ese giro a menos de ' + c.radiusKm + ' km de clientes actuales que no sean ya prospectos.');
            return String.join(lines, '\n');
        }
        lines.add('Encontré ' + prospects.size() + ' negocios reales (INEGI DENUE) de ' + c.family + ' a menos de ' + c.radiusKm
            + ' km de un cliente actual, que todavía no son prospectos. Los más cercanos:');
        for (Integer i = 0; i < Math.min(10, prospects.size()); i++) {
            MostradorOpsService.Prospect p = prospects[i];
            lines.add('- ' + p.name + ' · colonia ' + p.neighborhood + ', ' + p.municipality + ' · ' + p.stratum + ' · a ' + p.km + ' km');
        }
        lines.add('Puedo crearlos como Leads en Salesforce si me lo confirmas.');
        return String.join(lines, '\n');
    }
}
