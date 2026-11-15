/**
 * Agent action 3 · "Escala esos clientes y avísale al equipo."
 * Creates one escalation Case per customer blocked by a Jira issue, plus a follow-up Task
 * for the account owner. Runs as the user (USER_MODE). The customer list is re-read from
 * the source systems, never taken from the conversation. Idempotent per customer and issue.
 *
 * Two-phase on purpose: confirmar=false returns exactly what would be created and writes nothing;
 * only confirmar=true writes. The confirmation lives in code, not in the prompt
 * (Agent Script's require_user_confirmation does not block execution at runtime).
 */
public with sharing class EscalateBlockedCustomersAction {

    public class Request {
        @InvocableVariable(label='Región' description='Centro, Occidente, Norte o Península.')
        public String region;
        @InvocableVariable(label='Clave del bloqueo en Jira' description='La causa raíz a escalar, por ejemplo PLAT-7.')
        public String blockerKey;
        @InvocableVariable(label='Confirmado' description='false o vacío = solo muestra qué se va a escalar, sin crear nada. true = crea los casos y tareas. Pon true únicamente después de que el usuario dijo que sí a la vista previa.')
        public Boolean confirmar;
    }

    public class Response {
        @InvocableVariable(label='Resumen' description='Casos y tareas creados, y clientes que ya estaban escalados.')
        public String summary;
    }

    @InvocableMethod(label='Escalar clientes bloqueados' description='Escala a los clientes cuyo go-live está bloqueado por una incidencia de Jira: un caso de escalación por cliente y una tarea para el dueño de la cuenta. Llámala primero con confirmar=false para mostrar la vista previa; solo si el usuario dice que sí, llámala otra vez con confirmar=true.')
    public static List<Response> run(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            Response res = new Response();
            try {
                String region = MostradorOpsService.resolveOneRegion(req.region);
                String key = MostradorOpsService.validateIssueKey(req.blockerKey);
                Boolean go = req.confirmar == true;
                MostradorOpsService.EscalationResult r = MostradorOpsService.escalate(region, key, MostradorOpsService.currentQuarter(), go);
                res.summary = go ? summarize(r, region, key) : preview(r, region, key);
            } catch (MostradorOpsService.OpsException e) {
                res.summary = e.getMessage();
            }
            responses.add(res);
        }
        return responses;
    }

    private static String preview(MostradorOpsService.EscalationResult r, String region, String key) {
        if (r.pending.isEmpty()) {
            return r.alreadyEscalated.isEmpty()
                ? 'No encontré clientes en ' + region + ' con go-live bloqueado por ' + key + '. No hay nada que escalar.'
                : 'Todos los clientes bloqueados por ' + key + ' ya tienen una escalación abierta. No hay nada nuevo que crear.';
        }
        List<String> lines = new List<String>{
            'VISTA PREVIA, todavía no se creó nada. Voy a crear ' + r.pending.size() + ' casos de escalación (prioridad alta, ligados a '
            + key + ' y a su orden del ERP) y una tarea de seguimiento para el dueño de cada cuenta:'
        };
        for (MostradorOpsService.AtRiskOrder o : r.pending) {
            lines.add('- ' + o.customerName + ' · orden ' + o.orderId + ' · ' + MostradorOpsService.mxn(o.amount) + ' MXN');
        }
        if (!r.alreadyEscalated.isEmpty()) {
            lines.add('Ya escalados (no se duplican): ' + String.join(r.alreadyEscalated, ', ') + '.');
        }
        lines.add('¿Lo hago? Responde sí para confirmar.');
        return String.join(lines, '\n');
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
