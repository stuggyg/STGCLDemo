-- Run once against the target database before the first sync.

IF OBJECT_ID('dbo.ApiCursorResults', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ApiCursorResults
    (
        Id                  BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        BatchId             UNIQUEIDENTIFIER     NOT NULL,
        RequestCursorGuid   UNIQUEIDENTIFIER     NULL,
        ResponseCursorGuid  UNIQUEIDENTIFIER     NULL,
        ItemJson            NVARCHAR(MAX)        NOT NULL,
        -- Dedupe support: re-running the same request cursor (e.g. after a
        -- failure, via -Resume) must not insert the same items twice.
        -- NULL RequestCursorGuid (the very first call) is folded to a fixed
        -- sentinel because SQL Server treats NULLs as distinct in a unique index.
        DedupeCursor        AS (ISNULL(RequestCursorGuid, '00000000-0000-0000-0000-000000000000')) PERSISTED,
        ItemHash            AS (HASHBYTES('SHA2_256', ItemJson)) PERSISTED,
        RetrievedAtUtc      DATETIME2(3)         NOT NULL CONSTRAINT DF_ApiCursorResults_RetrievedAtUtc DEFAULT SYSUTCDATETIME()
    );

    CREATE INDEX IX_ApiCursorResults_BatchId ON dbo.ApiCursorResults (BatchId);
    CREATE INDEX IX_ApiCursorResults_ResponseCursorGuid ON dbo.ApiCursorResults (ResponseCursorGuid);
    CREATE UNIQUE INDEX UX_ApiCursorResults_Dedupe ON dbo.ApiCursorResults (DedupeCursor, ItemHash);
END;

IF OBJECT_ID('dbo.ApiCursorLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ApiCursorLog
    (
        BatchId             UNIQUEIDENTIFIER  NOT NULL PRIMARY KEY,
        RequestCursorGuid   UNIQUEIDENTIFIER  NULL,
        ResponseCursorGuid  UNIQUEIDENTIFIER  NULL,
        ItemCount           INT               NOT NULL,
        HttpStatusCode      INT               NULL,
        CalledAtUtc         DATETIME2(3)      NOT NULL CONSTRAINT DF_ApiCursorLog_CalledAtUtc DEFAULT SYSUTCDATETIME(),
        ErrorMessage        NVARCHAR(MAX)     NULL
    );
END;
