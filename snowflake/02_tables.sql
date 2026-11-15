-- From Slack to Strategy — systems of record
-- Fictional company: "Changarro", a point-of-sale software vendor selling to
-- Mexican small businesses. Customer profiles are shaped from INEGI DENUE
-- (industry, size, location); business names are fictional.
--
-- CUSTOMER_ID is the shared key across ERP, Jira and Salesforce (Account.ERP_Customer_Id__c),
-- which is what lets Data Cloud unify the three silos without moving them.

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE MD26_WH;

-- ───────────────────────────── ERP ─────────────────────────────

CREATE TABLE IF NOT EXISTS MD26_DB.ERP.CUSTOMERS (
  CUSTOMER_ID      VARCHAR(20)   NOT NULL PRIMARY KEY,  -- e.g. MX-000123
  DISPLAY_NAME     VARCHAR(255)  NOT NULL,              -- fictional
  DENUE_ID         VARCHAR(20),                         -- source establishment id
  ACTIVITY_CODE    VARCHAR(10),                         -- SCIAN code
  ACTIVITY_CLASS   VARCHAR(255),                        -- e.g. Farmacias sin minisúper
  STRATUM          VARCHAR(50),                         -- employee range
  STATE_CODE       VARCHAR(2),
  STATE_NAME       VARCHAR(100),
  MUNICIPALITY     VARCHAR(150),
  LATITUDE         NUMBER(9,6),
  LONGITUDE        NUMBER(9,6),
  SEGMENT          VARCHAR(20),                         -- SMB | MidMarket
  REGION           VARCHAR(20),                         -- Centro | Norte | Occidente | Península
  CUSTOMER_SINCE   DATE,
  SOURCE_SYSTEM    VARCHAR(30)   DEFAULT 'MULESOFT_DENUE',
  LAST_MODIFIED    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS MD26_DB.ERP.SALES_ORDERS (
  ORDER_ID         VARCHAR(20)   NOT NULL PRIMARY KEY,  -- SO-2026-00001
  CUSTOMER_ID      VARCHAR(20)   NOT NULL,
  ORDER_DATE       DATE          NOT NULL,
  FISCAL_QUARTER   VARCHAR(7)    NOT NULL,              -- FY26-Q4
  PRODUCT          VARCHAR(100),                        -- Changarro POS, Inventario, Facturación CFDI…
  AMOUNT_MXN       NUMBER(14,2)  NOT NULL,
  STATUS           VARCHAR(20)   NOT NULL,              -- Booked | Fulfilled | Delayed | Cancelled
  PROMISED_DATE    DATE,
  DELIVERED_DATE   DATE,
  EPIC_KEY         VARCHAR(20),                         -- Jira go-live epic (IMPL-n)
  LAST_MODIFIED    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS MD26_DB.ERP.INVOICES (
  INVOICE_ID       VARCHAR(20)   NOT NULL PRIMARY KEY,
  ORDER_ID         VARCHAR(20)   NOT NULL,
  CUSTOMER_ID      VARCHAR(20)   NOT NULL,
  ISSUE_DATE       DATE          NOT NULL,
  DUE_DATE         DATE          NOT NULL,
  AMOUNT_MXN       NUMBER(14,2)  NOT NULL,
  STATUS           VARCHAR(20)   NOT NULL,              -- Paid | Open | Overdue
  PAID_DATE        DATE,
  LAST_MODIFIED    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS MD26_DB.ERP.QUARTERLY_TARGETS (
  TARGET_ID        VARCHAR(30)   NOT NULL PRIMARY KEY,  -- FY26-Q4-Centro
  FISCAL_QUARTER   VARCHAR(7)    NOT NULL,
  REGION           VARCHAR(20)   NOT NULL,
  BOOKINGS_TARGET_MXN  NUMBER(14,2) NOT NULL,
  GO_LIVES_TARGET  NUMBER(6)     NOT NULL,
  LAST_MODIFIED    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

-- ───────────────────────────── JIRA ─────────────────────────────

-- One Epic per customer go-live in the IMPL project.
CREATE TABLE IF NOT EXISTS MD26_DB.JIRA.EPICS (
  EPIC_KEY         VARCHAR(20)   NOT NULL PRIMARY KEY,  -- IMPL-12
  NAME             VARCHAR(255)  NOT NULL,
  CUSTOMER_ID      VARCHAR(20)   NOT NULL,
  ORDER_ID         VARCHAR(20),
  REGION           VARCHAR(20),
  TARGET_GO_LIVE   DATE,
  STATUS           VARCHAR(20),                         -- To Do | In Progress | Blocked | Done
  LAST_MODIFIED    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS MD26_DB.JIRA.ISSUES (
  ISSUE_KEY        VARCHAR(20)   NOT NULL PRIMARY KEY,  -- IMPL-57, PLAT-42
  PROJECT          VARCHAR(10)   NOT NULL,              -- IMPL | PLAT
  EPIC_KEY         VARCHAR(20),                         -- parent epic (IMPL only)
  CUSTOMER_ID      VARCHAR(20),                         -- null for platform issues
  SUMMARY          VARCHAR(500)  NOT NULL,
  ISSUE_TYPE       VARCHAR(20),                         -- Task | Bug | Story
  PRIORITY         VARCHAR(20),                         -- Highest | High | Medium | Low
  STATUS           VARCHAR(20),                         -- To Do | In Progress | Blocked | Done
  IS_BLOCKER       BOOLEAN       DEFAULT FALSE,
  BLOCKED_BY       VARCHAR(20),                         -- issue key of the blocker, e.g. PLAT-42
  BLOCKED_REASON   VARCHAR(500),
  ASSIGNEE         VARCHAR(100),                        -- fictional
  CREATED_AT       TIMESTAMP_NTZ,
  DUE_DATE         DATE,
  RESOLVED_AT      TIMESTAMP_NTZ,
  LAST_MODIFIED    TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
