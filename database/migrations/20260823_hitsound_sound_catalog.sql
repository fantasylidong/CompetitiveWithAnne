-- Public sound choices use -1..-127; legacy preset choices keep using positive IDs.
-- The four preference columns must therefore be signed integers.
-- For a custom sm_hitsound_db_table, run SET @hitsound_table = 'YourTable'; first.

SET @hitsound_schema = DATABASE();
SET @hitsound_table = IF(
  COALESCE(@hitsound_table, '') REGEXP '^[A-Za-z0-9_]+$',
  @hitsound_table,
  'RPG'
);

SET @hitsound_sql = IF(
  EXISTS(
    SELECT 1 FROM `information_schema`.`COLUMNS`
    WHERE `TABLE_SCHEMA` = @hitsound_schema
      AND `TABLE_NAME` = @hitsound_table
      AND `COLUMN_NAME` = 'hitsound_head'
      AND `COLUMN_TYPE` LIKE '%unsigned%'
  ),
  CONCAT('ALTER TABLE `', @hitsound_table, '` MODIFY COLUMN `hitsound_head` tinyint(4) NOT NULL DEFAULT 0'),
  'SELECT 1'
);
PREPARE hitsound_stmt FROM @hitsound_sql;
EXECUTE hitsound_stmt;
DEALLOCATE PREPARE hitsound_stmt;

SET @hitsound_sql = IF(
  EXISTS(
    SELECT 1 FROM `information_schema`.`COLUMNS`
    WHERE `TABLE_SCHEMA` = @hitsound_schema
      AND `TABLE_NAME` = @hitsound_table
      AND `COLUMN_NAME` = 'hitsound_hit'
      AND `COLUMN_TYPE` LIKE '%unsigned%'
  ),
  CONCAT('ALTER TABLE `', @hitsound_table, '` MODIFY COLUMN `hitsound_hit` tinyint(4) NOT NULL DEFAULT 0'),
  'SELECT 1'
);
PREPARE hitsound_stmt FROM @hitsound_sql;
EXECUTE hitsound_stmt;
DEALLOCATE PREPARE hitsound_stmt;

SET @hitsound_sql = IF(
  EXISTS(
    SELECT 1 FROM `information_schema`.`COLUMNS`
    WHERE `TABLE_SCHEMA` = @hitsound_schema
      AND `TABLE_NAME` = @hitsound_table
      AND `COLUMN_NAME` = 'hitsound_kill'
      AND `COLUMN_TYPE` LIKE '%unsigned%'
  ),
  CONCAT('ALTER TABLE `', @hitsound_table, '` MODIFY COLUMN `hitsound_kill` tinyint(4) NOT NULL DEFAULT 0'),
  'SELECT 1'
);
PREPARE hitsound_stmt FROM @hitsound_sql;
EXECUTE hitsound_stmt;
DEALLOCATE PREPARE hitsound_stmt;

SET @hitsound_sql = IF(
  EXISTS(
    SELECT 1 FROM `information_schema`.`COLUMNS`
    WHERE `TABLE_SCHEMA` = @hitsound_schema
      AND `TABLE_NAME` = @hitsound_table
      AND `COLUMN_NAME` = 'hitsound_headkill'
      AND `COLUMN_TYPE` LIKE '%unsigned%'
  ),
  CONCAT('ALTER TABLE `', @hitsound_table, '` MODIFY COLUMN `hitsound_headkill` tinyint(4) DEFAULT NULL'),
  'SELECT 1'
);
PREPARE hitsound_stmt FROM @hitsound_sql;
EXECUTE hitsound_stmt;
DEALLOCATE PREPARE hitsound_stmt;
