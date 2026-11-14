-- From Slack to Strategy — staging for the MuleSoft Jira sync (mulesoft/jira-snowflake-sync)
-- MuleSoft fills the *_STAGE tables, then swaps them into EPICS / ISSUES with an atomic
-- INSERT OVERWRITE, so a Zero Copy query never sees a half-synced table.
-- The reader role gets nothing on staging (future grants on JIRA are revoked below).

USE ROLE ACCOUNTADMIN;

CREATE TABLE IF NOT EXISTS MD26_DB.JIRA.EPICS_STAGE  LIKE MD26_DB.JIRA.EPICS;
CREATE TABLE IF NOT EXISTS MD26_DB.JIRA.ISSUES_STAGE LIKE MD26_DB.JIRA.ISSUES;

REVOKE SELECT ON TABLE MD26_DB.JIRA.EPICS_STAGE  FROM ROLE MD26_ZEROCOPY_READER;
REVOKE SELECT ON TABLE MD26_DB.JIRA.ISSUES_STAGE FROM ROLE MD26_ZEROCOPY_READER;
