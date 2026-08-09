-- Run once against the target database before the first sync.
-- Cursor values are opaque tokens (not guaranteed to be GUIDs), so they're
-- stored as NVARCHAR rather than UNIQUEIDENTIFIER.

IF OBJECT_ID('dbo.ApiCursorResults', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ApiCursorResults
    (
        Id              BIGINT IDENTITY(1,1) NOT NULL PRIMARY KEY,
        BatchId         UNIQUEIDENTIFIER      NOT NULL,
        RequestCursor   NVARCHAR(400)         NULL,
        ResponseCursor  NVARCHAR(400)         NULL,
        ItemJson        NVARCHAR(MAX)         NOT NULL,
        -- Dedupe support: re-running the same request cursor (e.g. after a
        -- failure, via -Resume) must not insert the same items twice.
        -- NULL RequestCursor (the very first call) is folded to a fixed
        -- sentinel because SQL Server treats NULLs as distinct in a unique index.
        DedupeCursor    AS (ISNULL(RequestCursor, N'')) PERSISTED,
        ItemHash        AS (HASHBYTES('SHA2_256', ItemJson)) PERSISTED,
        RetrievedAtUtc  DATETIME2(3)          NOT NULL CONSTRAINT DF_ApiCursorResults_RetrievedAtUtc DEFAULT SYSUTCDATETIME()
    );

    CREATE INDEX IX_ApiCursorResults_BatchId ON dbo.ApiCursorResults (BatchId);
    CREATE INDEX IX_ApiCursorResults_ResponseCursor ON dbo.ApiCursorResults (ResponseCursor);
    CREATE UNIQUE INDEX UX_ApiCursorResults_Dedupe ON dbo.ApiCursorResults (DedupeCursor, ItemHash);
END;

IF OBJECT_ID('dbo.ApiCursorLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.ApiCursorLog
    (
        BatchId         UNIQUEIDENTIFIER  NOT NULL PRIMARY KEY,
        RequestCursor   NVARCHAR(400)     NULL,
        ResponseCursor  NVARCHAR(400)     NULL,
        ItemCount       INT               NOT NULL,
        HttpStatusCode  INT               NULL,
        CalledAtUtc     DATETIME2(3)      NOT NULL CONSTRAINT DF_ApiCursorLog_CalledAtUtc DEFAULT SYSUTCDATETIME(),
        ErrorMessage    NVARCHAR(MAX)     NULL
    );
END;
