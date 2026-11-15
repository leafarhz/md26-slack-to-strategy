#!/usr/bin/env bash
# Second demo persona: José Pech, sales rep who should only see the Península.
# Same agent, same question, different answer, driven only by Salesforce sharing.
#
# Usage: JOSE_EMAIL=you+jose@example.com scripts/setup-jose.sh [org-alias]
# JOSE_EMAIL must match the Slack account José logs in with.
set -euo pipefail

ORG="${1:-md26}"
EMAIL="${JOSE_EMAIL:?set JOSE_EMAIL to the email of José's Slack account}"
USERNAME="${JOSE_USERNAME:-jose.pech@md26-changarro.demo}"
TMP="$(mktemp -d)"

echo "1/5 Account, Case and Opportunity sharing -> Private"
sf project deploy start -o "$ORG" --metadata-dir demo/sharing --wait 20

echo "2/5 Create José (Standard User)"
PROFILE=$(sf data query -o "$ORG" -q "SELECT Id FROM Profile WHERE Name='Standard User'" --json \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['records'][0]['Id'])")
sf data create record -o "$ORG" -s User -v "Username='$USERNAME' FirstName='José' LastName='Pech' Alias='jpech' \
  Email='$EMAIL' ProfileId='$PROFILE' TimeZoneSidKey='America/Mexico_City' LocaleSidKey='es_MX' \
  LanguageLocaleKey='es_MX' EmailEncodingKey='UTF-8' Title='Ejecutivo de ventas, Península'"
JOSE=$(sf data query -o "$ORG" -q "SELECT Id FROM User WHERE Username='$USERNAME'" --json \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['records'][0]['Id'])")

echo "3/5 Agent access and Data Cloud"
sf org assign permset -o "$ORG" -n MD26_Mostrador_Ops -b "$USERNAME"
sf org assign permset -o "$ORG" -n GenieUserEnhancedSecurity -b "$USERNAME"

echo "4/5 José owns the Península accounts and their cases"
for OBJ in Account Case; do
  WHERE=$([ "$OBJ" = Account ] && echo "Region__c" || echo "Account.Region__c")
  sf data query -o "$ORG" -q "SELECT Id FROM $OBJ WHERE $WHERE='Península'" -r csv \
    | sed "1s/.*/Id,OwnerId/; 2,\$s/\$/,$JOSE/" > "$TMP/$OBJ.csv"
  sf data update bulk -o "$ORG" -s "$OBJ" -f "$TMP/$OBJ.csv" --wait 10
done

echo "5/5 Email José a password link"
echo "System.resetPassword('$JOSE', true);" > "$TMP/reset.apex"
sf apex run -o "$ORG" -f "$TMP/reset.apex" > /dev/null

echo "Done. Invite $EMAIL to the Slack workspace, set the password from the email, then ask the agent as José."
