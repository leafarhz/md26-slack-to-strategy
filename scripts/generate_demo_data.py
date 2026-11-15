#!/usr/bin/env python3
"""Generate the Mostrador demo data (see docs/story.md).

Input : an export of MD26_DB.MARKET.ESTABLISHMENTS (real INEGI DENUE data) as JSON
Output: CSVs in demo/data/ for Snowflake (ERP, Jira) and Salesforce (Accounts, Cases)

Customers are *shaped* from real establishments (industry, size, municipality,
neighbourhood) but get fictional names, jittered coordinates and no DENUE id,
so no fictional late invoice or complaint can be traced back to a real business.

Deterministic: same input + same SEED = same output.

Usage: python3 scripts/generate_demo_data.py <establishments.json>
"""

import csv
import json
import random
import sys
from collections import defaultdict
from datetime import date, timedelta
from pathlib import Path

SEED = 2026
TODAY = date(2026, 11, 14)          # data "as of"; the talk is 2026-11-20, same quarter
Q_START, Q_END = date(2026, 10, 1), date(2026, 12, 31)
QUARTER = "FY26-Q4"

OUT = Path(__file__).resolve().parent.parent / "demo" / "data"

REGION_CUSTOMERS = {"Centro": 42, "Occidente": 36, "Norte": 36, "Sur": 36}
# Sur leans on pharmacies and restaurants in Mérida: that's where the story lives.
VERTICAL_MIX = {
    "Centro":    {"Farmacia": 10, "Restaurante": 12, "Ferretería": 10, "Abarrotes": 10},
    "Occidente": {"Farmacia": 9,  "Restaurante": 9,  "Ferretería": 9,  "Abarrotes": 9},
    "Norte":     {"Farmacia": 9,  "Restaurante": 9,  "Ferretería": 9,  "Abarrotes": 9},
    "Sur":       {"Farmacia": 16, "Restaurante": 10, "Ferretería": 4,  "Abarrotes": 6},
}
BLOCKED_GO_LIVES = 9               # Sur go-lives stuck behind the CFDI blocker
SUR_FORECAST_PCT = 0.62            # what question 1 should reveal
SUR_IF_UNBLOCKED_PCT = 0.85        # what question 4 should reveal
OTHER_REGION_PCT = {"Centro": 1.03, "Occidente": 0.97, "Norte": 0.99}

PREFIX = {
    "Farmacia":    ["Farmacia", "Botica", "Farmacia"],
    "Restaurante": ["Cocina", "Taquería", "Fonda", "Antojitos", "Restaurante"],
    "Ferretería":  ["Ferretería", "Tlapalería", "Materiales"],
    "Abarrotes":   ["Abarrotes", "Miscelánea", "Tienda"],
}
NAME_WORDS = [
    "La Ceiba", "El Faro", "Los Laureles", "La Esperanza", "El Roble", "San Marcos",
    "La Palma", "Las Flores", "El Mirador", "La Fuente", "Santa Rosa", "El Sol",
    "La Luna", "Los Arcos", "El Portal", "La Estrella", "Del Parque", "La Huerta",
    "El Jardín", "Los Álamos", "La Cruz", "El Olivo", "Del Centro", "La Gloria",
    "El Ahorro", "La Nueva", "La Ermita", "Santa Ana", "El Zapote", "La Pitaya",
    "El Nogal", "La Joya", "El Pozo", "Las Torres", "El Puente", "La Loma",
]
PEOPLE = ["Ana Ruiz", "Luis Pérez", "Sofía Cano", "Diego Mora", "Valeria Gil",
          "Jorge Lara", "Paola Ríos", "Iván Soto", "Carla Vega", "Hugo Peña"]

INDUSTRY = {"Farmacia": "Healthcare", "Restaurante": "Hospitality",
            "Ferretería": "Retail", "Abarrotes": "Retail"}
STRATUM_EMPLOYEES = {"0 a 5 personas": 3, "6 a 10 personas": 8, "11 a 30 personas": 20,
                     "31 a 50 personas": 40, "51 a 100 personas": 75,
                     "101 a 250 personas": 175, "251 y más personas": 300}
STRATUM_STORES = {"0 a 5 personas": 1, "6 a 10 personas": 1, "11 a 30 personas": 2,
                  "31 a 50 personas": 4, "51 a 100 personas": 6,
                  "101 a 250 personas": 8, "251 y más personas": 10}

