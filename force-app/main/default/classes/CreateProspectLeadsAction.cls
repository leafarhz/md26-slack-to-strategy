/**
 * Agent action 5 · "Créalos como Leads."
 * Creates the prospects found by FindProspectsAction (same criteria, same list) as Leads,
 * keyed by DENUE id so the same business is never created twice. Runs as the user.
 * Two-phase: confirmar=false previews, confirmar=true writes.
 */
public with sharing class CreateProspectLeadsAction {

    public class Request {
        @InvocableVariable(label='Región' description='Centro, Occidente, Norte o Sur.')
        public String region;
        @InvocableVariable(label='Giro' description='Opcional: Farmacias, Restaurantes, Ferreterías o Abarrotes. Usa el mismo que en la búsqueda.')
        public String family;
        @InvocableVariable(label='Radio en km' description='Opcional. Usa el mismo que en la búsqueda. Por defecto 2.')
        public Decimal radiusKm;
        @InvocableVariable(label='Máximo de prospectos' description='Opcional. Usa el mismo que en la búsqueda. Por defecto 40.')
        public Integer maxResults;
        @InvocableVariable(label='Confirmado' description='false o vacío = solo dice cuántos Leads se crearían, sin crear nada. true = los crea. Pon true únicamente después de que el usuario dijo que sí.')
        public Boolean confirmar;
    }

    public class Response {
        @InvocableVariable(label='Resumen' description='Leads creados en Salesforce.')
        public String summary;
    }

    @InvocableMethod(label='Crear prospectos como Leads' description='Crea como Leads los negocios encontrados con "Buscar oportunidad en una región", con los mismos criterios. Llámala primero con confirmar=false para la vista previa; solo si el usuario dice que sí, llámala con confirmar=true.')
    public static List<Response> run(List<Request> requests) {
        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            Response res = new Response();
            try {
                FindProspectsAction.Criteria c = FindProspectsAction.criteria(req.region, req.family, req.radiusKm, req.maxResults);
                List<MostradorOpsService.Prospect> prospects = MostradorOpsService.findProspects(c.region, c.family, c.radiusKm, c.maxResults);
                if (req.confirmar != true) {
                    res.summary = prospects.isEmpty()
                        ? 'No hay prospectos nuevos que crear: los negocios encontrados ya son Leads.'
                        : 'VISTA PREVIA, todavía no se creó nada. Crearía ' + prospects.size() + ' Leads de ' + c.family + ' en ' + c.region
                            + ' (negocios reales de INEGI DENUE a menos de ' + c.radiusKm + ' km de clientes actuales), asignados a ti. ¿Los creo? Responde sí para confirmar.';
                    responses.add(res);
                    continue;
                }
                List<Lead> leads = MostradorOpsService.createLeads(prospects, c.family);
                res.summary = leads.isEmpty()
                    ? 'No había prospectos nuevos que crear: los negocios encontrados ya son Leads.'
                    : 'Creé ' + leads.size() + ' Leads de ' + c.family + ' en ' + c.region
                        + ' (origen: INEGI DENUE, a menos de ' + c.radiusKm + ' km de clientes actuales). '
                        + 'Quedan asignados a ti y marcados como "Open - Not Contacted".';
            } catch (MostradorOpsService.OpsException e) {
                res.summary = e.getMessage();
            }
            responses.add(res);
        }
        return responses;
    }
}
