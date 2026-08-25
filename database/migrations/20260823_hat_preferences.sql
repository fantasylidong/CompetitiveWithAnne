-- Add per-player hat wear/view/visibility preferences.
-- NULL lets the plugin migrate existing clientprefs values on first load.
-- Idempotent: each column is added only when missing.

SET @db := DATABASE();

SET @sql := (
  SELECT IF(
    COUNT(*) = 0,
    'ALTER TABLE `RPG` ADD COLUMN `HAT_ENABLED` tinyint(4) DEFAULT NULL AFTER `HAT`',
    'SELECT 1'
  )
  FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = @db AND TABLE_NAME = 'RPG' AND COLUMN_NAME = 'HAT_ENABLED'
);
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

SET @sql := (
  SELECT IF(
    COUNT(*) = 0,
    'ALTER TABLE `RPG` ADD COLUMN `HAT_VIEW_FIRST` tinyint(4) DEFAULT NULL AFTER `HAT_ENABLED`',
    'SELECT 1'
  )
  FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = @db AND TABLE_NAME = 'RPG' AND COLUMN_NAME = 'HAT_VIEW_FIRST'
);
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

SET @sql := (
  SELECT IF(
    COUNT(*) = 0,
    'ALTER TABLE `RPG` ADD COLUMN `HAT_VIEW_THIRD` tinyint(4) DEFAULT NULL AFTER `HAT_VIEW_FIRST`',
    'SELECT 1'
  )
  FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = @db AND TABLE_NAME = 'RPG' AND COLUMN_NAME = 'HAT_VIEW_THIRD'
);
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;

SET @sql := (
  SELECT IF(
    COUNT(*) = 0,
    'ALTER TABLE `RPG` ADD COLUMN `HAT_SHOW_OTHERS` tinyint(4) DEFAULT NULL AFTER `HAT_VIEW_THIRD`',
    'SELECT 1'
  )
  FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA = @db AND TABLE_NAME = 'RPG' AND COLUMN_NAME = 'HAT_SHOW_OTHERS'
);
PREPARE stmt FROM @sql;
EXECUTE stmt;
DEALLOCATE PREPARE stmt;