CFDI_BLOCKER_SUMMARY = "Timbrado CFDI 4.0 falla con la nueva versión del API del PAC"
GO_LIVE_TASKS = [
    "Configurar catálogo de productos",
    "Instalar hardware (terminal e impresora)",
    "Configurar facturación CFDI 4.0",
    "Capacitación al personal",
    "Go-live en tienda",
]


def vertical_of(e):
    c = (e["ACTIVITY_CLASS"] or "").lower()
    if c.startswith("farmacias"):
        return "Farmacia"
    if c.startswith("restaurantes"):
        return "Restaurante"
    if "ferreter" in c:
        return "Ferretería"
    if "abarrotes" in c or "minisupers" in c:
        return "Abarrotes"
    return None  # e.g. doctors' offices that matched "farmacia" by name


def money(x):
    return round(x / 100) * 100


def rand_date(rng, start, end):
    return start + timedelta(days=rng.randint(0, (end - start).days))


def title(s):
    return " ".join(w.capitalize() for w in (s or "").split())


def build(establishments):
    rng = random.Random(SEED)

    pool = defaultdict(list)
    for e in establishments:
        v = vertical_of(e)
        if v:
            pool[(e["REGION"], v)].append(e)

    # ── Customers ────────────────────────────────────────────────────────────
    customers, used_names = [], set()
    n = 0
    for region, total in REGION_CUSTOMERS.items():
        for vertical, count in VERTICAL_MIX[region].items():
            candidates = pool[(region, vertical)]
            if region == "Sur" and vertical in ("Farmacia", "Restaurante"):
                candidates = [e for e in candidates if e["MUNICIPALITY"] == "Mérida"] or candidates
            for e in rng.sample(candidates, count):
                n += 1
                while True:
                    name = f"{rng.choice(PREFIX[vertical])} {rng.choice(NAME_WORDS)}"
                    hood = title(e["NEIGHBORHOOD"])
                    if hood:
                        name += f" ({hood})"
                    if name not in used_names:
                        used_names.add(name)
                        break
                customers.append({
                    "CUSTOMER_ID": f"MX-{n:06d}",
                    "DISPLAY_NAME": name,
                    "VERTICAL": vertical,
                    "ACTIVITY_CODE": e["ACTIVITY_CODE"],
                    "ACTIVITY_CLASS": e["ACTIVITY_CLASS"],
                    "STRATUM": e["STRATUM"],
                    "STATE_CODE": e["STATE_CODE"],
                    "STATE_NAME": e["STATE_NAME"],
                    "MUNICIPALITY": e["MUNICIPALITY"],
                    # ~300 m jitter: realistic for maps, not a pointer to the real shop
                    "LATITUDE": round(float(e["LATITUDE"]) + rng.uniform(-0.003, 0.003), 6),
                    "LONGITUDE": round(float(e["LONGITUDE"]) + rng.uniform(-0.003, 0.003), 6),
                    "SEGMENT": "SMB" if STRATUM_EMPLOYEES.get(e["STRATUM"], 3) <= 10 else "MidMarket",
                    "REGION": region,
                    "CUSTOMER_SINCE": rand_date(rng, date(2024, 1, 15), date(2026, 9, 15)).isoformat(),
                    "_stores": STRATUM_STORES.get(e["STRATUM"], 1),
                })

    # ── Orders ───────────────────────────────────────────────────────────────
    orders, order_n = [], 0

    def new_order(c, order_date, promised, status, delivered=None, cfdi=True):
        nonlocal order_n
        order_n += 1
        product = "Mostrador POS + Facturación CFDI" if cfdi else "Mostrador POS"
        per_store = rng.uniform(26000, 42000) + (6000 if cfdi else 0)
        o = {
            "ORDER_ID": f"SO-2026-{order_n:05d}",
            "CUSTOMER_ID": c["CUSTOMER_ID"],
            "ORDER_DATE": order_date.isoformat(),
            "FISCAL_QUARTER": f"FY{str(promised.year)[2:]}-Q{(promised.month - 1) // 3 + 1}",
            "PRODUCT": product,
            "AMOUNT_MXN": money(per_store * c["_stores"]),
            "STATUS": status,
            "PROMISED_DATE": promised.isoformat(),
            "DELIVERED_DATE": delivered.isoformat() if delivered else "",
            "EPIC_KEY": "",
            "_customer": c,
            "_blocked_by_cfdi": False,
            "_noise_delay": False,
        }
        orders.append(o)
        return o

    by_region = defaultdict(list)
    for c in customers:
        by_region[c["REGION"]].append(c)

    for region, cs in by_region.items():
        rng.shuffle(cs)
        # History: every customer went live once before this quarter.
        for c in cs:
            since = date.fromisoformat(c["CUSTOMER_SINCE"])
            go_live = min(since + timedelta(days=rng.randint(20, 45)), date(2026, 9, 30))
            new_order(c, since, go_live, "Fulfilled", go_live, cfdi=rng.random() < 0.7)

        q4 = cs[: int(len(cs) * 0.6)]   # expansions / new stores this quarter
        if region == "Sur":
            merida_cfdi = [c for c in q4 if c["MUNICIPALITY"] == "Mérida"
                           and c["VERTICAL"] in ("Farmacia", "Restaurante")]
            blocked = set(c["CUSTOMER_ID"] for c in merida_cfdi[:BLOCKED_GO_LIVES])
        else:
            blocked = set()
        # Every region has a little ordinary friction: small, single-store delays.
        small = sorted(c["CUSTOMER_ID"] for c in q4
                       if c["CUSTOMER_ID"] not in blocked and c["_stores"] == 1)
        noise = set(rng.sample(small, 1 if region == "Sur" else 2))

        for c in q4:
            cid = c["CUSTOMER_ID"]
            if cid in blocked:
                promised = rand_date(rng, date(2026, 10, 20), date(2026, 11, 12))
                o = new_order(c, promised - timedelta(days=rng.randint(30, 50)), promised, "Delayed")
                o["_blocked_by_cfdi"] = True
            elif cid in noise:
                promised = rand_date(rng, date(2026, 10, 25), date(2026, 11, 10))
                o = new_order(c, promised - timedelta(days=40), promised, "Delayed", cfdi=False)
                o["_noise_delay"] = True
            else:
                promised = rand_date(rng, date(2026, 10, 3), date(2026, 12, 18))
                ordered = promised - timedelta(days=rng.randint(25, 50))
                if promised <= TODAY:
                    # Sur's live go-lives this quarter happened before the PAC change (Oct 14)
                    if region == "Sur":
                        promised = rand_date(rng, date(2026, 10, 2), date(2026, 10, 13))
                    new_order(c, ordered, promised, "Fulfilled", promised,
                              cfdi=rng.random() < 0.6)
                else:
                    # Sur's upcoming go-lives don't need CFDI yet (POS-only phase)
                    new_order(c, ordered, promised, "Booked",
                              cfdi=(region != "Sur") and rng.random() < 0.6)

        # A cancelled order now and then
        c = rng.choice(cs)
        d = rand_date(rng, date(2026, 10, 5), date(2026, 11, 5))
        new_order(c, d - timedelta(days=30), d, "Cancelled", cfdi=False)

    # ── Targets: calibrated so the story's numbers come out ─────────────────
    def q4(o):
        return Q_START <= date.fromisoformat(o["PROMISED_DATE"]) <= Q_END

    def forecast(region):
        return sum(o["AMOUNT_MXN"] for o in orders if q4(o) and o["_customer"]["REGION"] == region
                   and o["STATUS"] in ("Fulfilled", "Booked"))

    targets = []
    for region in REGION_CUSTOMERS:
        if region == "Sur":
            target = money(forecast(region) / SUR_FORECAST_PCT / 10) * 10
            blocked_orders = [o for o in orders if o["_blocked_by_cfdi"]]
            need = target * (SUR_IF_UNBLOCKED_PCT - SUR_FORECAST_PCT)
            scale = need / sum(o["AMOUNT_MXN"] for o in blocked_orders)
            for o in blocked_orders:
                o["AMOUNT_MXN"] = money(o["AMOUNT_MXN"] * scale)
        else:
            target = money(forecast(region) / OTHER_REGION_PCT[region] / 10) * 10
        go_lives = sum(1 for o in orders if q4(o) and o["_customer"]["REGION"] == region
                       and o["STATUS"] != "Cancelled")
        targets.append({
            "TARGET_ID": f"{QUARTER}-{region}",
            "FISCAL_QUARTER": QUARTER,
            "REGION": region,
            "BOOKINGS_TARGET_MXN": target,
            "GO_LIVES_TARGET": go_lives if region != "Sur" else go_lives,
        })

    # ── Invoices: issued at go-live, net 30 ─────────────────────────────────
    invoices, inv_n = [], 0
    for o in orders:
        if o["STATUS"] != "Fulfilled":
            continue
        inv_n += 1
        issued = date.fromisoformat(o["DELIVERED_DATE"])
        due = issued + timedelta(days=30)
        if due >= TODAY:
            status, paid = ("Paid", issued + timedelta(days=rng.randint(5, 25))) if rng.random() < 0.4 else ("Open", None)
            if paid and paid > TODAY:
                status, paid = "Open", None
        elif rng.random() < 0.93:
            status, paid = "Paid", issued + timedelta(days=rng.randint(10, 40))
        else:
            status, paid = "Overdue", None
        invoices.append({
            "INVOICE_ID": f"INV-{inv_n:06d}",
            "ORDER_ID": o["ORDER_ID"],
            "CUSTOMER_ID": o["CUSTOMER_ID"],
            "ISSUE_DATE": issued.isoformat(),
            "DUE_DATE": due.isoformat(),
            "AMOUNT_MXN": o["AMOUNT_MXN"],
            "STATUS": status,
            "PAID_DATE": paid.isoformat() if paid else "",
        })

    # ── Jira ────────────────────────────────────────────────────────────────
    # PLAT: platform team. Keys are sequential, as Jira assigns them in a new project.
    plat_specs = [
        ("Actualizar dependencias del servicio de inventario", "Task", "Low", "Done"),
        ("Reporte de ventas por hora tarda más de 10 s", "Bug", "Medium", "Done"),
        ("Soporte para lector de códigos QR de pago", "Story", "Medium", "In Progress"),
        ("Impresora térmica 58mm corta el ticket", "Bug", "Medium", "Done"),
        ("Migrar colas de sincronización offline", "Task", "Medium", "In Progress"),
        ("Exportación de corte de caja a Excel", "Story", "Low", "To Do"),
        (CFDI_BLOCKER_SUMMARY, "Bug", "Highest", "In Progress"),
        ("Modo oscuro en terminal", "Story", "Low", "To Do"),
        ("Alertas de stock bajo por sucursal", "Story", "Medium", "To Do"),
        ("Error intermitente al sincronizar catálogo grande", "Bug", "High", "In Progress"),
    ]
    issues, epics = [], []
    blocker_key = None
    for i, (summary, itype, prio, status) in enumerate(plat_specs, start=1):
        key = f"PLAT-{i}"
        is_blocker = summary == CFDI_BLOCKER_SUMMARY
        if is_blocker:
            blocker_key = key
        created = date(2026, 10, 14) if is_blocker else rand_date(rng, date(2026, 8, 1), date(2026, 11, 5))
        issues.append({
            "ISSUE_KEY": key, "PROJECT": "PLAT", "EPIC_KEY": "", "CUSTOMER_ID": "",
            "SUMMARY": summary, "ISSUE_TYPE": itype, "PRIORITY": prio, "STATUS": status,
            "IS_BLOCKER": str(is_blocker).upper(), "BLOCKED_BY": "",
            "BLOCKED_REASON": "", "ASSIGNEE": rng.choice(PEOPLE),
            "CREATED_AT": f"{created.isoformat()} 10:00:00",
            "DUE_DATE": "",
            "RESOLVED_AT": f"{(created + timedelta(days=rng.randint(3, 20))).isoformat()} 17:00:00" if status == "Done" else "",
        })

    # IMPL: one Epic per go-live this quarter, five tasks each. Keys follow creation order.
    impl_n = 0
    q4_orders = sorted((o for o in orders if q4(o) and o["STATUS"] != "Cancelled"),
                       key=lambda o: (o["ORDER_DATE"], o["ORDER_ID"]))
    for o in q4_orders:
        c = o["_customer"]
        impl_n += 1
        epic_key = f"IMPL-{impl_n}"
        o["EPIC_KEY"] = epic_key
        promised = date.fromisoformat(o["PROMISED_DATE"])
        if o["STATUS"] == "Fulfilled":
            epic_status = "Done"
        elif o["_blocked_by_cfdi"] or o["_noise_delay"]:
            epic_status = "Blocked"
        else:
            epic_status = "In Progress" if (promised - TODAY).days < 30 else "To Do"
        epics.append({
            "EPIC_KEY": epic_key,
            "NAME": f"Go-live {c['DISPLAY_NAME']}",
            "CUSTOMER_ID": c["CUSTOMER_ID"],
            "ORDER_ID": o["ORDER_ID"],
            "REGION": c["REGION"],
            "TARGET_GO_LIVE": o["PROMISED_DATE"],
            "STATUS": epic_status,
        })
        ordered = date.fromisoformat(o["ORDER_DATE"])
        for t, task in enumerate(GO_LIVE_TASKS):
            impl_n += 1
            blocked_by, reason, is_blocker = "", "", False
            if epic_status == "Done":
                status = "Done"
            elif epic_status == "To Do":
                status = "To Do"
            elif o["_blocked_by_cfdi"]:
                status = "Done" if t < 2 else ("Blocked" if t == 2 else "To Do")
                if t == 2:
                    blocked_by, is_blocker = blocker_key, True
                    reason = f"No se puede timbrar la factura de prueba. Depende de {blocker_key}."
            elif o["_noise_delay"]:
                status = "Done" if t == 0 else ("Blocked" if t == 1 else "To Do")
                if t == 1:
                    is_blocker = True
                    reason = rng.choice(["Terminal en tránsito con el proveedor de hardware",
                                         "El cliente pidió reprogramar la instalación"])
            else:
                status = "Done" if t < 2 else ("In Progress" if t == 2 else "To Do")
            if not o["PRODUCT"].endswith("CFDI") and t == 2:
                task_summary = "Configurar impuestos y tickets"
            else:
                task_summary = GO_LIVE_TASKS[t]
            created = ordered + timedelta(days=2)
            issues.append({
                "ISSUE_KEY": f"IMPL-{impl_n}", "PROJECT": "IMPL", "EPIC_KEY": epic_key,
                "CUSTOMER_ID": c["CUSTOMER_ID"],
                "SUMMARY": f"{task_summary} · {c['DISPLAY_NAME']}",
                "ISSUE_TYPE": "Task",
                "PRIORITY": "High" if is_blocker else "Medium",
                "STATUS": status,
                "IS_BLOCKER": str(is_blocker).upper(),
                "BLOCKED_BY": blocked_by,
                "BLOCKED_REASON": reason,
                "ASSIGNEE": rng.choice(PEOPLE),
                "CREATED_AT": f"{created.isoformat()} 09:00:00",
                "DUE_DATE": (promised - timedelta(days=(len(GO_LIVE_TASKS) - 1 - t) * 3)).isoformat(),
                "RESOLVED_AT": f"{min(promised, TODAY).isoformat()} 18:00:00" if status == "Done" else "",
            })

    # ── Salesforce ──────────────────────────────────────────────────────────
    accounts = [{
        "Name": c["DISPLAY_NAME"],
        "ERP_Customer_Id__c": c["CUSTOMER_ID"],
        "Region__c": c["REGION"],
        "Industry": INDUSTRY[c["VERTICAL"]],
        "Type": "Customer",
        "NumberOfEmployees": STRATUM_EMPLOYEES.get(c["STRATUM"], 3),
        "BillingCity": c["MUNICIPALITY"],
        # Salesforce State/Country picklist codes (Mexico City is still "DF")
        "BillingStateCode": {"09": "DF", "14": "JA", "19": "NL", "31": "YU"}[c["STATE_CODE"]],
        "BillingCountryCode": "MX",
        "Description": f"{c['VERTICAL']} · {c['ACTIVITY_CLASS']}",
    } for c in customers]

    cases, case_n = [], 0

    def add_case(c, subject, priority, status, created, origin, description):
        nonlocal case_n
        case_n += 1
        cases.append({
            "MD26_Key__c": f"CASE-{case_n:04d}",
            "Account.ERP_Customer_Id__c": c["CUSTOMER_ID"],
            "Subject": subject, "Priority": priority, "Status": status,
            "Origin": origin, "Type": "Problem" if priority != "Low" else "Question",
            "CreatedDate": f"{created.isoformat()}T15:00:00.000Z",
            "ClosedDate": f"{(created + timedelta(days=rng.randint(1, 6))).isoformat()}T18:00:00.000Z" if status == "Closed" else "",
            "Description": description,
        })

    cfdi_subjects = [
        ("Ya pagué la implementación y la tienda no arranca", "High"),
        ("No puedo facturar desde Mostrador", "High"),
        ("Error de timbrado CFDI al cerrar la venta", "High"),
        ("¿Cuándo queda lista la facturación?", "Medium"),
        ("La factura de prueba sale con error del PAC", "Medium"),
        ("Seguimos vendiendo con notas a mano", "Medium"),
        ("Llevamos semanas esperando el go-live", "Medium"),
    ]
    blocked_customers = [o["_customer"] for o in orders if o["_blocked_by_cfdi"]]
    for c, (subject, prio) in zip(blocked_customers[:7], cfdi_subjects):
        add_case(c, subject, prio, "Working", rand_date(rng, date(2026, 10, 20), date(2026, 11, 12)),
                 rng.choice(["Phone", "Email", "Web"]),
                 "El cliente reporta que no puede emitir facturas CFDI 4.0 y la tienda no puede salir a producción.")

    routine = [
        ("¿Cómo doy de alta un producto nuevo?", "Low"),
        ("La impresora de tickets no imprime", "Medium"),
        ("Cambio de contraseña del cajero", "Low"),
        ("Reporte de ventas del día no cuadra", "Medium"),
        ("Agregar una segunda caja", "Low"),
        ("El lector de código de barras no responde", "Medium"),
    ]
    for _ in range(34):
        c = rng.choice(customers)
        subject, prio = rng.choice(routine)
        created = rand_date(rng, date(2026, 9, 1), date(2026, 11, 12))
        status = "Closed" if (TODAY - created).days > 7 or rng.random() < 0.6 else "New"
        add_case(c, subject, prio, status, created, rng.choice(["Phone", "Email", "Web", "Chat"]),
                 "Solicitud de soporte de rutina.")

    return customers, orders, invoices, targets, epics, issues, accounts, cases


