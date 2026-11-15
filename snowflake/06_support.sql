-- From Slack to Strategy — support tickets still in Zendesk (migration to Salesforce half done)
-- Region Sur still works in Zendesk; everyone else is already in Salesforce Service Cloud.
-- Demo: synthetic tickets in Zendesk's export shape. Production: a Zendesk → warehouse pipeline
-- (MuleSoft, Fivetran…) and the same Zero Copy read. Adding this source was a connector decision.

USE ROLE ACCOUNTADMIN;

CREATE SCHEMA IF NOT EXISTS MD26_DB.SUPPORT COMMENT = 'Zendesk tickets (pre-migration)';

CREATE TABLE IF NOT EXISTS MD26_DB.SUPPORT.ZENDESK_TICKETS (
  TICKET_ID                 NUMBER(10)    NOT NULL PRIMARY KEY,
  ORGANIZATION_EXTERNAL_ID  VARCHAR(20),               -- = ERP CUSTOMER_ID (set when the org was created)
  ORGANIZATION_NAME         VARCHAR(255),              -- Zendesk's own spelling, e.g. "TAQ PUENTE"
  SUBJECT                   VARCHAR(500),
  PRIORITY                  VARCHAR(10),               -- urgent | high | normal | low
  STATUS                    VARCHAR(10),               -- new | open | pending | solved | closed
  CHANNEL                   VARCHAR(20),               -- voice | email | web | chat
  CREATED_AT                TIMESTAMP_NTZ,
  SOLVED_AT                 TIMESTAMP_NTZ,
  LAST_MODIFIED             TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

GRANT USAGE ON SCHEMA MD26_DB.SUPPORT TO ROLE MD26_LOADER;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES    IN SCHEMA MD26_DB.SUPPORT TO ROLE MD26_LOADER;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON FUTURE TABLES IN SCHEMA MD26_DB.SUPPORT TO ROLE MD26_LOADER;
GRANT USAGE ON SCHEMA MD26_DB.SUPPORT TO ROLE MD26_ZEROCOPY_READER;
GRANT SELECT ON TABLE MD26_DB.SUPPORT.ZENDESK_TICKETS TO ROLE MD26_ZEROCOPY_READER;
