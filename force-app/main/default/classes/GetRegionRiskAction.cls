/**
 * Agent action 2 · "¿Por qué Península?"
 * The cross-system answer: delayed ERP orders, joined live to their Jira blockers
 * (both via Data Cloud Zero Copy) and to open support cases in Salesforce.
 */
public with sharing class GetRegionRiskAction {

    public class Request {
        @InvocableVariable(label='Región' description='Centro, Occidente, Norte o Península.')
        public String region;
    }

    public class Response {
        @InvocableVariable(label='Resumen' description='Causas raíz del retraso, clientes afectados, monto y casos de soporte abiertos.')
        public String summary;
    }

    @InvocableMethod(label='Explicar riesgo de una región' description='Explica por qué una región va atrasada: cruza órdenes retrasadas del ERP con bloqueos en Jira y casos de soporte abiertos, y agrupa por causa raíz. Úsala para "¿por qué Península?", "¿qué está bloqueando?" o "¿qué clientes están en riesgo?".')
    public static List<Response> run(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            Response res = new Response();
            try {
                String region = MostradorOpsService.resolveOneRegion(req.region);
                res.summary = summarize(region, MostradorOpsService.currentQuarter());
            } catch (MostradorOpsService.OpsException e) {
                res.summary = e.getMessage();
            }
            responses.add(res);
        }
        return responses;
    }

    @TestVisible
    private static String summarize(String region, MostradorOpsService.Quarter q) {
        List<MostradorOpsService.AtRiskOrder> orders = MostradorOpsService.atRiskOrders(region, q);
        List<MostradorOpsService.RegionHealth> health = MostradorOpsService.quarterHealth(new List<String>{ region }, q);
        MostradorOpsService.RegionHealth h = health.isEmpty() ? new MostradorOpsService.RegionHealth() : health[0];

        List<String> lines = new List<String>{
            region + ', trimestre ' + q.label + ': pronóstico actual ' + h.forecastPct() + '% de la meta de '
            + MostradorOpsService.mxn(h.target) + ' MXN. Órdenes retrasadas: ' + orders.size()
            + '. Fuentes: ERP, Jira y Zendesk (Snowflake, vía Data Cloud Zero Copy) + casos de soporte en Salesforce.'
        };
        if (orders.isEmpty()) {
            lines.add('No hay órdenes retrasadas en ' + region + ' este trimestre.');
            return String.join(lines, '\n');
        }
        for (MostradorOpsService.Blocker b : MostradorOpsService.groupByBlocker(orders)) {
            if (b.key != null) {
                lines.add('CAUSA RAÍZ ' + b.key + ' (' + b.summary + '): bloquea ' + b.customers + ' go-lives, '
                    + MostradorOpsService.mxn(b.amount) + ' MXN que no se pueden facturar. ' + b.withOpenCases
                    + ' de esos clientes tienen casos de soporte abiertos (' + b.withSalesforceCases + ' en Salesforce, '
                    + b.withZendeskCases + ' en Zendesk; ' + b.highPriorityCases + ' urgentes). Si ' + b.key + ' se resuelve y salen a producción, ' + region
                    + ' sube de ' + h.forecastPct() + '% a ' + h.pctWith(b.amount) + '%.');
            } else if (b.summary != null) {
                lines.add('Otros retrasos (' + b.customers + ', ' + MostradorOpsService.mxn(b.amount)
                    + ' MXN), sin causa común: ' + b.summary + '.');
            } else {
                lines.add('Sin bloqueo activo en Jira (' + b.customers + ' órdenes, ' + MostradorOpsService.mxn(b.amount)
                    + ' MXN): siguen retrasadas en el ERP pero ya pueden avanzar a go-live.');
            }
        }
        if (!MostradorOpsService.zendeskAvailable) {
            lines.add('Aviso: no pude consultar Zendesk, así que solo incluyo los casos de Salesforce.');
        }
        lines.add('Clientes afectados:');
        List<MostradorOpsService.AtRiskOrder> listed = new List<MostradorOpsService.AtRiskOrder>();
        for (MostradorOpsService.AtRiskOrder o : orders) {
            if (o.blockerKey != null) listed.add(o);
        }
        for (MostradorOpsService.AtRiskOrder o : orders) {
            if (o.blockerKey == null) listed.add(o);
        }
        for (MostradorOpsService.AtRiskOrder o : listed) {
            lines.add('- ' + o.customerName + ' (' + o.customerId + ', ' + o.municipality + '): orden ' + o.orderId
                + ' por ' + MostradorOpsService.mxn(o.amount) + ' MXN, prometida ' + MostradorOpsService.iso(o.promised) + '. Jira '
                + o.epicKey + (o.blockerKey != null ? ' bloqueado por ' + o.blockerKey
                    : (o.blockedReason != null ? ' detenido: ' + o.blockedReason : ' sin bloqueo activo'))
                + '. Casos abiertos: ' + o.openCases + (o.openCases > 0 ? ' (Salesforce ' + o.casesSalesforce + ', Zendesk ' + o.casesZendesk + ')' : '')
                + (o.topCaseSubject != null ? ' (' + o.topCasePriority + ': "' + o.topCaseSubject + '")' : '') + '.');
        }
        return String.join(lines, '\n');
    }
}
