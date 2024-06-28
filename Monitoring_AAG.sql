USE [master]
GO
/****** Object:  Database [DBA]    Script Date: 1/14/2015 11:32:34 AM ******/
CREATE DATABASE [DBA]
 CONTAINMENT = NONE
 ON  PRIMARY 
( NAME = N'DBA', FILENAME = N'D:\MSSQL_Data\DBA.mdf' , SIZE = 10304KB , MAXSIZE = UNLIMITED, FILEGROWTH = 1024KB )
 LOG ON 
( NAME = N'DBA_log', FILENAME = N'E:\MSSQL_Log\DBA_log.ldf' , SIZE = 1344KB , MAXSIZE = 2048GB , FILEGROWTH = 10%)
GO
ALTER DATABASE [DBA] SET COMPATIBILITY_LEVEL = 110
GO
IF (1 = FULLTEXTSERVICEPROPERTY('IsFullTextInstalled'))
begin
EXEC [DBA].[dbo].[sp_fulltext_database] @action = 'enable'
end
GO
ALTER DATABASE [DBA] SET ANSI_NULL_DEFAULT OFF 
GO
ALTER DATABASE [DBA] SET ANSI_NULLS OFF 
GO
ALTER DATABASE [DBA] SET ANSI_PADDING OFF 
GO
ALTER DATABASE [DBA] SET ANSI_WARNINGS OFF 
GO
ALTER DATABASE [DBA] SET ARITHABORT OFF 
GO
ALTER DATABASE [DBA] SET AUTO_CLOSE OFF 
GO
ALTER DATABASE [DBA] SET AUTO_CREATE_STATISTICS ON 
GO
ALTER DATABASE [DBA] SET AUTO_SHRINK OFF 
GO
ALTER DATABASE [DBA] SET AUTO_UPDATE_STATISTICS ON 
GO
ALTER DATABASE [DBA] SET CURSOR_CLOSE_ON_COMMIT OFF 
GO
ALTER DATABASE [DBA] SET CURSOR_DEFAULT  GLOBAL 
GO
ALTER DATABASE [DBA] SET CONCAT_NULL_YIELDS_NULL OFF 
GO
ALTER DATABASE [DBA] SET NUMERIC_ROUNDABORT OFF 
GO
ALTER DATABASE [DBA] SET QUOTED_IDENTIFIER OFF 
GO
ALTER DATABASE [DBA] SET RECURSIVE_TRIGGERS OFF 
GO
ALTER DATABASE [DBA] SET  DISABLE_BROKER 
GO
ALTER DATABASE [DBA] SET AUTO_UPDATE_STATISTICS_ASYNC OFF 
GO
ALTER DATABASE [DBA] SET DATE_CORRELATION_OPTIMIZATION OFF 
GO
ALTER DATABASE [DBA] SET TRUSTWORTHY OFF 
GO
ALTER DATABASE [DBA] SET ALLOW_SNAPSHOT_ISOLATION OFF 
GO
ALTER DATABASE [DBA] SET PARAMETERIZATION SIMPLE 
GO
ALTER DATABASE [DBA] SET READ_COMMITTED_SNAPSHOT OFF 
GO
ALTER DATABASE [DBA] SET HONOR_BROKER_PRIORITY OFF 
GO
ALTER DATABASE [DBA] SET RECOVERY SIMPLE 
GO
ALTER DATABASE [DBA] SET  MULTI_USER 
GO
ALTER DATABASE [DBA] SET PAGE_VERIFY CHECKSUM  
GO
ALTER DATABASE [DBA] SET DB_CHAINING OFF 
GO
ALTER DATABASE [DBA] SET FILESTREAM( NON_TRANSACTED_ACCESS = OFF ) 
GO
ALTER DATABASE [DBA] SET TARGET_RECOVERY_TIME = 0 SECONDS 
GO
EXEC sys.sp_db_vardecimal_storage_format N'DBA', N'ON'
GO
USE [DBA]
GO
/****** Object:  StoredProcedure [dbo].[dba_alwayson_detect_failover]    Script Date: 1/14/2015 11:32:34 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE PROCEDURE [dbo].[dba_alwayson_detect_failover]
as

DECLARE @t_aag TABLE
(
 group_name SYSNAME not null,
 primary_replica VARCHAR(128) not null,
 primary_recovery_health NVARCHAR(80) null
);

declare @t_aag_result table
(
 [action] VARCHAR(50) not null, 
 group_name SYSNAME not null,
 primary_replica_old VARCHAR(128) null,
 primary_replica_new VARCHAR(128) not null,
 primary_recovery_health NVARCHAR(80) null
);

WHILE 1 = 1
BEGIN

 WITH aag
 AS
 (
	SELECT 
	 g.name AS group_name,
	 primary_replica,
	 primary_recovery_health_desc
	FROM sys.dm_hadr_availability_group_states AS ags
	 JOIN sys.availability_groups AS g
	  ON ags.group_id = g.group_id
 )
 MERGE @t_aag as t_aag
 USING aag
  ON aag.group_name = t_aag.group_name collate French_CI_AS
 WHEN matched and aag.primary_replica <> t_aag.primary_replica collate French_CI_AS
  THEN update SET primary_replica = aag.primary_replica,
				  primary_recovery_health = aag.primary_recovery_health_desc
 WHEN NOT MATCHED BY TARGET 
  THEN INSERT VALUES (aag.group_name, aag.primary_replica, aag.primary_recovery_health_desc)
 WHEN NOT MATCHED BY SOURCE 
  THEN DELETE
 OUTPUT $action, inserted.group_name, deleted.primary_replica, inserted.primary_replica, inserted.primary_recovery_health
 INTO @t_aag_result;

 -- insert only when changes on existing data
 INSERT INTO [dbo].[dba_alwayson_failover_logs] (group_name, primary_replica_old, primary_replica_new, primary_recovery_health)
 SELECT 
  group_name, 
  primary_replica_old, 
  primary_replica_new, 
  primary_recovery_health
 FROM @t_aag_result
 WHERE [action] = 'update';

 -- Reset work table
 DELETE FROM @t_aag_result;

 -- Send email if failover is detected
 EXEC dbo.dba_alwayson_mail;

 WAITFOR DELAY '00:00:10';
END




GO
/****** Object:  StoredProcedure [dbo].[dba_alwayson_mail]    Script Date: 1/14/2015 11:32:35 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO






CREATE PROCEDURE [dbo].[dba_alwayson_mail]
(
 @profile_mail SYSNAME = 'dba'
)
AS
/**********************************************************
 * @author = David BARBARIN - Pragmantic SA               *
 * @Procedure = dba_alwayson_mail                         *
 * @Description =                                         *
 * Send email to the operator when a failover occurs      *                                                  *
 **********************************************************/

SET NOCOUNT ON;

DECLARE @operators VARCHAR(1000);

-- Verification if errors exist 
IF EXISTS (SELECT 1 FROM dbo.dba_alwayson_failover_logs
           WHERE sent_by_email IS NULL)
BEGIN
 /* Operators for sendmail */
 IF EXISTS (SELECT 1 from msdb.dbo.sysoperators)
 BEGIN
  SELECT @operators = email_address 
   FROM msdb.dbo.sysoperators
  WHERE name = 'dba'
 END
 ELSE 
 BEGIN
  SELECT @operators = value 
  FROM dbo.dba_maintenance_configuration 
  WHERE parameter = 'operator_email';
 END

 -- If no operators configured sending maintenance mail is not performed
 IF @operators IS NULL OR LEN(@operators) = 0
 BEGIN
  RAISERROR('No operators are configured for sending maintenance mails.', 16, 1);
  RETURN;
 END

-- If no insentia profile is configured send maintenance mail is not performance
 IF NOT EXISTS(SELECT 1 FROM msdb.dbo.sysmail_profile
               WHERE name = @profile_mail)
 BEGIN
  RAISERROR('No databasemail dba profil is configured for sending maintenance mails.', 16, 1);
  RETURN;
 END

 DECLARE @subject_mail NVARCHAR(255);
 DECLARE @body_mail NVARCHAR(MAX);

 DECLARE @group_name SYSNAME;
 DECLARE @primary_replica_old VARCHAR(128);
 DECLARE @primary_replica_new VARCHAR(128);
 DECLARE @primary_recovery_health NVARCHAR(80);

 SELECT TOP 1 
  @group_name = group_name,
  @primary_replica_old = primary_replica_old,
  @primary_replica_new = primary_replica_new,
  @primary_recovery_health = primary_recovery_health
 FROM [dbo].[dba_alwayson_failover_logs]
 WHERE sent_by_email IS NULL
 ORDER BY event_time;

 DECLARE @servername SYSNAME = @@SERVERNAME;
 SET @subject_mail = COALESCE(@@SERVERNAME, ' ') + ' -  ' + 'Failover occuring for the availability group ' + @group_name; 
 SET @body_mail = COALESCE(@@SERVERNAME, ' ') + CHAR(13) + CHAR(13) + 
                  'Availabilty group   : ' + @group_name + CHAR(13) + CHAR(13) +
                  'Old primary replica : ' + @primary_replica_old + CHAR(13) + CHAR(13) +
				  'New primary replica : ' + @primary_replica_new + CHAR(13) + CHAR(13);

 /* Send Email */
 EXEC msdb.dbo.sp_send_dbmail
  @profile_name = @profile_mail,
  @recipients = @operators,
  @importance = 'HIGH',
  @subject = @subject_mail,
  @body = @body_mail;


 /* Update table dbo.dba_maintenance_task_logs */
  WITH alwaysonFailover
  AS
  (
	  SELECT TOP (1) *
	  FROM dbo.dba_alwayson_failover_logs 
	  WHERE sent_by_email IS NULL
	  ORDER BY event_time
  )
  UPDATE alwaysonFailover
  SET sent_by_email = 1;
  
