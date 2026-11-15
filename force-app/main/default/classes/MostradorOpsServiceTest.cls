@IsTest
private class MostradorOpsServiceTest {

    /** Stands in for Data Cloud: Apex tests cannot call the Query API. Answers by recognising the SQL. */
    private class FakeDataCloud implements MostradorDataCloud.Runner {
        public List<String> seen = new List<String>();
        public List<List<Object>> run(String sql) {
            seen.add(sql);
            if (sql.contains('FROM ERP_Quarterly_Targets__dll')) {
                return new List<List<Object>>{
                    new List<Object>{ 'Sur', '690000.00', 21, '257300.00', '170300.00', '200500.00', 10, 7 }
                };
            }
            if (sql.contains('LEFT JOIN Jira_Issues__dll')) {
                return new List<List<Object>>{
                    new List<Object>{ 'MX-000001', 'Farmacia Uno', 'Mérida', 'SO-1', '13000.00', '2026-10-25', 'IMPL-1', 'IMPL-3', 'PLAT-7', 'Timbrado CFDI', 'Bloqueado por PLAT-7' },
                    new List<Object>{ 'MX-000002', 'Taquería Dos', 'Mérida', 'SO-2', '41800.00', '2026-10-31', 'IMPL-7', 'IMPL-8', null, null, 'Marcado como impedimento en Jira' }
                };
            }
            if (sql.contains('o.status__c = \'Fulfilled\'')) {
                return new List<List<Object>>{
                    new List<Object>{ 'Restaurantes con servicio de preparación de tacos y tortas', '2026-08-01', '2026-08-25' },
                    new List<Object>{ 'Restaurantes de autoservicio', '2026-08-01', '2026-08-29' },
                    new List<Object>{ 'Restaurantes de autoservicio', '2026-09-01', '2026-09-27' },
                    new List<Object>{ 'Farmacias sin minisúper', '2026-08-01', '2026-09-20' }
                };
            }
            if (sql.contains('FROM DENUE_Establishments__dll')) {
                return new List<List<Object>>{
                    new List<Object>{ '9001', 'TAQUERIA REAL', 'Restaurantes de autoservicio', 'CENTRO', 'Mérida', 'Yucatán', 'CALLE 60', '501', '97000', '0 a 5 personas', '0.42' },
                    new List<Object>{ '9002', 'COCINA REAL', 'Restaurantes de autoservicio', 'CENTRO', 'Mérida', 'Yucatán', 'CALLE 62', '0', '97000', '6 a 10 personas', '1.10' }
                };
            }
            return new List<List<Object>>();
        }
    }

    @TestSetup
    static void setup() {
        insert new List<Account>{
            new Account(Name = 'Farmacia Uno', ERP_Customer_Id__c = 'MX-000001', Region__c = 'Sur'),
            new Account(Name = 'Taquería Dos', ERP_Customer_Id__c = 'MX-000002', Region__c = 'Sur')
        };
        Account uno = [SELECT Id FROM Account WHERE ERP_Customer_Id__c = 'MX-000001'];
        insert new Case(AccountId = uno.Id, Subject = 'No puedo facturar', Priority = 'High', Status = 'New');
    }

    private static FakeDataCloud fake() {
        FakeDataCloud f = new FakeDataCloud();
        MostradorDataCloud.runner = f;
        return f;
    }

    @IsTest
    static void quarterHealthReportsRegionAgainstTarget() {
        fake();
        Test.startTest();
        GetQuarterHealthAction.Request req = new GetQuarterHealthAction.Request();
        String summary = GetQuarterHealthAction.run(new List<GetQuarterHealthAction.Request>{ req })[0].summary;
        Test.stopTest();
        Assert.isTrue(summary.contains('Sur: EN RIESGO'), summary);
        Assert.isTrue(summary.contains('62.0%'), summary);
    }

    @IsTest
    static void regionRiskGroupsByJiraRootCauseAndJoinsCases() {
        fake();
        GetRegionRiskAction.Request req = new GetRegionRiskAction.Request();
        req.region = 'sur';
        String summary = GetRegionRiskAction.run(new List<GetRegionRiskAction.Request>{ req })[0].summary;
        Assert.isTrue(summary.contains('CAUSA RAÍZ PLAT-7'), summary);
        Assert.isTrue(summary.contains('1 de esos clientes tienen casos de soporte abiertos (1 de prioridad alta)'), summary);
        Assert.isTrue(summary.indexOf('CAUSA RAÍZ') < summary.indexOf('Otros retrasos'), 'root cause listed first');
    }

    @IsTest
    static void rejectsUnknownRegionBeforeAnySql() {
        FakeDataCloud f = fake();
        GetRegionRiskAction.Request req = new GetRegionRiskAction.Request();
        req.region = 'Sur\' OR 1=1 --';
        String summary = GetRegionRiskAction.run(new List<GetRegionRiskAction.Request>{ req })[0].summary;
        Assert.isTrue(summary.startsWith('Región desconocida'), summary);
        Assert.areEqual(0, f.seen.size(), 'no SQL may run for invalid input');
    }

    private static User newRep() {
        User rep = new User(
            Alias = 'mdrep', Email = 'md26rep@example.com', EmailEncodingKey = 'UTF-8', LastName = 'Rep',
            LanguageLocaleKey = 'es', LocaleSidKey = 'es_MX', TimeZoneSidKey = 'America/Mexico_City',
            ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User'].Id,
            Username = 'md26rep' + Crypto.getRandomInteger() + '@example.com'
        );
        insert rep;
        return rep;
    }

