#!/usr/bin/env python3
"""Seed a Jira Cloud site with the Changarro demo backlog (demo/data/jira_*.csv).

One-time setup, not an integration: after this, Jira is the system of record and
MuleSoft syncs it to Snowflake.

Modelled the way Jira teams actually work:
  - PLAT  platform team. PLAT-7 is the CFDI blocker.
  - IMPL  one Epic per customer go-live, five Tasks under it.
  - "Blocked" is not a status: it is an "is blocked by" link (PLAT-7 blocks IMPL-n)
    plus the Flag. Move PLAT-7 to Done and the go-lives are no longer blocked.
  - CUSTOMER_ID and REGION travel as labels; the original open date goes in Start date
    (Jira always stamps Created as "now").

Issues are created in generator order so Jira assigns the same keys the ERP references.
Requires two empty company-managed software projects, PLAT and IMPL.

Usage: python3 scripts/seed_jira.py .private/jira.env
"""

import base64
import csv
import json
import sys
import time
import urllib.error
import urllib.request
from collections import defaultdict
from pathlib import Path

DATA = Path(__file__).resolve().parent.parent / "demo" / "data"
FLAGGED = "customfield_10021"
START_DATE = "customfield_10015"


def load_env(path):
    env = {}
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


class Jira:
    def __init__(self, url, email, token):
        self.url = url.rstrip("/")
        self.auth = "Basic " + base64.b64encode(f"{email}:{token}".encode()).decode()

    def call(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        for attempt in range(6):
            req = urllib.request.Request(self.url + path, data=data, method=method, headers={
                "Authorization": self.auth, "Accept": "application/json",
                "Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    raw = r.read()
                    return json.loads(raw) if raw else None
            except urllib.error.HTTPError as e:
                if e.code == 429 or e.code >= 500:
                    time.sleep(int(e.headers.get("Retry-After", 2 ** attempt)))
                    continue
                raise RuntimeError(f"{method} {path} → {e.code}: {e.read().decode()[:500]}")
        raise RuntimeError(f"{method} {path} → gave up after retries")


def adf(*paragraphs):
    return {"type": "doc", "version": 1, "content": [
        {"type": "paragraph", "content": [{"type": "text", "text": p}]} for p in paragraphs if p]}


def issue_fields(project, itype, summary, priority, labels, start, due, description, parent=None):
    f = {
        "project": {"key": project},
        "issuetype": {"name": itype},
        "summary": summary[:250],
        "priority": {"name": priority},
        "labels": [l.replace(" ", "_") for l in labels if l],
        "description": description,
    }
    if start:
        f[START_DATE] = start[:10]
    if due:
        f["duedate"] = due[:10]
    if parent:
        f["parent"] = {"key": parent}
    return f


def main():
    env = load_env(sys.argv[1])
    jira = Jira(env["JIRA_URL"], env["JIRA_EMAIL"], env["JIRA_API_TOKEN"])

    for key in ("PLAT", "IMPL"):
        found = jira.call("POST", "/rest/api/3/search/jql",
                          {"jql": f"project = {key}", "maxResults": 1, "fields": ["key"]})
        if found.get("issues"):
            sys.exit(f"Project {key} already has issues; refusing to seed twice.")

    issues = list(csv.DictReader(open(DATA / "jira_issues.csv", encoding="utf-8")))
    epics = list(csv.DictReader(open(DATA / "jira_epics.csv", encoding="utf-8")))
    region_of = {e["EPIC_KEY"]: e["REGION"] for e in epics}
    tasks_by_epic = defaultdict(list)
    for i in issues:
        if i["PROJECT"] == "IMPL":
            tasks_by_epic[i["EPIC_KEY"]].append(i)

    created = []  # (expected_key, actual_key, target_status)

    def describe(i):
        lines = [f"Responsable: {i['ASSIGNEE']}"]
        if i["BLOCKED_REASON"]:
            lines.append(f"Bloqueo: {i['BLOCKED_REASON']}")
        return adf(*lines)

    # PLAT: one bulk call keeps creation order.
    plat = [i for i in issues if i["PROJECT"] == "PLAT"]
    res = jira.call("POST", "/rest/api/3/issue/bulk", {"issueUpdates": [{"fields": issue_fields(
        "PLAT", i["ISSUE_TYPE"], i["SUMMARY"], i["PRIORITY"], [],
        i["CREATED_AT"], i["DUE_DATE"], describe(i))} for i in plat]})
    if res.get("errors"):
        sys.exit(f"PLAT bulk errors: {res['errors']}")
    created += [(i["ISSUE_KEY"], r["key"], i["STATUS"]) for i, r in zip(plat, res["issues"])]
    print(f"PLAT: {len(plat)} issues")

    # IMPL: epic, then its five tasks, in generator order.
    for n, e in enumerate(epics, 1):
        r = jira.call("POST", "/rest/api/3/issue", {"fields": issue_fields(
            "IMPL", "Epic", e["NAME"], "Medium", [e["CUSTOMER_ID"], e["REGION"]],
            None, e["TARGET_GO_LIVE"], adf(f"Orden ERP: {e['ORDER_ID']}", f"Región: {e['REGION']}"))})
        epic_status = "Done" if e["STATUS"] == "Done" else ("To Do" if e["STATUS"] == "To Do" else "In Progress")
        created.append((e["EPIC_KEY"], r["key"], epic_status))
        tasks = tasks_by_epic[e["EPIC_KEY"]]
        res = jira.call("POST", "/rest/api/3/issue/bulk", {"issueUpdates": [{"fields": issue_fields(
            "IMPL", "Task", t["SUMMARY"], t["PRIORITY"], [t["CUSTOMER_ID"], region_of[e["EPIC_KEY"]]],
            t["CREATED_AT"], t["DUE_DATE"], describe(t), parent=r["key"])} for t in tasks]})
        if res.get("errors"):
            sys.exit(f"IMPL bulk errors under {r['key']}: {res['errors']}")
        # "Blocked" lives in links and the flag; the workflow status stays To Do.
        created += [(t["ISSUE_KEY"], x["key"], "To Do" if t["STATUS"] == "Blocked" else t["STATUS"])
                    for t, x in zip(tasks, res["issues"])]
        if n % 10 == 0:
            print(f"IMPL: {n}/{len(epics)} epics")

    mismatches = [(exp, act) for exp, act, _ in created if exp != act]
    if mismatches:
        sys.exit(f"Key mismatch (first 5): {mismatches[:5]}. Delete the issues, empty the projects and re-run.")
    print(f"Keys match the ERP: {len(created)} issues")

    # Statuses
    transitions = {}
    for _, key, status in created:
        if status == "To Do":
            continue
        if not transitions:
            ts = jira.call("GET", f"/rest/api/3/issue/{key}/transitions")["transitions"]
            transitions = {t["to"]["name"]: t["id"] for t in ts}
        jira.call("POST", f"/rest/api/3/issue/{key}/transitions", {"transition": {"id": transitions[status]}})
    print("Statuses set")

    # Blocks: links to PLAT-7, flag on everything blocked (including ordinary hardware delays)
    flag_ok = True
    for i in issues:
        if i["IS_BLOCKER"] != "TRUE" or i["PROJECT"] != "IMPL":
            continue
        if i["BLOCKED_BY"]:
            # Jira's create-link API is counter-intuitive: inwardIssue gets the *outward*
            # description. This reads "PLAT-7 blocks IMPL-n" / "IMPL-n is blocked by PLAT-7".
            jira.call("POST", "/rest/api/3/issueLink", {
                "type": {"name": "Blocks"},
                "inwardIssue": {"key": i["BLOCKED_BY"]},
                "outwardIssue": {"key": i["ISSUE_KEY"]}})
        if flag_ok:
            try:
                jira.call("PUT", f"/rest/api/3/issue/{i['ISSUE_KEY']}",
                          {"fields": {FLAGGED: [{"value": "Impediment"}]}})
            except RuntimeError as err:
                flag_ok = False
                print(f"Flag not settable on this screen, skipping flags: {err}")
        jira.call("POST", f"/rest/api/3/issue/{i['ISSUE_KEY']}/comment",
                  {"body": adf(i["BLOCKED_REASON"])})
    print("Blockers linked" + (" and flagged" if flag_ok else ""))


if __name__ == "__main__":
    main()