END






GO
/****** Object:  StoredProcedure [dbo].[dba_backup_log_user_databases_alwayson]    Script Date: 1/14/2015 11:32:35 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[dba_backup_log_user_databases_alwayson]  
AS 

/**********************************************************
 * @author = David BARBARIN - Pragmantic SA               *
 * @Procedure = dba_backup_log_user_databases             *
 * @Description =                                         *
 * step 1 : Creation of a subdirectory folder for the     *
 * the concerned database.                                *
 * step 2 : backup of transaction of all available        *
 * databases. If full backup doesn't exist it will done   *
 * before                                                 *
 * --> online = true                                      *
 * --> recovery model = bulk logged or full               *
 * --> with checksum option (new feature since 2008)      *
 * --> Compression (permit by default)                    *
 * step 2 : Verification of the log backups               *
 * --> with checksum option (by default                   *
 **********************************************************/

SET NOCOUNT ON;  

-- DEBUG PARAMETER
DECLARE @debug BIT = 0;

-- CONFIGURATION PARAMETERS  
DECLARE @backupdir VARCHAR(100) = (SELECT value FROM dbo.dba_maintenance_configuration WHERE parameter = 'backupdir');  
DECLARE @compression VARCHAR(3) = (SELECT value FROM dbo.dba_maintenance_configuration WHERE parameter = 'compression');
DECLARE @backup_integrity_checksum VARCHAR(10) = (SELECT value FROM dbo.dba_maintenance_configuration WHERE parameter = 'backup_integrity_checksum');

-- ERROR PARAMETERS
DECLARE @error_line INT;
DECLARE @error_number INT;
DECLARE @error_severity INT;
DECLARE @error_state INT;
DECLARE @error_message NVARCHAR(2048);

-- LOG PARAMETERS
DECLARE @start_time DATETIME;
DECLARE @end_time DATETIME;
DECLARE @start_time_task DATETIME;
DECLARE @end_time_task DATETIME;
DECLARE @nb_errors INT = 0;
DECLARE @succeeded BIT = 1;
DECLARE @task_detail_id_insert BIGINT;

-- VERSION PARAMETER
DECLARE @edition_check INT = CAST(SERVERPROPERTY('EngineEdition') AS TINYINT); -- 3 = Enterprise (This is returned for Enterprise, Enterprise Evaluation, and Developer.)
  
-- WORK TABLES
DECLARE @t_database TABLE
(
 id INT IDENTITY(1,1),
 database_name SYSNAME,
 aag_name SYSNAME NULL
);
  
INSERT @t_database (database_name, aag_name)  
SELECT d.name, g.name
FROM sys.databases AS d
 LEFT JOIN sys.dm_hadr_availability_replica_states AS r
  ON r.replica_id = d.replica_id
 LEFT JOIN sys.availability_groups AS g
  ON g.group_id = r.group_id
WHERE d.database_id > 4 -- System databases
 AND d.[state] = 0 -- Databases online only
  AND recovery_model <> 3 -- Databases with only full or bulk-logged recovery model
   AND sys.fn_hadr_backup_is_preferred_replica(d.name) = 1;

  
DECLARE @i INT = 1;  
DECLARE @max INT = (SELECT COUNT(*) FROM @t_database);  
DECLARE @name SYSNAME;  
DECLARE @aag_name SYSNAME;
DECLARE @pathbackup VARCHAR(200); 
DECLARE @sql VARCHAR(8000); 

-- Record start time for the backup system job
SET @start_time = GETDATE();

EXEC dbo.dba_maintenance_task_logging
 @operation = 'I',
 @task_name = 'dba_backup_log_user_databases',
 @start_time = @start_time,
 @task_detail_id_insert = @task_detail_id_insert OUTPUT;
  
  
