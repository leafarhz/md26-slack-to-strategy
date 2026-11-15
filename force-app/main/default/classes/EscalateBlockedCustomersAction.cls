/**
 * Agent action 3 · "Escala esos clientes y avísale al equipo."
 * Creates one escalation Case per customer blocked by a Jira issue, plus a follow-up Task
 * for the account owner. Runs as the user (USER_MODE). The customer list is re-read from
 * the source systems, never taken from the conversation. Idempotent per customer and issue.
 * Configure the agent action to require user confirmation.
 */
public with sharing class EscalateBlockedCustomersAction {

    public class Request {
        @InvocableVariable(required=true label='Región' description='Centro, Occidente, Norte o Sur.')
        public String region;
        @InvocableVariable(required=true label='Clave del bloqueo en Jira' description='La causa raíz a escalar, por ejemplo PLAT-7.')
        public String blockerKey;
    }

    public class Response {
        @InvocableVariable(label='Resumen' description='Casos y tareas creados, y clientes que ya estaban escalados.')
        public String summary;
    }

    @InvocableMethod(label='Escalar clientes bloqueados' description='Crea un caso de escalación por cada cliente cuyo go-live está bloqueado por una incidencia de Jira, y una tarea de seguimiento para el dueño de la cuenta. Pide confirmación antes de usarla.')
    public static List<Response> run(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            Response res = new Response();
            try {
                String region = MostradorOpsService.resolveRegions(req.region)[0];
                String key = MostradorOpsService.validateIssueKey(req.blockerKey);
                res.summary = summarize(MostradorOpsService.escalate(region, key, MostradorOpsService.currentQuarter()), region, key);
            } catch (MostradorOpsService.OpsException e) {
                res.summary = e.getMessage();
            }
            responses.add(res);
        }
        return responses;
    }

    private static String summarize(MostradorOpsService.EscalationResult r, String region, String key) {
        List<String> lines = new List<String>();
        if (r.created.isEmpty() && r.alreadyEscalated.isEmpty()) {
            return 'No encontré clientes en ' + region + ' con go-live bloqueado por ' + key + '. No creé nada.';
        }
        if (!r.created.isEmpty()) {
            lines.add('Creé ' + r.created.size() + ' casos de escalación (prioridad alta, ligados a ' + key
                + ' y a la orden del ERP) y ' + r.tasks + ' tareas de seguimiento para los dueños de cuenta:');
            for (Case c : r.created) {
                lines.add('- Caso ' + c.CaseNumber + ': ' + c.Account.Name);
            }
        }
        if (!r.alreadyEscalated.isEmpty()) {
            lines.add('Ya tenían escalación abierta por ' + key + ' (no dupliqué): ' + String.join(r.alreadyEscalated, ', ') + '.');
        }
        return String.join(lines, '\n');
    }
}
