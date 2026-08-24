USE master;
GO

DROP PROCEDURE IF EXISTS dbo.sp_tdc_get_sql_managed_instance_iops_performance;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE PROCEDURE dbo.sp_tdc_get_sql_managed_instance_iops_performance
AS
BEGIN;


    WITH
        DatabaseFiles
        AS
        (
            SELECT DB_NAME(database_id)                                 AS [Database Name],
                type_desc                                            AS [File Type],
                name                                                 AS [File Name],
                CAST(( size * 8.0 ) / 1024 AS DECIMAL(38, 1))        AS [Size MB],
                CAST(( size * 8.0 ) / 1024 / 1024 AS DECIMAL(38, 1)) AS [Size GB]
            FROM sys.master_files
            WHERE  type IN ( 0 ) AND
                database_id >= 5
        )
    SELECT DF.[Database Name],
        DF.[File Type],
        DF.[File Name],
        DF.[Size MB],
        DF.[Size GB],
        CASE WHEN DF.[Size GB] >= 0 AND
            DF.[Size GB] <= 128 THEN 'P10'
                 WHEN DF.[Size GB] > 128 AND
            DF.[Size GB] <= 256 THEN 'P15'
                 WHEN DF.[Size GB] > 256 AND
            DF.[Size GB] <= 512 THEN 'P20'
                 WHEN DF.[Size GB] > 512 AND
            DF.[Size GB] <= 1024 THEN 'P30'
                 WHEN DF.[Size GB] > 1024 AND
            DF.[Size GB] <= 2048 THEN 'P40'
                 WHEN DF.[Size GB] > 2048 AND
            DF.[Size GB] <= 4096 THEN 'P40'
                 WHEN DF.[Size GB] > 4096 AND
            DF.[Size GB] <= 8192 THEN 'P50'
                 ELSE 'P60'
             END AS [Azure Disk],
        CASE WHEN DF.[Size GB] >= 0 AND
            DF.[Size GB] <= 128 THEN 500
                 WHEN DF.[Size GB] > 128 AND
            DF.[Size GB] <= 256 THEN 1100
                 WHEN DF.[Size GB] > 256 AND
            DF.[Size GB] <= 512 THEN 2300
                 WHEN DF.[Size GB] > 512 AND
            DF.[Size GB] <= 1024 THEN 5000
                 WHEN DF.[Size GB] > 1024 AND
            DF.[Size GB] <= 2048 THEN 7500
                 WHEN DF.[Size GB] > 2048 AND
            DF.[Size GB] <= 4096 THEN 7500
                 WHEN DF.[Size GB] > 4096 AND
            DF.[Size GB] <= 8192 THEN 12500
                 ELSE 12500
             END AS [Max IOPS Per FILE],
        CASE WHEN DF.[Size GB] >= 0 AND
            DF.[Size GB] <= 128 THEN 100
                 WHEN DF.[Size GB] > 128 AND
            DF.[Size GB] <= 256 THEN 125
                 WHEN DF.[Size GB] > 256 AND
            DF.[Size GB] <= 512 THEN 150
                 WHEN DF.[Size GB] > 512 AND
            DF.[Size GB] <= 1024 THEN 200
                 WHEN DF.[Size GB] > 1024 AND
            DF.[Size GB] <= 2048 THEN 250
                 WHEN DF.[Size GB] > 2048 AND
            DF.[Size GB] <= 4096 THEN 250
                 WHEN DF.[Size GB] > 4096 AND
            DF.[Size GB] <= 8192 THEN 500
                 ELSE 500
             END AS [Max T/P Per File MiB/s]
    FROM DatabaseFiles AS DF
    ORDER BY DF.[Database Name],
             DF.[File Type];
END;
GO