WHILE @i <= @max  
BEGIN  
 SELECT @name = database_name, @aag_name = aag_name
 FROM @t_database  
 WHERE id = @i;  
  
 /* DEBUG */ 
 IF @debug = 1
 BEGIN
  IF ( @aag_name IS NULL)
  BEGIN
   PRINT 'Create subdirectory for ' + @name
   PRINT 'EXECUTE [master].dbo.xp_create_subdir ''' + @backupdir + @@SERVERNAME + '\' + @name + '''';
  END
  ELSE
  BEGIN
   PRINT 'Create subdirectory for ' + @name
   PRINT 'EXECUTE [master].dbo.xp_create_subdir ''' + @backupdir + 'AAG_' + @aag_name + '\' + @name + ''''
  END
 END
 
 -- Record start time for the creation of folder task
 SET @start_time_task = GETDATE();
   
 /* Create subdirectoy for the concerned database */
 IF ( @aag_name IS NULL)
 BEGIN
  EXEC('EXECUTE [master].dbo.xp_create_subdir ''' + @backupdir + @@SERVERNAME + '\' + @name + '''');
 END
 ELSE
 BEGIN
  EXEC('EXECUTE [master].dbo.xp_create_subdir ''' + @backupdir + 'AAG_' + @aag_name + '\' + @name + '''');
 END

 IF @@ERROR = 0
 BEGIN
  PRINT 'Create subdirectory for ' + @name + ' OK'
 END
 ELSE
 BEGIN
  PRINT 'Create subdirectory for ' + @name + ' KO'
 END
 
 
 IF (@aag_name IS NULL)
 BEGIN
	 /* If no full backup exists we must perform a full database backup before the backup log */
	 IF (SELECT MAX(backup_start_date) FROM msdb.dbo.backupset
		  WHERE database_name = @name AND [type] = 'D') IS NULL
	 BEGIN
	  SET @pathbackup = @backupdir + @@SERVERNAME + '\' + @name + '\' + @name + '_' +   
				  CONVERT(VARCHAR, GETDATE(), 112) + CAST(DATEPART(hh, GETDATE()) AS VARCHAR(2)) +   
				  CAST(DATEPART(mi, GETDATE()) AS VARCHAR(2)) + CAST(DATEPART(ss, GETDATE()) AS VARCHAR(2)) +  
				  '.BAK';
              
	  -- Backup full database  
	  SET @sql = 'BACKUP DATABASE [' + @name + '] TO DISK = ''' + @pathbackup + ''' WITH INIT' + CASE @backup_integrity_checksum WHEN 'CHECKSUM' THEN ', CHECKSUM' ELSE '' END + CASE WHEN @compression = 'Yes' AND @edition_check = 3 THEN ', COMPRESSION;' ELSE '' END;      
	 END
	 ELSE 
	 BEGIN
	  SET @pathbackup =  @backupdir + @@SERVERNAME + '\' + @name + '\' + @name + '_' +   
				  CONVERT(VARCHAR, GETDATE(), 112) + CAST(DATEPART(hh, GETDATE()) AS VARCHAR(2)) +   
				  CAST(DATEPART(mi, GETDATE()) AS VARCHAR(2)) + CAST(DATEPART(ss, GETDATE()) AS VARCHAR(2)) +  
				  '.TRN';
  
	 -- Backup log database  
	  SET @sql = 'BACKUP LOG [' + @name + '] TO DISK = ''' + @pathbackup + ''' WITH INIT' + CASE @backup_integrity_checksum WHEN 'CHECKSUM' THEN ', CHECKSUM' ELSE '' END + CASE WHEN @compression = 'Yes' AND @edition_check = 3 THEN ', COMPRESSION;' ELSE '' END;               
	 END
 END
 ELSE
 BEGIN
    SET @pathbackup =  @backupdir + 'AAG_' + @aag_name + '\' + @name + '\' + @name + '_' +   
				  CONVERT(VARCHAR, GETDATE(), 112) + CAST(DATEPART(hh, GETDATE()) AS VARCHAR(2)) +   
				  CAST(DATEPART(mi, GETDATE()) AS VARCHAR(2)) + CAST(DATEPART(ss, GETDATE()) AS VARCHAR(2)) +  
				  '.TRN';
   
	-- Backup log database  
	SET @sql = 'BACKUP LOG [' + @name + '] TO DISK = ''' + @pathbackup + ''' WITH INIT' + CASE @backup_integrity_checksum WHEN 'CHECKSUM' THEN ', CHECKSUM' ELSE '' END + CASE WHEN @compression = 'Yes' AND @edition_check = 3 THEN ', COMPRESSION;' ELSE '' END;               
 END

 
 /* DEBUG */
 IF @debug = 1
 BEGIN
  PRINT 'Backup database for ' + @name  
  PRINT @sql;  
 END 
 BEGIN TRY
  -- Record start time for the backup log task
  SET @start_time_task = GETDATE();

  EXEC (@sql);  

  -- Record log for the backup log task
  SET @end_time_task = GETDATE();

  EXEC dbo.dba_maintenance_task_details_logging
   @task_detail_id = @task_detail_id_insert,
   @database_name = @name,
   @step_name = 'Backup log',
   @start_time = @start_time_task,
   @end_time = @end_time_task,
   @succeeded = 1;
 END TRY
 BEGIN CATCH
  -- Count number of errors
  SET @nb_errors = @nb_errors + 1;
  
  SET @error_number = ERROR_NUMBER();
  SET @error_severity = ERROR_SEVERITY();
  SET @error_message = ERROR_MESSAGE();
  
  -- Record log for the create folder task
  SET @end_time_task = GETDATE();
  
  EXEC dbo.dba_maintenance_task_details_logging
   @task_detail_id = @task_detail_id_insert,
   @database_name = @name,
   @step_name = 'Backup log',
   @start_time = @start_time_task,
   @end_time = @end_time_task,
   @error_number = @error_number,
   @error_severity = @error_severity,
   @error_message = @error_message,
   @succeeded = 0;
 END CATCH
   
 /* Verify backup log */
 SET @sql = 'EXEC dbo.dba_verif_backup_databases ''' + @pathbackup + ''''  
 
 /* DEBUG */
 IF @debug = 1
 BEGIN  
  PRINT 'Verify backup database for ' + @name  
  PRINT @sql;  
 END 
 
 BEGIN TRY
  -- Record start time for the verif backup database task
  SET @start_time_task = GETDATE();
  
  EXEC (@sql); 
  
  -- Record log for the create folder task
  SET @end_time_task = GETDATE();
  
  EXEC dbo.dba_maintenance_task_details_logging
   @task_detail_id = @task_detail_id_insert,
   @database_name = @name,
   @step_name = 'Verification of log backup',
   @start_time = @start_time_task,
   @end_time = @end_time_task,
   @succeeded = 1;   
 END TRY
 BEGIN CATCH
    -- Count number of errors
  SET @nb_errors = @nb_errors + 1;
  
  -- Record log for the create folder task
  SET @end_time_task = GETDATE();
  
  EXEC dbo.dba_maintenance_task_details_logging
   @task_detail_id = @task_detail_id_insert,
   @database_name = @name,
   @step_name = 'Verification of log backup',
   @start_time = @start_time_task,
   @end_time = @end_time_task,
   @error_number = @error_number,
   @error_severity = @error_severity,
   @error_message = @error_message,
   @succeeded = 0;
 END CATCH
            
 SET @i += 1;  
END

-- Record log for the backup system job
SET @end_time = GETDATE();

IF @nb_errors > 0 
 SET @succeeded = 0;
  
EXEC dbo.dba_maintenance_task_logging
 @operation = 'U',
 @task_name = 'dba_backup_log_user_databases',
 @end_time = @end_time,
 @succeeded = @succeeded,
 @task_detail_id_update = @task_detail_id_insert;

GO
/****** Object:  StoredProcedure [dbo].[dba_backup_system_databases_alwayson]    Script Date: 1/14/2015 11:32:35 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[dba_backup_system_databases_alwayson]    
AS    

/**********************************************************
 * @author = David BARBARIN - Pragmantic SA               *
 * @Procedure = dba_backup_system_databases               *
 * @Description =                                         *
 * step 1 : Creation of a subdirectory folder for the     *
 * the concerned database.                                *
 * step 1 : backup of system databases of all available   *
 * --> online = true                                      *
 * --> with checksum option (new feature since 2008)      *
 * --> Compression (permit by default)                    *
 * step 2 : Verification of the databases backups         *
 * --> with checksum option                               *
 **********************************************************/
    
SET NOCOUNT ON;  

-- DEBUG PARAMETERS
DECLARE @debug BIT = 0;

-- CONFIGURATION PARAMETERS    
DECLARE @backupdir VARCHAR(100) = (SELECT value FROM dbo.dba_maintenance_configuration WHERE parameter = 'backupdir');  
DECLARE @compression VARCHAR(3) = (SELECT value FROM dbo.dba_maintenance_configuration WHERE parameter = 'compression');
DECLARE @backup_integrity_checksum VARCHAR(10) = (SELECT value FROM dbo.dba_maintenance_configuration WHERE parameter = 'backup_integrity_checksum');  

-- ERROR PARAMETERS
DECLARE @error_line INT;
DECLARE @error_number INT;
DECLARE @error_severity INT;
DECLARE @error_state INT;
DECLARE @error_message NVARCHAR(2048);

-- LOG PARAMETERS
DECLARE @start_time DATETIME;
DECLARE @end_time DATETIME;
DECLARE @start_time_task DATETIME;
DECLARE @end_time_task DATETIME;
DECLARE @nb_errors INT = 0;
DECLARE @succeeded BIT = 1;
DECLARE @task_detail_id_insert BIGINT;
  
-- WORK TABLES
DECLARE @t_database TABLE    
(    
 id INT IDENTITY(1,1),    
 database_name SYSNAME    
);    
    
INSERT @t_database (database_name)    
SELECT name    
FROM sys.databases    
WHERE database_id <= 4 -- System databases    
 AND name <> 'tempdb'    
    
DECLARE @i INT = 1;    
DECLARE @max INT = (SELECT COUNT(*) FROM @t_database);    
DECLARE @name SYSNAME;        
DECLARE @pathbackup VARCHAR(200);    
DECLARE @sql VARCHAR(MAX);  


-- Record start time for the backup system job
SET @start_time = GETDATE();

EXEC dbo.dba_maintenance_task_logging
 @operation = 'I',
 @task_name = 'dba_backup_system_databases',
 @start_time = @start_time,
 @task_detail_id_insert = @task_detail_id_insert OUTPUT;
   
    
WHILE @i <= @max    
BEGIN    
 SET @name = (SELECT database_name FROM @t_database    
              WHERE id = @i);    
       
 /* DEBUG */       
 IF @debug = 1
 BEGIN 
  PRINT 'Create subdirectory for ' + @name    
  PRINT 'EXECUTE [master].dbo.xp_create_subdir ''' + @backupdir + @@SERVERNAME + '\' + @name + '''';
 END   

 -- Record start time for the creation of folder task
 SET @start_time_task = GETDATE();
 
 /* Create subdirectoy for the concerned database */
 EXEC('EXECUTE [master].dbo.xp_create_subdir ''' + @backupdir + @@SERVERNAME + '\' + @name + '''');
 
 -- For xp_create_subdir we cannot use TRY CATCH
 IF @@ERROR = 0
 BEGIN
  PRINT 'Create subdirectory for ' + @name + ' OK'
 END
 ELSE
 BEGIN
  PRINT 'Create subdirectory for ' + @name + ' KO';
 END
 
 SET @pathbackup =  @backupdir + @@SERVERNAME + '\' + @name + '\' + @name + '_' +     
              CONVERT(VARCHAR, GETDATE(), 112) + CAST(DATEPART(hh, GETDATE()) AS VARCHAR(2)) +     
              CAST(DATEPART(mi, GETDATE()) AS VARCHAR(2)) + CAST(DATEPART(ss, GETDATE()) AS VARCHAR(2)) +    
              '.BAK';
     
 /* Backup systemp database */   
 SET @sql = 'BACKUP DATABASE [' + @name + '] TO DISK = ''' + @pathbackup + ''' WITH INIT' + CASE @backup_integrity_checksum WHEN 'CHECKSUM' THEN ', CHECKSUM' ELSE '' END + CASE @compression WHEN 'Yes' THEN ', COMPRESSION;' ELSE '' END    
 
 /* DEBUG */
 IF @debug = 1
 BEGIN 
  PRINT 'Backup database for ' + @name    
  PRINT @sql;  
 END   
  
 BEGIN TRY
  -- Record start time for the backup database task
  SET @start_time_task = GETDATE();   
 
  EXEC (@sql);    
  
  -- Record log for the create folder task
  SET @end_time_task = GETDATE();
  
  EXEC dbo.dba_maintenance_task_details_logging
   @task_detail_id = @task_detail_id_insert,
   @database_name = @name,
   @step_name = 'Backup database',
   @start_time = @start_time_task,
   @end_time = @end_time_task,
   @succeeded = 1;
 END TRY  
 BEGIN CATCH
   -- Count number of errors
  SET @nb_errors = @nb_errors + 1;
  
  SET @error_number = ERROR_NUMBER();
  SET @error_severity = ERROR_SEVERITY();
  SET @error_message = ERROR_MESSAGE();
  
  -- Record log for the create folder task
  SET @end_time_task = GETDATE();
  
  EXEC dbo.dba_maintenance_task_details_logging
   @task_detail_id = @task_detail_id_insert,
   @database_name = @name,
   @step_name = 'Backup database',
   @start_time = @start_time_task,
   @end_time = @end_time_task,
   @error_number = @error_number,
   @error_severity = @error_severity,
   @error_message = @error_message,
   @succeeded = 0;
 
 END CATCH

 /* Verify backup database */ 
 SET @sql = 'EXEC dbo.dba_verif_backup_databases ''' + @pathbackup + ''''  
 
 /* DEBUG */
 IF @debug = 1
 BEGIN
  PRINT 'Verify backup database for ' + @name  
  PRINT @sql;  
 END
 
 BEGIN TRY 
   -- Record start time for the backup database task
  SET @start_time_task = GETDATE();
 
  EXEC (@sql);
  
  -- Record log for the create folder task
  SET @end_time_task = GETDATE();
  
  EXEC dbo.dba_maintenance_task_details_logging
   @task_detail_id = @task_detail_id_insert,
   @database_name = @name,
   @step_name = 'Verification of database backup',
   @start_time = @start_time_task,
   @end_time = @end_time_task,
   @succeeded = 1;    
 END TRY
 BEGIN CATCH
   -- Count number of errors
  SET @nb_errors = @nb_errors + 1;
  
  -- Record log for the create folder task
  SET @end_time_task = GETDATE();
  
  EXEC dbo.dba_maintenance_task_details_logging
   @task_detail_id = @task_detail_id_insert,
   @database_name = @name,
   @step_name = 'Verification of database backup',
   @start_time = @start_time_task,
   @end_time = @end_time_task,
   @error_number = @error_number,
   @error_severity = @error_severity,
   @error_message = @error_message,
   @succeeded = 0;
 
 END CATCH    
    
 SET @i += 1;    
END

-- Record log for the backup system job
SET @end_time = GETDATE();

IF @nb_errors > 0 
 SET @succeeded = 0;
  
EXEC dbo.dba_maintenance_task_logging
 @operation = 'U',
 @task_name = 'dba_backup_system_databases',
 @end_time = @end_time,
 @succeeded = @succeeded,
 @task_detail_id_update = @task_detail_id_insert;

GO
/****** Object:  StoredProcedure [dbo].[dba_backup_user_databases_alwayson]    Script Date: 1/14/2015 11:32:35 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[dba_backup_user_databases_alwayson]
AS

/**********************************************************
 * @author = David BARBARIN - Pragmantic SA               *
 * @Procedure = dba_backup_user_databases                 *
 * @Description =                                         *
 * step 1 : Creation of a subdirectory folder for the     *
 * the concerned database.                                *
 * step 1 : backup of system databases of all available   *
 * --> online = true                                      *
 * --> with checksum option (new feature since 2008)      *
 * --> Compression (permit by default)                    *
 * step 2 : Verification of the databases backups         *
 * --> with checksum option                               *
 **********************************************************/

SET NOCOUNT ON;

-- DEBUG PARAMETER
DECLARE @debug INT = 0;

-- CONFIGURATION PARAMETERS
DECLARE @backupdir VARCHAR(100) = (SELECT value FROM dbo.dba_maintenance_configuration WHERE parameter = 'backupdir');
DECLARE @compression VARCHAR(3) = (SELECT value FROM dbo.dba_maintenance_configuration WHERE parameter = 'compression');
DECLARE @backup_integrity_checksum VARCHAR(10) = (SELECT value FROM dbo.dba_maintenance_configuration WHERE parameter = 'backup_integrity_checksum');

-- ERROR PARAMETERS
DECLARE @error_line INT;
DECLARE @error_number INT;
DECLARE @error_severity INT;
DECLARE @error_state INT;
DECLARE @error_message NVARCHAR(2048);

-- LOG PARAMETERS
DECLARE @start_time DATETIME;
DECLARE @end_time DATETIME;
DECLARE @start_time_task DATETIME;
DECLARE @end_time_task DATETIME;
DECLARE @nb_errors INT = 0;
DECLARE @succeeded BIT = 1;
DECLARE @task_detail_id_insert BIGINT;

-- WORK TABLES
DECLARE @t_database TABLE
(
 id INT IDENTITY(1,1),
 database_name SYSNAME,
 replica_role_desc NVARCHAR(50) NULL,
 aag_name SYSNAME NULL
);

INSERT @t_database (database_name, replica_role_desc, aag_name)
SELECT d.name, r.role_desc, g.name
FROM sys.databases AS d
 LEFT JOIN sys.dm_hadr_availability_replica_states AS r
  ON r.replica_id = d.replica_id
 LEFT JOIN sys.availability_groups AS g
  ON g.group_id = r.group_id
WHERE d.database_id > 4 -- System databases
 AND d.[state] = 0 -- Databases online only
  AND sys.fn_hadr_backup_is_preferred_replica(d.name) = 1;


DECLARE @i INT = 1;
DECLARE @max INT = (SELECT COUNT(*) FROM @t_database);
DECLARE @name SYSNAME;
DECLARE @replica_role_desc VARCHAR(50);
DECLARE @aag_name SYSNAME;
DECLARE @pathbackup VARCHAR(200);
DECLARE @sql VARCHAR(8000);


-- Record start time for the backup user job
SET @start_time = GETDATE();

EXEC dbo.dba_maintenance_task_logging
 @operation = 'I',
 @task_name = 'dba_backup_user_databases',
 @start_time = @start_time,
 @task_detail_id_insert = @task_detail_id_insert OUTPUT;


WHILE @i <= @max
BEGIN
 SELECT @name = database_name, @replica_role_desc = replica_role_desc, @aag_name = aag_name 
 FROM @t_database
 WHERE id = @i

 
 IF @debug = 1
 BEGIN
  IF ( @aag_name IS NULL)
  BEGIN
   PRINT 'Create subdirectory for ' + @name
   PRINT 'EXECUTE [master].dbo.xp_create_subdir ''' + @backupdir + @@SERVERNAME + '\' + @name + '''';
  END
  ELSE
  BEGIN
   PRINT 'Create subdirectory for ' + @name
   PRINT 'EXECUTE [master].dbo.xp_create_subdir ''' + @backupdir + 'AAG_' + @aag_name + '\' + @name + ''''
  END
 END

 -- Record start time for the creation of folder task
 SET @start_time_task = GETDATE();
 
 /* Create subdirectoy for the concerned database */
 IF ( @aag_name IS NULL)
 BEGIN
   EXEC('EXECUTE [master].dbo.xp_create_subdir ''' + @backupdir + @@SERVERNAME + '\' + @name + '''');
 END
 ELSE
 BEGIN
  EXEC('EXECUTE [master].dbo.xp_create_subdir ''' + @backupdir + 'AAG_' + @aag_name + '\' + @name + '''');
 END
 
 -- For xp_create_subdir we cannot use TRY CATCH
 IF @@ERROR = 0
 BEGIN
  PRINT 'Create subdirectory for ' + @name + ' OK'
  
 END
 ELSE
 BEGIN
  PRINT 'Create subdirectory for ' + @name + ' KO'
 END
 
 IF ( @aag_name IS NULL)
 BEGIN
  SET @pathbackup = @backupdir + @@SERVERNAME + '\' + @name + '\' + @name + '_' +     
              CONVERT(VARCHAR, GETDATE(), 112) + CAST(DATEPART(hh, GETDATE()) AS VARCHAR(2)) +     
              CAST(DATEPART(mi, GETDATE()) AS VARCHAR(2)) + CAST(DATEPART(ss, GETDATE()) AS VARCHAR(2)) +    
              '.BAK';
 END
 ELSE
 BEGIN
  SET @pathbackup = @backupdir + 'AAG_' + @aag_name + '\' + @name + '\' + @name + '_' +     
              CONVERT(VARCHAR, GETDATE(), 112) + CAST(DATEPART(hh, GETDATE()) AS VARCHAR(2)) +     
              CAST(DATEPART(mi, GETDATE()) AS VARCHAR(2)) + CAST(DATEPART(ss, GETDATE()) AS VARCHAR(2)) +    
              '.BAK';
 END

 /* Backup user database */
 IF ( @replica_role_desc = 'PRIMARY' OR @replica_role_desc IS NULL)
 BEGIN
  SET @sql = 'BACKUP DATABASE [' + @name + '] TO DISK = ''' + @pathbackup + ''' WITH INIT' + CASE @backup_integrity_checksum WHEN 'CHECKSUM' THEN ', CHECKSUM' ELSE '' END + CASE @compression WHEN 'Yes' THEN ', COMPRESSION;' ELSE '' END
 END
 ELSE
 BEGIN
  SET @sql = 'BACKUP DATABASE [' + @name + '] TO DISK = ''' + @pathbackup + ''' WITH INIT, COPY_ONLY ' + CASE @backup_integrity_checksum WHEN 'CHECKSUM' THEN ', CHECKSUM' ELSE '' END + CASE @compression WHEN 'Yes' THEN ', COMPRESSION;' ELSE '' END
 END

 IF @debug = 1
 BEGIN
  PRINT 'Backup database for ' + @name
  PRINT @sql;
 END
 
 BEGIN TRY
  -- Record start time for the backup database task
  SET @start_time_task = GETDATE();

  EXEC (@sql);

  -- Record log for the create folder task
  SET @end_time_task = GETDATE();
  
  EXEC dbo.dba_maintenance_task_details_logging
   @task_detail_id = @task_detail_id_insert,
   @database_name = @name,
   @step_name = 'Backup database',
   @start_time = @start_time_task,
   @end_time = @end_time_task,
   @succeeded = 1;
 END TRY
 BEGIN CATCH
  -- Count number of errors
  SET @nb_errors = @nb_errors + 1;
  
  SET @error_number = ERROR_NUMBER();
  SET @error_severity = ERROR_SEVERITY();
  SET @error_message = ERROR_MESSAGE();
  
  -- Record log for the create folder task
  SET @end_time_task = GETDATE();
  
  EXEC dbo.dba_maintenance_task_details_logging
   @task_detail_id = @task_detail_id_insert,
   @database_name = @name,
   @step_name = 'Backup database',
   @start_time = @start_time_task,
   @end_time = @end_time_task,
   @error_number = @error_number,
   @error_severity = @error_severity,
   @error_message = @error_message,
   @succeeded = 0;
 END CATCH
 
 -- Verify backup database
 SET @sql = 'EXEC dbo.dba_verif_backup_databases ''' + @pathbackup + '''' 
 
 IF @debug = 1
 BEGIN
  PRINT 'Verify backup database for ' + @name
  PRINT @sql;
 END
 
 BEGIN TRY
  -- Record start time for the verif backup database task
  SET @start_time_task = GETDATE();
 
  EXEC(@sql);
  
  -- Record log for the create folder task
  SET @end_time_task = GETDATE();
  
  EXEC dbo.dba_maintenance_task_details_logging
   @task_detail_id = @task_detail_id_insert,
   @database_name = @name,
   @step_name = 'Verification of database backup',
   @start_time = @start_time_task,
   @end_time = @end_time_task,
   @succeeded = 1;
 END TRY
 BEGIN CATCH
  -- Count number of errors
  SET @nb_errors = @nb_errors + 1;
  
  -- Record log for the create folder task
  SET @end_time_task = GETDATE();
  
  SET @error_number = ERROR_NUMBER();
  SET @error_severity = ERROR_SEVERITY();
  SET @error_message = ERROR_MESSAGE();
  
  EXEC dbo.dba_maintenance_task_details_logging
   @task_detail_id = @task_detail_id_insert,
   @database_name = @name,
   @step_name = 'Verification of database backup',
   @start_time = @start_time_task,
   @end_time = @end_time_task,
   @error_number = @error_number,
   @error_severity = @error_severity,
   @error_message = @error_message,
   @succeeded = 0;
 END CATCH
       
 SET @i += 1;
END

-- Record log for the backup user job
SET @end_time = GETDATE();

IF @nb_errors > 0 
 SET @succeeded = 0;
  
EXEC dbo.dba_maintenance_task_logging
 @operation = 'U',
 @task_name = 'dba_backup_user_databases',
 @end_time = @end_time,
 @succeeded = @succeeded,
 @task_detail_id_update = @task_detail_id_insert;

GO
/****** Object:  StoredProcedure [dbo].[dba_integrity_system_databases_alwayson]    Script Date: 1/14/2015 11:32:35 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[dba_integrity_system_databases_alwayson]  
AS  
  
/**********************************************************  
 * @author = David BARBARIN - Pragmantic SA               *  
 * @Procedure = dba_integrity_system_databases            *  
 * @Description =                                         *  
 * Verification of integrity of the system databases      *  
 **********************************************************/  
  
SET NOCOUNT ON;  

-- DEBUG PARAMETERS
DECLARE @debug BIT = 0;

-- ERROR PARAMETERS
DECLARE @error_line INT;
DECLARE @error_number INT;
DECLARE @error_severity INT;
DECLARE @error_state INT;
DECLARE @error_message NVARCHAR(2048);

-- LOG PARAMETERS
DECLARE @start_time DATETIME;
DECLARE @end_time DATETIME;
DECLARE @start_time_task DATETIME;
DECLARE @end_time_task DATETIME;
DECLARE @nb_errors INT = 0;
DECLARE @succeeded BIT = 1;
DECLARE @task_detail_id_insert BIGINT;
  
-- WORK TABLES
DECLARE @t_database TABLE    
(    
 id INT IDENTITY(1,1),    
 database_name SYSNAME    
);    
    
INSERT @t_database (database_name)    
SELECT name    
FROM sys.databases    
WHERE database_id <= 4 -- System databases    
 AND name <> 'tempdb' 
    
DECLARE @i INT = 1;    
DECLARE @max INT = (SELECT COUNT(*) FROM @t_database);   
DECLARE @name SYSNAME;   
DECLARE @sql VARCHAR(8000);   

-- Record start time for the database integrity job
SET @start_time = GETDATE();

EXEC dbo.dba_maintenance_task_logging
 @operation = 'I',
 @task_name = 'dba_integrity_system_databases',
 @start_time = @start_time,
 @task_detail_id_insert = @task_detail_id_insert OUTPUT;
 
  
    
WHILE @i <= @max    
BEGIN    
 SET @name = (SELECT database_name FROM @t_database    
              WHERE id = @i);  
                
 IF @debug = 1
 BEGIN               
  PRINT 'Verify integrity of ' + @name  
  PRINT 'DBCC CHECKDB(''' + @name+ ''') WITH NO_INFOMSGS;'  
 END
   
 /* Verify integrity of the concerned database */  
 BEGIN TRY
  -- Record start time for the database integrity task
  SET @start_time_task = GETDATE();

  EXEC('DBCC CHECKDB(''' + @name+ ''') WITH NO_INFOMSGS');  

  -- Record log for the create folder task
  SET @end_time_task = GETDATE();
  
  EXEC dbo.dba_maintenance_task_details_logging
   @task_detail_id = @task_detail_id_insert,
   @database_name = @name,
   @step_name = 'Integrity database check',
   @start_time = @start_time_task,
   @end_time = @end_time_task,
   @succeeded = 1;
 END TRY
 BEGIN CATCH
  -- Count number of errors
  SET @nb_errors = @nb_errors + 1;
  
  SET @error_number = ERROR_NUMBER();
  SET @error_severity = ERROR_SEVERITY();
  SET @error_message = ERROR_MESSAGE();
  
  -- Record log for the create folder task
  SET @end_time_task = GETDATE();
  
  EXEC dbo.dba_maintenance_task_details_logging
   @task_detail_id = @task_detail_id_insert,
   @database_name = @name,
   @step_name = 'Integrity database check',
   @start_time = @start_time_task,
   @end_time = @end_time_task,
   @error_number = @error_number,
   @error_severity = @error_severity,
   @error_message = @error_message,
   @succeeded = 0;
 END CATCH 
   
 SET @i += 1;    
END

-- Record log for the database integrity job
SET @end_time = GETDATE();

IF @nb_errors > 0 
 SET @succeeded = 0;
  
EXEC dbo.dba_maintenance_task_logging
 @operation = 'U',
 @task_name = 'dba_integrity_system_databases',
 @end_time = @end_time,
 @succeeded = @succeeded,
 @task_detail_id_update = @task_detail_id_insert;
GO
/****** Object:  StoredProcedure [dbo].[dba_integrity_user_databases_alwayson]    Script Date: 1/14/2015 11:32:35 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[dba_integrity_user_databases_alwayson]  
AS  
  
/**********************************************************  
 * @author = David BARBARIN - Pragmantic SA               *  
 * @Procedure = dba_integrity_user_databases              *  
 * @Description =                                         *  
 * Verification of integrity of the all available user    *  
 * databases                                              *  
 * --> online = true                                      *  
 **********************************************************/  
  
SET NOCOUNT ON; 

-- DEBUG PARAMETER
DECLARE @debug BIT = 0; 

-- ERROR PARAMETERS
DECLARE @error_line INT;
DECLARE @error_number INT;
DECLARE @error_severity INT;
DECLARE @error_state INT;
DECLARE @error_message NVARCHAR(2048);

-- LOG PARAMETERS
DECLARE @start_time DATETIME;
DECLARE @end_time DATETIME;
DECLARE @start_time_task DATETIME;
DECLARE @end_time_task DATETIME;
DECLARE @nb_errors INT = 0;
DECLARE @succeeded BIT = 1;
DECLARE @task_detail_id_insert BIGINT;
  
-- WORK TABLES
DECLARE @t_database TABLE    
(    
 id INT IDENTITY(1,1),    
 database_name SYSNAME    
);   

DECLARE @T_CHECKDB TABLE
(
 Error INT, 
 [Level] INT,
 [State] INT,
 MessageText NVARCHAR(MAX),
 RepairLevel VARCHAR(100),
 [Status] INT,
 [DbId] INT,
 ObjectId BIGINT,
 IndexId INT,
 PartitionId BIGINT,
 AllocUnitId BIGINT,
 [File] INT,
 Page INT,
 Slot INT,
 RefFile INT,
 RefPage INT,
 RefSlot INT,
 Allocation INT
); 
    
INSERT @t_database (database_name)    
SELECT d.name
FROM sys.databases AS d
 LEFT JOIN sys.dm_hadr_availability_replica_states AS r
  ON r.replica_id = d.replica_id
 LEFT JOIN sys.availability_replicas AS rp
  ON rp.replica_id = r.replica_id
 LEFT JOIN sys.availability_groups AS g
  ON g.group_id = rp.group_id
WHERE d.database_id > 4  -- System databases 
 AND d.[state] = 0 -- databases online only   
  AND (sys.fn_hadr_backup_is_preferred_replica(d.name) = 1 -- databases that will be backuped
       OR r.role_desc = 'PRIMARY')                         -- or that are concerned by a primary replica
    
DECLARE @i INT = 1;    
DECLARE @max INT = (SELECT COUNT(*) FROM @t_database);   
DECLARE @name SYSNAME;   
DECLARE @sql VARCHAR(8000);  


-- Record start time for the database integrity job
SET @start_time = GETDATE();

EXEC dbo.dba_maintenance_task_logging
 @operation = 'I',
 @task_name = 'dba_integrity_user_databases',
 @start_time = @start_time,
 @task_detail_id_insert = @task_detail_id_insert OUTPUT;
   
    
WHILE @i <= @max    
BEGIN    
 SET @name = (SELECT database_name FROM @t_database    
              WHERE id = @i);  
          
 IF @debug = 1
 BEGIN      
  PRINT 'Verify integrity of ' + @name  
  PRINT 'DBCC CHECKDB(''' + @name+ ''') WITH NO_INFOMSGS'  
 END
 
 -- Record start time for the database integrity task
 SET @start_time_task = GETDATE();

 -- Verify integrity of the concerned database  
 INSERT @T_CHECKDB
 EXEC('DBCC CHECKDB(''' + @name+ ''') WITH NO_INFOMSGS, ALL_ERRORMSGS, TABLERESULTS'); 
 
 SET @error_number = @@ROWCOUNT;
 
 IF @error_number = 0
 BEGIN
  -- Record log for the create folder task
  SET @end_time_task = GETDATE();
  
  EXEC dbo.dba_maintenance_task_details_logging
   @task_detail_id = @task_detail_id_insert,
   @database_name = @name,
   @step_name = 'Integrity database check',
   @start_time = @start_time_task,
   @end_time = @end_time_task,
   @succeeded = 1;
 END 
 ELSE
 BEGIN
  -- Count number of errors
  SET @nb_errors = @nb_errors + 1;
  
  SET @error_number = ERROR_NUMBER();
  SET @error_severity = ERROR_SEVERITY();
  SET @error_message = ERROR_MESSAGE();
  
  -- Record log for the create folder task
  SET @end_time_task = GETDATE();
  
  EXEC dbo.dba_maintenance_task_details_logging
   @task_detail_id = @task_detail_id_insert,
   @database_name = @name,
   @step_name = 'Integrity database check',
   @start_time = @start_time_task,
   @end_time = @end_time_task,
   @error_number = @error_number,
   @error_severity = NULL,
   @error_message = 'Error integrity check',
   @succeeded = 0;
  
 END   
   
 SET @i += 1;    
END

-- Record log for the database integrity job
SET @end_time = GETDATE();

IF @nb_errors > 0 
 SET @succeeded = 0;
  
EXEC dbo.dba_maintenance_task_logging
 @operation = 'U',
 @task_name = 'dba_integrity_user_databases',
 @end_time = @end_time,
 @succeeded = @succeeded,
 @task_detail_id_update = @task_detail_id_insert;
GO
/****** Object:  StoredProcedure [dbo].[dba_maintenance_mail]    Script Date: 1/14/2015 11:32:35 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO



CREATE PROCEDURE [dbo].[dba_maintenance_mail]
(
 @profile_mail SYSNAME = 'dba',
 @subject_mail NVARCHAR(255),
 @body_mail NVARCHAR(MAX),
 @procedure_name VARCHAR(50)
)
AS
/**********************************************************
 * @author = David BARBARIN - Pragmantic SA               *
 * @Procedure = dba_maintenance_mail                      *
 * @Description =                                         *
 * Send email to the operator when a maintenance task     *
 * fails                                                  *
 **********************************************************/

SET NOCOUNT ON;

DECLARE @operators VARCHAR(1000);

/* Operators for sendmail */
IF EXISTS (SELECT 1 from msdb.dbo.sysoperators)
BEGIN
 SELECT @operators = email_address 
 FROM msdb.dbo.sysoperators
 WHERE name = 'dba'
END
ELSE 
BEGIN
 SELECT @operators = value 
 FROM dbo.dba_maintenance_configuration 
 WHERE parameter = 'operator_email';
END

-- If no operators configured sending maintenance mail is not performed
IF @operators IS NULL OR LEN(@operators) = 0
BEGIN
 RAISERROR('No operators are configured for sending maintenance mails.', 16, 1);
 RETURN;
END

-- If no insentia profile is configured send maintenance mail is not performance
IF NOT EXISTS(SELECT 1 FROM msdb.dbo.sysmail_profile
              WHERE name = 'dba')
BEGIN
 RAISERROR('No databasemail dba profil is configured for sending maintenance mails.', 16, 1);
 RETURN;
END

  
-- Verification if errors exist for the concerned procedure
IF EXISTS (SELECT 1 FROM dbo.dba_maintenance_task_logs 
           WHERE task_name = @procedure_name AND sent_by_email IS NULL
            AND (succeeded = 0 OR succeeded IS NULL))
BEGIN
 DECLARE @servername SYSNAME = @@SERVERNAME;
 SET @subject_mail = COALESCE(@@SERVERNAME, ' ') + ' -  ' + @subject_mail; 
 SET @body_mail = COALESCE(@@SERVERNAME, ' ') + CHAR(13) + CHAR(13) + @body_mail

 /* Send Email */
 EXEC msdb.dbo.sp_send_dbmail
  @profile_name = @profile_mail,
  @recipients = @operators,
  @importance = 'HIGH',
  @subject = @subject_mail,
  @body = @body_mail;
  
END

/* Update table dbo.dba_maintenance_task_logs */
UPDATE dbo.dba_maintenance_task_logs
 SET sent_by_email = CASE succeeded 
                      WHEN 1 THEN 0
                      ELSE 1
                     END  
WHERE task_name = @procedure_name
 AND sent_by_email IS NULL;



GO
/****** Object:  StoredProcedure [dbo].[dba_maintenance_task_details_logging]    Script Date: 1/14/2015 11:32:35 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[dba_maintenance_task_details_logging]
(
 @task_detail_id BIGINT,
 @database_name SYSNAME,
 @step_name VARCHAR(50),
 @start_time DATETIME,
 @end_time DATETIME,
 @error_number INT = NULL,
 @error_severity INT = NULL,
 @error_message NVARCHAR(MAX) = NULL,
 @succeeded BIT
)
AS


-- INSERT DETAIL LOG
INSERT dbo.dba_maintenance_task_details_logs (task_detail_id, database_name, step_name, start_time, end_time, [error_number], [error_severity], [error_message], succeeded) 
 VALUES (@task_detail_id, @database_name, @step_name, @start_time, @end_time, @error_number, @error_severity, @error_message, @succeeded);


GO
/****** Object:  StoredProcedure [dbo].[dba_maintenance_task_logging]    Script Date: 1/14/2015 11:32:35 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[dba_maintenance_task_logging]
(
 @operation CHAR(1),
 @task_name VARCHAR(50),
 @start_time DATETIME = NULL,
 @end_time DATETIME = NULL,
 @succeeded BIT = NULL,
 @task_detail_id_update BIGINT = NULL,
 @task_detail_id_insert BIGINT = -1 OUTPUT
)
AS

IF @operation NOT IN ('I', 'U')
BEGIN
 RAISERROR('@operation must be one of the following : I, U', 16, 1);  
 RETURN; 
END

IF @operation = 'I' AND @start_time IS NULL
BEGIN
 RAISERROR('For @operation = ''I'' @start_time cannot be null', 16, 1);  
 RETURN; 
END

IF @operation = 'U' AND (@end_time IS NULL OR @task_detail_id_update IS NULL OR @succeeded IS NULL)
BEGIN
 RAISERROR('For @operation = ''U'' @end_time or @task_detail_id_update or @succeeded cannot be null', 16, 1);  
 RETURN; 
END

-- INSERT GENERAL LOG
IF @operation = 'I'
BEGIN
 INSERT dbo.dba_maintenance_task_logs (task_name, start_time, end_time, succeeded) 
 VALUES (@task_name, @start_time, @end_time, NULL);

 -- RETURN the task_detail_id inserted in the execution procedure context
 SET @task_detail_id_insert = SCOPE_IDENTITY();
END
ELSE
BEGIN
 UPDATE dbo.dba_maintenance_task_logs
 SET end_time = @end_time,
     succeeded = @succeeded
 WHERE task_detail_id = @task_detail_id_update;
 
 --SET @task_detail_id_insert = -1;
END
GO
/****** Object:  StoredProcedure [dbo].[dba_maintenance_user_databases_alwayson]    Script Date: 1/14/2015 11:32:35 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[dba_maintenance_user_databases_alwayson]    
AS   
  
  
/**********************************************************  
 * @author = David BARBARIN - Pragmantic SA               *  
 * @Procedure = dba_maintenance_user_databases            *  
 * @Description =                                         *  
 * step 1 :                                               *  
 * Reorganize / Rebuild indexes depending of the general  *  
 * fragmentation of the indexes                           *  
 * step 2 :                                               *  
 * update all necessary statistics                        *     
 **********************************************************/   
    
SET NOCOUNT ON;   

-- DEBUG
DECLARE @debug BIT = 0;

-- CONFIGURATION PARAMETERS
DECLARE @scan_frag_index VARCHAR(10) = (SELECT value FROM dbo.dba_maintenance_configuration WHERE parameter = 'scan_frag_index');
DECLARE @index_fillfactor VARCHAR(10) = (SELECT value FROM dbo.dba_maintenance_configuration WHERE parameter = 'index_fillfactor');
DECLARE @index_sort_in_tempdb VARCHAR(3) = (SELECT value FROM dbo.dba_maintenance_configuration WHERE parameter = 'index_sort_in_tempdb');
DECLARE @index_rebuild_online VARCHAR(3) = (SELECT value FROM dbo.dba_maintenance_configuration WHERE parameter = 'index_rebuild_online');
DECLARE @index_defrag_threshold TINYINT = (SELECT value FROM dbo.dba_maintenance_configuration WHERE parameter = 'index_defrag_threshold');
DECLARE @index_rebuild_threshold TINYINT = (SELECT value FROM dbo.dba_maintenance_configuration WHERE parameter = 'index_rebuild_threshold');

-- VERSION PARAMETER
DECLARE @edition_check INT = CAST(SERVERPROPERTY('EngineEdition') AS TINYINT); -- 3 = Enterprise (This is returned for Enterprise, Enterprise Evaluation, and Developer.)

-- ERROR PARAMETERS
DECLARE @error_line INT;
DECLARE @error_number INT;
DECLARE @error_severity INT;
DECLARE @error_state INT;
DECLARE @error_message NVARCHAR(2048); 

-- LOG PARAMETERS
DECLARE @start_time DATETIME;
DECLARE @end_time DATETIME;
DECLARE @start_time_task DATETIME;
DECLARE @end_time_task DATETIME;
DECLARE @nb_errors INT = 0;
DECLARE @succeeded BIT = 1;
DECLARE @task_detail_id_insert BIGINT;

-- WORKTABLES
DECLARE @t_database TABLE    
(    
 id INT IDENTITY(1,1), 
 database_id INT,   
 database_name SYSNAME    
);   

IF OBJECT_ID('tempdb.dbo.#t_index') IS NOT NULL
 DROP TABLE #t_index;
 
CREATE TABLE #t_index     
(    
  id INT IDENTITY(1,1) PRIMARY KEY,
  database_id INT,
  database_name SYSNAME,
  [schema_name] SYSNAME,
  [object_id] INT,    
  [object_name] SYSNAME, 
  index_id INT,   
  index_name SYSNAME,    
  partition_number INT,
  avg_fragmentation_in_percent FLOAT,
  index_type TINYINT NULL,
  lob_columns BIT NULL,
  partitionned_index BIT NULL
);    
 
INSERT @t_database (database_id, database_name)    
SELECT d.database_id, d.name
FROM sys.databases AS d
 LEFT JOIN sys.dm_hadr_availability_replica_states AS r
  ON r.replica_id = d.replica_id
 LEFT JOIN sys.availability_replicas AS rp
  ON rp.replica_id = r.replica_id
 LEFT JOIN sys.availability_groups AS g
  ON g.group_id = rp.group_id
WHERE d.database_id > 4  -- System databases 
 AND d.[state] = 0 -- databases online only   
  AND (r.role_desc IS NULL -- not concerned by a availability group
       OR r.role_desc = 'PRIMARY') -- or that are concerned by a primary replica 

-- DEBUG
IF @debug = 1
BEGIN
 SELECT *
 FROM @t_database;
END 
    
DECLARE @i INT = 1;    
DECLARE @max INT = (SELECT COUNT(*) FROM @t_database);    
DECLARE @name SYSNAME; 
DECLARE @id INT;   
DECLARE @sql_index VARCHAR(MAX);    
DECLARE @sql_stats VARCHAR(MAX) = '';


-- Record start time for the database maintenance inex job
SET @start_time = GETDATE();

EXEC dbo.dba_maintenance_task_logging
 @operation = 'I',
 @task_name = 'dba_maintenance_user_databases_index',
 @start_time = @start_time,
 @task_detail_id_insert = @task_detail_id_insert OUTPUT;



/* Construct sqlstatements for indexes maintenance and update statistics */
WHILE @i <= @max    
BEGIN   
 
 SELECT
  @id = database_id, 
  @name = database_name
 FROM @t_database    
 WHERE id = @i;    
 
  -- Record start time for the index maintenance task
 SET @start_time_task = GETDATE();
 
 SET @sql_index = '
	 SELECT  
	  P.database_id,
	  ''' + @name + ''',  
	  SCH.name AS [schema_name], 
	  O.[object_id],   
	  O.name AS [object_name],  
	  I.index_id,  
	  I.name AS index_name,    
	  P.partition_number,
	  AVG(P.avg_fragmentation_in_percent) AS avg_fragmentation_in_percent
	 FROM sys.dm_db_index_physical_stats(' + CAST(@id AS VARCHAR(10)) + ', NULL, NULL, NULL, ''' + @scan_frag_index + ''') AS P    
	 INNER JOIN [' + @name + '].sys.objects AS O     
	  ON P.[object_id] = O.[object_id]    
	 INNER JOIN [' + @name + '].sys.indexes AS I    
	  ON O.[object_id] = I.[object_id] 
	   AND P.index_id = I.index_id   
	 INNER JOIN [' + @name + '].sys.schemas AS SCH    
	  ON O.[schema_id] = SCH.[schema_id]    
	 WHERE P.index_id > 0    
	  AND P.page_count > 1000   
	   AND P.avg_fragmentation_in_percent >= 10  
	 GROUP BY P.database_id, SCH.name, O.[object_id], O.name, I.index_id, I.name, P.partition_number';
       
 INSERT #t_index (database_id, database_name, [schema_name], [object_id], [object_name], index_id, index_name, partition_number, avg_fragmentation_in_percent)  
 EXEC(@sql_index);
 
 -- step 1 - Verify if the index is an xml or spatial index / or index composed with a lob column  
 SET @sql_index = '
 UPDATE TI
  SET index_type = I.[type] -- 0 = Heap, 1 = Clustered, 2 = Nonclustered, 3 = XML, 4 = Spatial
 FROM #t_index AS TI
 INNER JOIN [' + @name + '].sys.indexes AS I 
  ON I.[object_id] = TI.[object_id]
   AND I.index_id = TI.index_id';
  
 EXEC(@sql_index); 
   
 -- step 2 - Verify if no special indexes have a special data type 
 -- system_type_id --> 34 = image, 35 = text, 99 = ntext
 -- max_length = -1 --> varbinary(max), varchar(max), nvarchar(max), xml
 SET @sql_index = '
 UPDATE TI 
  SET lob_columns = 1
 FROM #t_index TI
 WHERE EXISTS (SELECT * FROM [' + @name + '].sys.columns AS C
               WHERE C.[object_id] = TI.[object_id]
                AND (C.system_type_id IN (34, 35, 99) OR C.max_length = -1) 
                 AND TI.index_type IN (1, 2))';
                 
 EXEC(@sql_index);          
 
 -- step 3 - Mark partitionned indexes 
 UPDATE TI
  SET partitionned_index = 1
 FROM #t_index TI
 INNER JOIN (SELECT database_id, [schema_name], [object_id], index_id
             FROM #t_index 
             GROUP BY database_id, [schema_name], [object_id], index_id
             HAVING MAX(partition_number) > 1) AS TI2
  ON TI2.database_id = TI.database_id
   AND TI2.[schema_name] = TI.[schema_name]
    AND TI2.[object_id] = TI.[object_id]
     AND TI2.index_id = TI.index_id;
     
 -- step 4 - Construct update statistics statement */
 SET @sql_stats = @sql_stats + 'USE [' + @name + ']; EXEC sp_updatestats;' + CHAR(10);
 
 /* DEBUG */
 IF @debug = 1 SELECT * FROM #t_index;

 SET @sql_index = '';

 -- Non partitionned indexes 
 SELECT 
  @sql_index = @sql_index + 
  'ALTER INDEX [' + index_name + '] ON [' + database_name + '].[' + [schema_name] + '].[' + [object_name] + '] ' + 
  CASE 
   WHEN avg_fragmentation_in_percent BETWEEN @index_defrag_threshold AND @index_rebuild_threshold THEN 'REORGANIZE'
   ELSE 'REBUILD WITH (FILLFACTOR = ' + @index_fillfactor + ', SORT_IN_TEMPDB = ' + @index_sort_in_tempdb + '' + 
    CASE @index_rebuild_online 
     WHEN 'OFF' THEN ', ONLINE = OFF)'
     ELSE CASE 
          WHEN (index_type IN (1, 2)) AND (lob_columns IS NULL) AND (@edition_check = 3) THEN ', ONLINE = ON)'
          ELSE ', ONLINE = OFF)'
         END
    END
  END + CHAR(10)
 FROM #t_index
 WHERE partitionned_index IS NULL;

 -- Partitionned indexes --> always REORGANIZE */
 SELECT 
  @sql_index = @sql_index + 
  'ALTER INDEX [' + index_name + '] ON [' + database_name + '].[' + [schema_name] + '].[' + [object_name] + '] ' + 
  CASE 
   WHEN avg_fragmentation_in_percent BETWEEN @index_defrag_threshold AND @index_rebuild_threshold THEN 'REORGANIZE PARTITION = ' + CAST(partition_number AS VARCHAR(10))+ ''
   ELSE 'REBUILD PARTITION = ' + CAST(partition_number AS VARCHAR(10)) + ' WITH (SORT_IN_TEMPDB = ' + @index_sort_in_tempdb + ')' 
   END + CHAR(10)
 FROM #t_index
 WHERE partitionned_index = 1;

 /* DEBUG */
 IF @debug = 1 PRINT @sql_index;
 IF @debug = 1 PRINT @sql_stats;

 /* Rebuild / reorganize indexes */
 BEGIN TRY
  EXEC(@sql_index);
  EXEC(@sql_stats);

  -- Record log for the maintenance index task
  SET @end_time_task = GETDATE();

  EXEC dbo.dba_maintenance_task_details_logging
   @task_detail_id = @task_detail_id_insert,
   @database_name = @name,
   @step_name = 'dba_maintenance_user_databases_index',
   @start_time = @start_time_task,
   @end_time = @end_time_task,
   @succeeded = 1;
 END TRY
 BEGIN CATCH
  -- Count number of errors
  SET @nb_errors = @nb_errors + 1;
  
  -- Record log for the create folder task
  SET @end_time_task = GETDATE();
  
  SET @error_number = ERROR_NUMBER();
  SET @error_severity = ERROR_SEVERITY();
  SET @error_message = ERROR_MESSAGE();
  
  EXEC dbo.dba_maintenance_task_details_logging
   @task_detail_id = @task_detail_id_insert,
   @database_name = @name,
   @step_name = 'dba_maintenance_user_databases_index',
   @start_time = @start_time_task,
   @end_time = @end_time_task,
   @error_number = @error_number,
   @error_severity = @error_severity,
   @error_message = @error_message,
   @succeeded = 0;
 END CATCH

 -- Drop index entries into the #t_index table
 TRUNCATE TABLE #t_index;

 SET @i += 1;    
END 

-- Record log for the database integrity job
SET @end_time = GETDATE();

IF @nb_errors > 0 
 SET @succeeded = 0;
  
EXEC dbo.dba_maintenance_task_logging
 @operation = 'U',
 @task_name = 'dba_maintenance_user_databases_index',
 @end_time = @end_time,
 @succeeded = @succeeded,
 @task_detail_id_update = @task_detail_id_insert;

GO
/****** Object:  StoredProcedure [dbo].[dba_retention_backup_alwayson]    Script Date: 1/14/2015 11:32:35 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[dba_retention_backup_alwayson]  
(  
 @type CHAR(3)  
)  
AS 


/**********************************************************
 * @author = David BARBARIN - Pragmantic SA               *
 * @Procedure = dba_maintenance_user_databases            *
 * @Description =                                         *
 * Delete all backups (BAK and TRN) regarding the         *
 * retention configuration value                          * 
 * @Parameters =                                          *
 * @type = backup type to delete CHAR(3)                  * 
 **********************************************************/  
  
IF @type NOT IN ('BAK', 'TRN')  
BEGIN  
 RAISERROR('@type must be one of the following : BAK, TRN or TXT', 16, 1);  
 RETURN;  
END 

SET NOCOUNT ON;

-- DEBUG
DECLARE @debug BIT = 0;

-- Get backup path  
DECLARE @pathbackup VARCHAR(1000) = (SELECT value FROM dbo.dba_maintenance_configuration WHERE parameter = 'backupdir');  
DECLARE @backupdir VARCHAR(2000);
DECLARE @folderexists INT;

DECLARE @t_folderexists TABLE
(
 file_exists INT,
 file_is_a_directory INT,
 parent_directory_exists INT
)

SET @pathbackup = LEFT(@pathbackup, LEN(@pathbackup) - 1);  
  
-- Get retention value (in days)  
DECLARE @nb_jours INT = (SELECT value FROM dbo.dba_maintenance_configuration WHERE parameter = 'backup retention');  
  
DECLARE @sql VARCHAR(MAX);  
DECLARE @date_retention DATETIME = GETDATE() - @nb_jours;   

DECLARE @t_aag TABLE
(
 id INT IDENTITY(1,1),
 aag_name SYSNAME NULL
);

INSERT @t_aag
SELECT DISTINCT g.name
FROM sys.databases AS d
 LEFT JOIN sys.dm_hadr_availability_replica_states AS r
  ON r.replica_id = d.replica_id
 LEFT JOIN sys.availability_groups AS g
  ON g.group_id = r.group_id
WHERE --d.database_id > 4 -- System databases
 d.[state] = 0 -- Databases online only
   AND sys.fn_hadr_backup_is_preferred_replica(d.name) = 1; -- replica is the preferred backup replica

DECLARE @i INT = 1;  
DECLARE @max INT = (SELECT COUNT(*) FROM @t_aag); 
DECLARE @aag_name SYSNAME;

WHILE @i <= @max  
BEGIN  
 SELECT @aag_name = aag_name
 FROM @t_aag
 WHERE id = @i;

 IF (@aag_name IS NULL)
 BEGIN
  SET @backupdir = @pathbackup + '\' + @@SERVERNAME;
 END
 ELSE
 BEGIN
  SET @backupdir =  @pathbackup + '\AAG_' + @aag_name;
 END

 -- Verification of the path before deletion
 INSERT @t_folderexists
 EXEC master.dbo.xp_fileexist @backupdir;

 SELECT @folderexists = file_is_a_directory
 FROM @t_folderexists

 IF @folderexists = 1
 BEGIN
  SET @sql = 'EXECUTE master.dbo.xp_delete_file 0,''' + + @backupdir + ''',N''' + @type + ''',N''' + CONVERT(VARCHAR, @date_retention, 127) + ''',1';

  -- DEBUG
  IF @debug = 1
  BEGIN
   PRINT @sql;
  END

  EXEC(@sql);
 END
 ELSE
 BEGIN
  PRINT 'The path ' + @backupdir + ' does not exist';
 END 

 DELETE FROM @t_folderexists;

 SET @i += 1;
END


  
 

GO
/****** Object:  StoredProcedure [dbo].[dba_retention_logs_alwayson]    Script Date: 1/14/2015 11:32:35 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[dba_retention_logs_alwayson]
(
 @nb_jours INT
)
AS

/**********************************************************
 * @author = David BARBARIN - Pragmantic SA               *
 * @Procedure = dba_retention_logs                        *
 * @Description =                                         *
 * Delete all log records before a threshold date         *
 * retention configuration value                          * 
 * @Parameters =                                          *
 * @nb_jours = Nombre de jours pour la rétention          *
 **********************************************************/
  
DECLARE @date_retention DATETIME = GETDATE() - @nb_jours; 

-- Delete log from details table
DELETE FROM [dbo].[dba_maintenance_task_details_logs] 
WHERE EXISTS (SELECT 1 FROM [dbo].[dba_maintenance_task_logs] AS t
              WHERE t.task_detail_id = task_detail_id
			   AND t.start_time <= @date_retention)

-- Delete log from header table
DELETE FROM [dbo].[dba_maintenance_task_logs]
WHERE start_time <= @date_retention;

GO
/****** Object:  StoredProcedure [dbo].[dba_verif_backup_databases]    Script Date: 1/14/2015 11:32:35 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE PROCEDURE [dbo].[dba_verif_backup_databases]
(
 @backupdir VARCHAR(1000)
)
AS

/**********************************************************
 * @author = David BARBARIN - Pragmantic SA               *
 * @Procedure = dba_maintenance_user_databases            *
 * @Description =                                         *
 * Verify the generated backup (BAK or TRN)               *
 * --> checksum option                                    *
 * @Parameters =                                          *
 * @backupdir = path of the backup                        * 
 **********************************************************/  

SET NOCOUNT ON;

-- DEBUG PARAMETER
DECLARE @debug BIT = 0;

-- CONFIGURATION PARAMETERS
DECLARE @backup_integrity_checksum VARCHAR(10) = (SELECT value FROM dbo.dba_maintenance_configuration WHERE parameter = 'backup_integrity_checksum');


DECLARE @sql VARCHAR(200) = 'RESTORE VERIFYONLY FROM DISK = ''' 
                             + @backupdir + '''' + CASE @backup_integrity_checksum WHEN 'CHECKSUM' THEN ' WITH CHECKSUM;' ELSE ';' END;
        
IF @debug = 1
BEGIN
 PRINT 'Verification of the backup ' + @backupdir;        
 PRINT @sql; 
END

EXEC(@sql);

GO
/****** Object:  Table [dbo].[dba_alwayson_failover_logs]    Script Date: 1/14/2015 11:32:35 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
SET ANSI_PADDING ON
GO
CREATE TABLE [dbo].[dba_alwayson_failover_logs](
	[event_time] [datetime] NULL CONSTRAINT [DF__test__event_time__5BE2A6F2]  DEFAULT (getdate()),
	[group_name] [sysname] NOT NULL,
	[primary_replica_old] [varchar](128) NULL,
	[primary_replica_new] [varchar](128) NOT NULL,
	[primary_recovery_health] [nvarchar](80) NULL,
	[sent_by_email] [bit] NULL
) ON [PRIMARY]

GO
SET ANSI_PADDING OFF
GO
/****** Object:  Table [dbo].[dba_maintenance_configuration]    Script Date: 1/14/2015 11:32:35 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
SET ANSI_PADDING ON
GO
CREATE TABLE [dbo].[dba_maintenance_configuration](
	[parameter] [varchar](100) NULL,
	[value] [varchar](100) NULL,
	[description] [varchar](200) NULL
) ON [PRIMARY]

GO
SET ANSI_PADDING OFF
GO
/****** Object:  Table [dbo].[dba_maintenance_task_details_logs]    Script Date: 1/14/2015 11:32:35 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
SET ANSI_PADDING ON
GO
CREATE TABLE [dbo].[dba_maintenance_task_details_logs](
	[task_detail_id] [bigint] NOT NULL,
	[database_name] [sysname] NOT NULL,
	[step_name] [varchar](50) NOT NULL,
	[start_time] [datetime] NOT NULL,
	[end_time] [datetime] NOT NULL,
	[error_number] [int] NULL,
	[error_severity] [int] NULL,
	[error_message] [nvarchar](max) NULL,
	[succeeded] [bit] NOT NULL
) ON [PRIMARY] TEXTIMAGE_ON [PRIMARY]

GO
SET ANSI_PADDING OFF
GO
/****** Object:  Table [dbo].[dba_maintenance_task_logs]    Script Date: 1/14/2015 11:32:35 AM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
SET ANSI_PADDING ON
GO
CREATE TABLE [dbo].[dba_maintenance_task_logs](
	[task_detail_id] [bigint] IDENTITY(1,1) NOT NULL,
	[task_name] [varchar](50) NOT NULL,
	[start_time] [datetime] NOT NULL,
	[end_time] [datetime] NULL,
	[succeeded] [bit] NULL,
	[sent_by_email] [bit] NULL
) ON [PRIMARY]

GO
SET ANSI_PADDING OFF
GO
/****** Object:  Index [IDX_CLST_dba_maintenance_task_logs_start_time]    Script Date: 1/14/2015 11:32:35 AM ******/
CREATE CLUSTERED INDEX [IDX_CLST_dba_maintenance_task_logs_start_time] ON [dbo].[dba_maintenance_task_logs]
(
	[start_time] DESC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_ba_maintenance_task_details_logs_task_detail_id]    Script Date: 1/14/2015 11:32:35 AM ******/
CREATE NONCLUSTERED INDEX [IDX_ba_maintenance_task_details_logs_task_detail_id] ON [dbo].[dba_maintenance_task_details_logs]
(
	[task_detail_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
/****** Object:  Index [IDX_task_detail_id]    Script Date: 1/14/2015 11:32:35 AM ******/
CREATE UNIQUE NONCLUSTERED INDEX [IDX_task_detail_id] ON [dbo].[dba_maintenance_task_logs]
(
	[task_detail_id] ASC
)WITH (PAD_INDEX = OFF, STATISTICS_NORECOMPUTE = OFF, SORT_IN_TEMPDB = OFF, IGNORE_DUP_KEY = OFF, DROP_EXISTING = OFF, ONLINE = OFF, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = ON) ON [PRIMARY]
GO
ALTER TABLE [dbo].[dba_maintenance_task_details_logs]  WITH CHECK ADD  CONSTRAINT [FK_ba_maintenance_tasks_details_log_task_detail_id] FOREIGN KEY([task_detail_id])
REFERENCES [dbo].[dba_maintenance_task_logs] ([task_detail_id])
GO
ALTER TABLE [dbo].[dba_maintenance_task_details_logs] CHECK CONSTRAINT [FK_ba_maintenance_tasks_details_log_task_detail_id]
GO
USE [master]
GO
ALTER DATABASE [DBA] SET  READ_WRITE 
GO
