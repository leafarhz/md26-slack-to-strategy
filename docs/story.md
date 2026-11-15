# The demo story

> Everything in this story is fictional: the company, the people and the transactions.
> The market data (businesses in Mexico) is real public data from INEGI DENUE.

## The company

**Changarro** sells point-of-sale software to small businesses across Mexico:
pharmacies, restaurants, hardware stores and corner shops.

Changarro **invoices a customer only when their store goes live.** So revenue
depends on implementations (Jira), and implementations depend on support.

## The person

**María Fernández, Directora de Operaciones.** Monday, 8:55 AM. The CEO pings her on Slack: the meeting
starts at 9:00 and she has five minutes to answer:

> **"¿Vamos bien este trimestre?"**

Today that answer means a BI dashboard, the ERP, Jira, the support console and
three Slack channels. Each one looks *almost* fine on its own.

## The hidden problem: one root cause, three systems

```
JIRA   PLAT blocker: CFDI 4.0 stamping fails with the new PAC API version
  ↓    → 9 go-lives in Yucatán stuck "Blocked"
ERP    → their orders are "Delayed"; no go-live, no invoice
  ↓    → Sur is booking fine but recognizing far below target
CRM    → the same customers open cases: "Ya pagué y no puedo vender"
```

The ERP says *revenue is late*. Jira says *a ticket is blocked*. Support says
*customers are upset*. Only by joining the three on `CUSTOMER_ID` do you see it
is **one problem**. That join is what Data Cloud Zero Copy makes cheap.

## The demo: four messages in Slack

| # | María asks | The agent | Systems |
|---|---|---|---|
| 1 | **¿Vamos bien este trimestre?** | Centro, Norte, Occidente on track. **Sur at ~62% of target.** | ERP |
| 2 | **¿Por qué Sur?** | 9 Yucatán go-lives blocked by the same Jira issue (CFDI). $X MXN that can't be invoiced. 7 of the 9 customers have open cases, 3 high priority. | ERP + Jira + CRM |
| 3 | **Escala esos clientes y avísale al equipo.** | Shows the 9, asks for confirmation, then creates an escalation **Case** per customer (with Jira key and ERP order) and a **Task** for each owner. Runs as María. | Writes to Salesforce |
| 4 | **Aunque lo arreglemos, ¿nos alcanza? ¿Dónde está la oportunidad?** | Clearing PLAT-7 takes Sur to 85%; even if every delayed order went live it ends at 91%, $61,900 short. The data says Sur's fastest go-lives are **restaurants** (~28 days order to go-live). Finds 40 real restaurants and taquerías (DENUE) within 2 km of current customers: 37 in Mérida, 3 in Ticul, Kinchil and Chemax; on confirmation creates them as **Leads**. | Market + writes to Salesforce |

**Close:** *"Prepárame 3 bullets para la junta."* María walks into the 9:00
meeting with a diagnosis, actions taken and a plan, in minutes instead of hours.

The question started as **operations** and ended as **strategy**, without leaving Slack.

## Optional: the permission chain, live

**José Pech**, the Sur sales rep in Mérida, asks the same *"¿Vamos bien?"* and sees only their own region.
Same agent, same question, different answer.

## What the data is built to show

- ~150 customers across four regions (CDMX = Centro, Jalisco = Occidente,
  Nuevo León = Norte, Yucatán = Sur), shaped from DENUE with fictional names
- Revenue recognized only at go-live
- One platform blocker in Jira causing nine blocked Yucatán go-lives; other regions
  have only normal noise
- Support cases concentrated on exactly those customers
- Every system looks healthy on its own; the problem appears only when crossed
