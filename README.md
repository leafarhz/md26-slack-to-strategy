# From Slack to Strategy

**Building an Enterprise Agentforce Architecture with Data Cloud Zero Copy**

México Dreamin' 2026 · Friday, November 20, 2026 · Mexico City
Speaker: Rafael Hernández — Salesforce MVP Hall of Fame

> The session is presented in Spanish. The code, comments and this README are in English.

---

## The question

> **"Are we on track this quarter?"**

Answering it usually means opening a BI dashboard, three Slack channels, the
support queue and the engineering backlog, then reconciling everything by hand.
The answer is slow, stale by the time it's shared, and trapped in one person's
head.

This repo is a reusable reference implementation of the pattern from the talk:
ask the question in Slack, and let an Agentforce agent answer it from data that
stays where it lives.

## The architecture

```
Business user
     │
     ▼
   Slack
     │
     ▼
Agentforce agent ──── interprets intent, picks an action
     │
     ▼
Apex actions ──────── controlled, testable execution
     │
     ▼
Data Cloud SQL ────── one query layer over a unified model
     │
     ▼
Zero Copy federation
   ┌─────┼──────────┐
  ERP  Support/CRM  Jira      ← each remains its own system of record
```

**The agent does not own or move the data.** Adding a new source becomes a
connector decision, not an integration project.

## Three lessons

1. **Security is a permission chain you cannot skip.**
2. **Zero Copy can reduce time-to-prototype from weeks to days.**
3. **Measure hours of human work recovered, not cool AI features.**

## What's in this repo

| Path | What |
|---|---|
| `force-app/` | Agent, Apex actions and metadata for the demo org |
| `demo/data/` | Synthetic ERP, support and Jira data — no real company data |
| `docs/architecture/` | Reference architecture and permission-chain walkthrough |
| `slides/` | Session deck (published after the event) |
| `scripts/` | Org setup and data load scripts |

> **About the demo.** The pattern comes from a real enterprise build. This repo
> is a clean, public re-implementation on a Developer Edition org with synthetic
> data, so you can deploy and adapt it yourself. Where something in the talk is
> production-only or representative, the docs say so.

## Status

🚧 Under construction for México Dreamin' 2026.

## License

MIT
