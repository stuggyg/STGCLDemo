-- Run once against the target database before the first ADAudit Plus pull.
-- Raw landing only: one row per report page, holding the response body exactly
-- as ADAudit Plus sent it. No shredding, typing, or dedupe happens here - that
-- is a later step reading out of this table.

IF OBJECT_ID('dbo.stg_adap_events_raw', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.stg_adap_events_raw
    (
        id           BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        -- One GUID per script run, stamped on every page of that run, so a
        -- partial run can be identified and resumed or discarded wholesale.
        run_id       UNIQUEIDENTIFIER      NOT NULL,
        report_name  NVARCHAR(200)         NULL,
        page_no      INT                   NOT NULL,
        -- Verbatim response string. NVARCHAR(MAX) because a page of reportData
        -- routinely exceeds the 4000-char in-row limit.
        payload      NVARCHAR(MAX)         NOT NULL,
        ingested_at  DATETIME2(3)          NOT NULL
            CONSTRAINT DF_stg_adap_events_raw_ingested_at DEFAULT SYSUTCDATETIME()
    );

    -- Supports "what did run X already land?" for resume, and ordering pages
    -- back into sequence at shred time. Deliberately NOT unique: re-running a
    -- page after a failure is allowed to land a second copy, since the brief
    -- defers all dedupe to the shred step.
    CREATE INDEX IX_stg_adap_events_raw_run_page
        ON dbo.stg_adap_events_raw (run_id, page_no);
END;