    @IsTest
    static void userWithoutPermissionSetGetsNoFederatedData() {
        FakeDataCloud f = fake();
        System.runAs(newRep()) {
            GetQuarterHealthAction.Request req = new GetQuarterHealthAction.Request();
            String summary = GetQuarterHealthAction.run(new List<GetQuarterHealthAction.Request>{ req })[0].summary;
            Assert.isTrue(summary.startsWith('No tienes permiso'), summary);
        }
        Assert.areEqual(0, f.seen.size(), 'no Data Cloud query without CRM permission');
    }

    @IsTest
    static void scopeFollowsAccountsTheUserCanSee() {
        fake();
        User rep = newRep();
        insert new PermissionSetAssignment(
            AssigneeId = rep.Id,
            PermissionSetId = [SELECT Id FROM PermissionSet WHERE Name = 'MD26_Mostrador_Ops'].Id
        );
        System.runAs(rep) {
            Integer visible = [SELECT COUNT() FROM Account WHERE ERP_Customer_Id__c != NULL WITH USER_MODE];
            Assert.areEqual(visible == 0 ? 0 : 1, MostradorOpsService.visibleRegions().size(), 'scope follows CRM visibility');
        }
    }

    @IsTest
    static void escalationCreatesCasesAndTasksOnceForTheBlocker() {
        fake();
        EscalateBlockedCustomersAction.Request req = new EscalateBlockedCustomersAction.Request();
        req.region = 'Sur';
        req.blockerKey = 'plat-7';
        String preview = EscalateBlockedCustomersAction.run(new List<EscalateBlockedCustomersAction.Request>{ req })[0].summary;
        Assert.isTrue(preview.startsWith('VISTA PREVIA'), preview);
        Assert.areEqual(0, [SELECT COUNT() FROM Case WHERE Status = 'Escalated'], 'preview must not write');
        req.confirmar = true;
        String first = EscalateBlockedCustomersAction.run(new List<EscalateBlockedCustomersAction.Request>{ req })[0].summary;
        String second = EscalateBlockedCustomersAction.run(new List<EscalateBlockedCustomersAction.Request>{ req })[0].summary;

        Assert.isTrue(first.startsWith('Creé 1 casos'), first);
        Assert.isTrue(second.contains('no dupliqué'), second);
        Case c = [SELECT Priority, Status, Jira_Issue_Key__c, ERP_Order_Id__c FROM Case WHERE Status = 'Escalated'];
        Assert.areEqual('PLAT-7', c.Jira_Issue_Key__c);
        Assert.areEqual('SO-1', c.ERP_Order_Id__c);
        Assert.areEqual(1, [SELECT COUNT() FROM Task WHERE Subject LIKE 'Dar seguimiento:%']);
    }

    @IsTest
    static void escalationRejectsMalformedIssueKey() {
        fake();
        EscalateBlockedCustomersAction.Request req = new EscalateBlockedCustomersAction.Request();
        req.region = 'Sur';
        req.blockerKey = 'PLAT-7; DROP';
        String summary = EscalateBlockedCustomersAction.run(new List<EscalateBlockedCustomersAction.Request>{ req })[0].summary;
        Assert.isTrue(summary.startsWith('Clave de Jira inválida'), summary);
        Assert.areEqual(0, [SELECT COUNT() FROM Case WHERE Status = 'Escalated']);
    }

    @IsTest
    static void prospectsUseFastestFamilyAndLeadsAreNotDuplicated() {
        fake();
        FindProspectsAction.Request find = new FindProspectsAction.Request();
        find.region = 'Sur';
        String found = FindProspectsAction.run(new List<FindProspectsAction.Request>{ find })[0].summary;
        Assert.isTrue(found.contains('Giro: Restaurantes'), found);
        Assert.isTrue(found.contains('TAQUERIA REAL'), found);

        CreateProspectLeadsAction.Request create = new CreateProspectLeadsAction.Request();
        create.region = 'Sur';
        String preview = CreateProspectLeadsAction.run(new List<CreateProspectLeadsAction.Request>{ create })[0].summary;
        Assert.isTrue(preview.startsWith('VISTA PREVIA'), preview);
        Assert.areEqual(0, [SELECT COUNT() FROM Lead WHERE DENUE_Id__c != NULL], 'preview must not write');
        create.confirmar = true;
        CreateProspectLeadsAction.run(new List<CreateProspectLeadsAction.Request>{ create });
        String again = CreateProspectLeadsAction.run(new List<CreateProspectLeadsAction.Request>{ create })[0].summary;

        Assert.areEqual(2, [SELECT COUNT() FROM Lead WHERE DENUE_Id__c != NULL]);
        Assert.isTrue(again.startsWith('No había prospectos nuevos'), again);
    }

    @IsTest
    static void familyNamesAreNormalised() {
        Assert.areEqual('Ferreterías', MostradorOpsService.normalizeFamily('ferreteria'));
        Assert.areEqual('Farmacias', MostradorOpsService.normalizeFamily('Farmacia'));
        Assert.areEqual('Abarrotes', MostradorOpsService.familyOf('Comercio al por menor en tiendas de abarrotes, ultramarinos y misceláneas'));
        Assert.areEqual('FY26-Q4', MostradorOpsService.quarterFor(Date.newInstance(2026, 11, 20)).label);
    }
}
