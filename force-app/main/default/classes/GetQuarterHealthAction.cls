/**
 * Agent action 1 · "¿Vamos bien este trimestre?"
 * Quarter-to-date revenue vs target per region, read live from the ERP in Snowflake
 * through Data Cloud Zero Copy. Scoped to the regions the user can see in CRM.
 */
public with sharing class GetQuarterHealthAction {

    public class Request {
        @InvocableVariable(label='Región' description='Opcional. Centro, Occidente, Norte o Península. Vacío = todas las regiones que el usuario puede ver.')
        public String region;
    }

    public class Response {
        @InvocableVariable(label='Resumen' description='Avance del trimestre por región: meta, reconocido, pronóstico y monto en riesgo.')
        public String summary;
    }

    @InvocableMethod(label='Revisar avance del trimestre' description='Responde si vamos bien este trimestre: compara ingreso reconocido y agendado contra la meta de cada región, con datos en vivo del ERP. Úsala para preguntas como "¿vamos bien?", "¿cómo va el trimestre?" o "¿cómo va la Península?".')
    public static List<Response> run(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            Response res = new Response();
            try {
                res.summary = summarize(MostradorOpsService.resolveRegions(req.region), MostradorOpsService.currentQuarter());
            } catch (MostradorOpsService.OpsException e) {
                res.summary = e.getMessage();
            }
            responses.add(res);
        }
        return responses;
    }

    @TestVisible
    private static String summarize(List<String> regions, MostradorOpsService.Quarter q) {
        if (regions.isEmpty()) {
            return 'No tienes acceso a cuentas de clientes de Changarro, así que no puedo mostrar el avance de ninguna región.';
        }
        List<MostradorOpsService.RegionHealth> health = MostradorOpsService.quarterHealth(regions, q);
        // Worst first: that's what an ops leader needs to see
        List<MostradorOpsService.RegionHealth> sorted = new List<MostradorOpsService.RegionHealth>();
        for (MostradorOpsService.RegionHealth h : health) {
            Integer i = 0;
            while (i < sorted.size() && sorted[i].forecastPct() <= h.forecastPct()) {
                i++;
            }
            if (i == sorted.size()) {
                sorted.add(h);
            } else {
                sorted.add(i, h);
            }
        }
        List<String> lines = new List<String>{
            'Trimestre ' + q.label + ' (' + MostradorOpsService.iso(q.startDate) + ' a ' + MostradorOpsService.iso(q.endDate) + '), datos al ' + MostradorOpsService.iso(q.asOf)
            + '. Fuente: ERP de Changarro en Snowflake, consultado en vivo vía Data Cloud Zero Copy.'
        };
        for (MostradorOpsService.RegionHealth h : sorted) {
            String status = h.forecastPct() >= 95 ? 'en camino' : (h.forecastPct() >= 85 ? 'en riesgo leve' : 'EN RIESGO');
            lines.add('- ' + h.region + ': ' + status + '. Pronóstico ' + h.forecastPct() + '% de la meta de '
                + MostradorOpsService.mxn(h.target) + ' MXN (reconocido ' + MostradorOpsService.mxn(h.recognized)
                + ' + agendado ' + MostradorOpsService.mxn(h.booked) + '). Retrasado: '
                + MostradorOpsService.mxn(h.delayed) + ' MXN en ' + h.delayedOrders + ' órdenes. Go-lives: '
                + h.goLives + ' de ' + h.goLivesTarget + '.');
        }
        lines.add('Notas: Changarro factura cuando la tienda sale a producción (go-live). Reconocido = go-lives hechos; '
            + 'agendado = go-lives programados en tiempo; retrasado = órdenes que ya pasaron su fecha prometida.');
        return String.join(lines, '\n');
    }
}
