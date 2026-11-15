#!/usr/bin/env bash
# From Slack to Strategy: set up a Salesforce org for the Mostrador Ops demo.
#
# Usage: scripts/setup-org.sh <org-alias>
#
# Needs: a Developer Edition with Agentforce + Data Cloud that can create Employee agents
# (if the Slack templates in Agentforce Builder fail to commit with "no access to agent
# templates", the org lacks the license; get a fresh one), the Salesforce CLI, Python 3,
# and Slack connected to the org (Setup > Slack) because the agent declares a Slack connection.
#
# Snowflake, Jira and MuleSoft live outside the org: see snowflake/ and mulesoft/.
# Data Cloud (connector + data streams) is configured by hand afterwards; the steps are
# printed at the end.

set -euo pipefail

ORG="${1:?Usage: scripts/setup-org.sh <org-alias>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/force-app/main/default"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

step() { printf '\n▶ %s\n' "$*"; }

step "1/6 Fields and Apex"
sf project deploy start -o "$ORG" -d "$SRC/objects" -d "$SRC/classes" --wait 15

step "2/6 Agent (publish + activate). Apex must exist first"
sf agent validate authoring-bundle -o "$ORG" --api-name Mostrador_Ops
sf agent publish authoring-bundle -o "$ORG" --api-name Mostrador_Ops
sf agent activate -o "$ORG" --api-name Mostrador_Ops

step "3/6 Permission set (references the agent, so it goes after it)"
sf project deploy start -o "$ORG" -d "$SRC/permissionsets" --wait 15
sf org assign permset -o "$ORG" -n MD26_Mostrador_Ops || true   # already assigned is fine

step "4/6 Accounts"
sf data upsert bulk -o "$ORG" -s Account -f "$ROOT/demo/data/sf_accounts.csv" -i ERP_Customer_Id__c --wait 10

step "5/6 Cases (CreatedDate/ClosedDate cannot be set without audit-field permissions; dropped)"
python3 - "$ROOT/demo/data/sf_cases.csv" "$TMP/cases.csv" <<'PY'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1], encoding="utf-8")))
drop = {"CreatedDate", "ClosedDate", "Type"}
for r in rows:
    r["Origin"] = {"Chat": "Web"}.get(r["Origin"], r["Origin"])
fields = [f for f in rows[0] if f not in drop]
w = csv.DictWriter(open(sys.argv[2], "w", newline="", encoding="utf-8"), fieldnames=fields,
                   extrasaction="ignore", lineterminator="\n")
w.writeheader(); w.writerows(rows)
PY
sf data upsert bulk -o "$ORG" -s Case -f "$TMP/cases.csv" -i MD26_Key__c --wait 10

step "6/6 Apex tests"
sf apex run test -o "$ORG" -n MostradorOpsServiceTest --wait 10

cat <<'EOF'

✅ Org ready. Now, by hand, in Data Cloud (Setup > Data Cloud Setup):

  1. Other Connectors > New > Snowflake (NOT "File Federation")
       Account URL   <account>.snowflakecomputing.com   (no https://)
       Username      MD26_DATACLOUD_SVC                 (snowflake/01_setup.sql)
       Auth          Private Key Pair; paste the key body without BEGIN/END lines
       Warehouse     MD26_WH
       Leverage Snowflake Data Unload: OFF
  2. Data Streams > New > Snowflake > MD26_DB, one stream with 7 objects:
       ERP.CUSTOMERS          ERP_Customers          Profile     CUSTOMER_ID
       ERP.INVOICES           ERP_Invoices           Engagement  INVOICE_ID  (ISSUE_DATE)
       ERP.QUARTERLY_TARGETS  ERP_Quarterly_Targets  Other       TARGET_ID
       ERP.SALES_ORDERS       ERP_Sales_Orders       Engagement  ORDER_ID    (ORDER_DATE)
       JIRA.EPICS             Jira_Epics             Other       EPIC_KEY
       JIRA.ISSUES            Jira_Issues            Other       ISSUE_KEY
       MARKET.ESTABLISHMENTS  DENUE_Establishments   Other       DENUE_ID
     Select ALL fields on every object. Acceleration: OFF (keeps queries live, i.e. Zero Copy).
  3. Slack: install the agent from Slack (Organization settings > Salesforce > Agentforce,
     or Admin > Manage Agentforce on non-Grid workspaces). Slack users map by email.
EOF
