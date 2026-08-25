-- Add per-player hitsound playback preferences.
-- hitsound_headkill stores a legacy preset source (>0) or shared sound source (<0); 0 follows the regular headshot sound.
-- NULL lets the plugin migrate an existing player's SoundSelect.txt values on first load.
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
      AND `COLUMN_NAME` = 'hitsound_stack_mode'
  ),
  'SELECT 1',
  CONCAT('ALTER TABLE `', @hitsound_table, '` ADD COLUMN `hitsound_stack_mode` tinyint(4) DEFAULT NULL AFTER `hiticon_si_only`')
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
  ),
  'SELECT 1',
  CONCAT('ALTER TABLE `', @hitsound_table, '` ADD COLUMN `hitsound_headkill` tinyint(4) DEFAULT NULL AFTER `hitsound_stack_mode`')
);
PREPARE hitsound_stmt FROM @hitsound_sql;
EXECUTE hitsound_stmt;
DEALLOCATE PREPARE hitsound_stmt;
