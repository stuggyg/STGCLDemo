-- Example queries against dbo.ApiCursorResults.ItemJson using OPENJSON.
-- Assumes items shaped like { "Message": "This is a demo", "Device": "Demo" }.

-- 1. Discover what fields actually show up (default OPENJSON: one row per
--    property, generic key/value/type columns). Useful before you know the
--    exact schema, or to spot fields that appear only on some items.
SELECT DISTINCT j.[key]
FROM dbo.ApiCursorResults r
CROSS APPLY OPENJSON(r.ItemJson) j;

-- 2. Same default mode, showing actual key/value pairs for a sample of rows.
SELECT TOP 50 r.Id, r.BatchId, j.[key], j.[value], j.[type]
FROM dbo.ApiCursorResults r
CROSS APPLY OPENJSON(r.ItemJson) j
ORDER BY r.Id;

-- 3. Shredded into typed columns (WITH clause) - use once you know the
--    fields you care about. This is the shape you'd normally query/report on.
SELECT
    r.Id,
    r.BatchId,
    r.RequestCursor,
    r.ResponseCursor,
    r.RetrievedAtUtc,
    j.Message,
    j.Device
FROM dbo.ApiCursorResults r
CROSS APPLY OPENJSON(r.ItemJson)
    WITH (
        Message NVARCHAR(4000) '$.Message',
        Device  NVARCHAR(200)  '$.Device'
    ) j;

-- 4. Filtered example: all "Demo" device items retrieved in the last day.
SELECT
    r.Id,
    j.Message,
    j.Device,
    r.RetrievedAtUtc
FROM dbo.ApiCursorResults r
CROSS APPLY OPENJSON(r.ItemJson)
    WITH (
        Message NVARCHAR(4000) '$.Message',
        Device  NVARCHAR(200)  '$.Device'
    ) j
WHERE j.Device = 'Demo'
  AND r.RetrievedAtUtc >= DATEADD(DAY, -1, SYSUTCDATETIME());

-- 5. Batch-level rollup: item counts per API call, joined with the call log.
SELECT
    l.BatchId,
    l.RequestCursor,
    l.ResponseCursor,
    l.ItemCount AS LoggedItemCount,
    COUNT(r.Id) AS StoredItemCount,
    l.CalledAtUtc
FROM dbo.ApiCursorLog l
LEFT JOIN dbo.ApiCursorResults r ON r.BatchId = l.BatchId
GROUP BY l.BatchId, l.RequestCursor, l.ResponseCursor, l.ItemCount, l.CalledAtUtc
ORDER BY l.CalledAtUtc;