def write(name, rows, fields=None):
    fields = fields or [k for k in rows[0] if not k.startswith("_")]
    with open(OUT / name, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    print(f"  {name:28s} {len(rows):5d} rows")


def main():
    establishments = json.load(open(sys.argv[1], encoding="utf-8"))
    customers, orders, invoices, targets, epics, issues, accounts, cases = build(establishments)
    OUT.mkdir(parents=True, exist_ok=True)
    print("Writing", OUT)
    write("erp_customers.csv", customers, [
        "CUSTOMER_ID", "DISPLAY_NAME", "ACTIVITY_CODE", "ACTIVITY_CLASS", "STRATUM",
        "STATE_CODE", "STATE_NAME", "MUNICIPALITY", "LATITUDE", "LONGITUDE",
        "SEGMENT", "REGION", "CUSTOMER_SINCE"])
    write("erp_sales_orders.csv", orders)
    write("erp_invoices.csv", invoices)
    write("erp_quarterly_targets.csv", targets)
    write("jira_epics.csv", epics)
    write("jira_issues.csv", issues)
    write("sf_accounts.csv", accounts)
    write("sf_cases.csv", cases)

    print(f"\nStory check ({QUARTER}, as of {TODAY}):")
    for t in targets:
        r = t["REGION"]
        in_q = [o for o in orders if o["_customer"]["REGION"] == r
                and Q_START <= date.fromisoformat(o["PROMISED_DATE"]) <= Q_END]
        rec = sum(o["AMOUNT_MXN"] for o in in_q if o["STATUS"] == "Fulfilled")
        fc = sum(o["AMOUNT_MXN"] for o in in_q if o["STATUS"] in ("Fulfilled", "Booked"))
        dl = sum(o["AMOUNT_MXN"] for o in in_q if o["STATUS"] == "Delayed")
        print(f"  {r:10s} target {t['BOOKINGS_TARGET_MXN']:>12,.0f}  recognized {rec:>12,.0f}"
              f"  forecast {fc / t['BOOKINGS_TARGET_MXN']:6.1%}  if delays clear {(fc + dl) / t['BOOKINGS_TARGET_MXN']:6.1%}")
    blocked = [o for o in orders if o["_blocked_by_cfdi"]]
    sur = next(t for t in targets if t["REGION"] == "Sur")
    sur_fc = sum(o["AMOUNT_MXN"] for o in orders if o["_customer"]["REGION"] == "Sur"
                 and Q_START <= date.fromisoformat(o["PROMISED_DATE"]) <= Q_END
                 and o["STATUS"] in ("Fulfilled", "Booked"))
    print(f"  Sur if only the CFDI blocker clears: "
          f"{(sur_fc + sum(o['AMOUNT_MXN'] for o in blocked)) / sur['BOOKINGS_TARGET_MXN']:.1%}")
    print(f"  CFDI-blocked go-lives: {len(blocked)} · MXN {sum(o['AMOUNT_MXN'] for o in blocked):,.0f}"
          f" · with open cases: {sum(1 for c in cases if c['Status'] == 'Working')}")


if __name__ == "__main__":
    main()
