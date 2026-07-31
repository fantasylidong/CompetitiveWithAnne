-- Map records v2 migration. Stop l4d_stats writes before running this file.
-- This migration is idempotent and preserves timedmaps/timedmap_runs unchanged.

CREATE TABLE IF NOT EXISTS `map_runs` (
  `run_id` varchar(64) CHARACTER SET ascii NOT NULL,
  `map` varchar(255) CHARACTER SET utf8mb4 NOT NULL,
  `gamemode` tinyint unsigned NOT NULL,
  `mutation` varchar(64) CHARACTER SET utf8mb4 NOT NULL DEFAULT '',
  `ruleset_key` varchar(64) CHARACTER SET ascii NOT NULL,
  `ruleset_version` varchar(64) CHARACTER SET utf8mb4 NOT NULL DEFAULT '',
  `record_policy` tinyint unsigned NOT NULL DEFAULT '2',
  `timing_profile` varchar(24) CHARACTER SET ascii NOT NULL DEFAULT 'completion',
  `difficulty_type` varchar(16) CHARACTER SET ascii NOT NULL DEFAULT 'game',
  `difficulty` tinyint unsigned NOT NULL DEFAULT '0',
  `duration_ms` bigint unsigned NOT NULL,
  `survivor_count` smallint unsigned NOT NULL DEFAULT '0',
  `infected_count` smallint unsigned NOT NULL DEFAULT '0',
  `si_count` smallint unsigned NOT NULL DEFAULT '0',
  `si_spawn_time` smallint unsigned NOT NULL DEFAULT '0',
  `usebuy` tinyint unsigned NOT NULL DEFAULT '0',
  `auto` tinyint unsigned NOT NULL DEFAULT '0',
  `legacy_mode` tinyint unsigned NOT NULL DEFAULT '0',
  `completed` tinyint unsigned NOT NULL DEFAULT '1',
  `valid` tinyint unsigned NOT NULL DEFAULT '1',
  `server_name` varchar(128) CHARACTER SET utf8mb4 NOT NULL DEFAULT '',
  `source` varchar(32) CHARACTER SET ascii NOT NULL DEFAULT 'native',
  `created` datetime NOT NULL,
  `modified` datetime NOT NULL,
  PRIMARY KEY (`run_id`),
  KEY `idx_map_runs_leaderboard` (`record_policy`,`completed`,`valid`,`ruleset_key`,`map`,`difficulty`,`duration_ms`),
  KEY `idx_map_runs_recent` (`ruleset_key`,`created`),
  KEY `idx_map_runs_map_recent` (`map`,`created`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `map_run_players` (
  `run_id` varchar(64) CHARACTER SET ascii NOT NULL,
  `steamid` varchar(255) CHARACTER SET utf8mb4 NOT NULL,
  `team` tinyint unsigned NOT NULL DEFAULT '2',
  `completed` tinyint unsigned NOT NULL DEFAULT '1',
  `created` datetime NOT NULL,
  PRIMARY KEY (`run_id`,`steamid`),
  KEY `idx_map_run_players_steamid` (`steamid`,`created`),
  KEY `idx_map_run_players_run_team` (`run_id`,`team`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS `legacy_map_bests` (
  `source_hash` char(64) CHARACTER SET ascii NOT NULL,
  `map` varchar(255) CHARACTER SET utf8mb4 NOT NULL,
  `gamemode` tinyint unsigned NOT NULL,
  `mutation` varchar(64) CHARACTER SET utf8mb4 NOT NULL DEFAULT '',
  `ruleset_key` varchar(64) CHARACTER SET ascii NOT NULL,
  `ruleset_version` varchar(64) CHARACTER SET utf8mb4 NOT NULL DEFAULT '',
  `timing_profile` varchar(24) CHARACTER SET ascii NOT NULL DEFAULT 'completion',
  `difficulty_type` varchar(16) CHARACTER SET ascii NOT NULL DEFAULT 'game',
  `difficulty` tinyint unsigned NOT NULL DEFAULT '0',
  `steamid` varchar(255) CHARACTER SET utf8mb4 NOT NULL,
  `plays` int unsigned NOT NULL DEFAULT '0',
  `best_duration_ms` bigint unsigned NOT NULL,
  `player_count` smallint unsigned NOT NULL DEFAULT '0',
  `si_count` smallint unsigned NOT NULL DEFAULT '0',
  `si_spawn_time` smallint unsigned NOT NULL DEFAULT '0',
  `usebuy` tinyint unsigned NOT NULL DEFAULT '0',
  `auto` tinyint unsigned NOT NULL DEFAULT '0',
  `legacy_mode` tinyint unsigned NOT NULL DEFAULT '0',
  `created` date NOT NULL,
  `modified` datetime NOT NULL,
  PRIMARY KEY (`source_hash`),
  KEY `idx_legacy_map_bests_filter` (`ruleset_key`,`map`,`difficulty`,`best_duration_ms`),
  KEY `idx_legacy_map_bests_steamid` (`steamid`,`modified`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO `map_runs` (
  `run_id`,`map`,`gamemode`,`mutation`,`ruleset_key`,`ruleset_version`,`record_policy`,
  `timing_profile`,`difficulty_type`,`difficulty`,`duration_ms`,`survivor_count`,
  `infected_count`,`si_count`,`si_spawn_time`,`usebuy`,`auto`,`legacy_mode`,
  `completed`,`valid`,`server_name`,`source`,`created`,`modified`
)
SELECT
  tr.`run_id`, MAX(tr.`map`), MAX(tr.`gamemode`), MAX(tr.`mutation`),
  CASE MAX(tr.`mode`)
    WHEN 1 THEN 'annehappy' WHEN 2 THEN 'witchparty' WHEN 3 THEN 'allcharger'
    WHEN 4 THEN 'alone' WHEN 5 THEN 'hunters' WHEN 6 THEN 'anne_hardcore'
    WHEN 7 THEN 'anne_shotgun'
    ELSE CASE MAX(tr.`gamemode`)
      WHEN 0 THEN 'legacy_coop' WHEN 1 THEN 'legacy_versus'
      WHEN 2 THEN 'legacy_realism' WHEN 3 THEN 'legacy_survival'
      WHEN 4 THEN 'legacy_scavenge' WHEN 5 THEN 'legacy_realism_versus'
      WHEN 6 THEN CONCAT('legacy_mutation_', COALESCE(NULLIF(MAX(tr.`mutation`), ''), 'unknown'))
      ELSE 'legacy_unknown'
    END
  END,
  MAX(tr.`anneversion`),
  CASE WHEN MAX(tr.`gamemode`) IN (1,4,5) AND MAX(tr.`mode`) = 0 THEN 1 ELSE 2 END,
  CASE WHEN MAX(tr.`gamemode`) = 3 THEN 'survival'
       WHEN MAX(tr.`gamemode`) IN (1,4,5) AND MAX(tr.`mode`) = 0 THEN 'round_history'
       ELSE 'completion' END,
  CASE WHEN MAX(tr.`mode`) > 0 THEN 'anne_ai' ELSE 'game' END,
  CASE WHEN MAX(tr.`mode`) > 0 AND MAX(tr.`difficulty`) = 3 AND MAX(tr.`modified`) < '2026-05-19 00:00:00'
       THEN 4 ELSE MAX(tr.`difficulty`) END,
  ROUND(MAX(tr.`time`) * 1000), MAX(tr.`players`), 0,
  MAX(tr.`sinum`), MAX(tr.`sitime`), MAX(tr.`usebuy`), MAX(tr.`auto`), MAX(tr.`mode`),
  1, 1, '', 'legacy_timedmap_runs', MIN(tr.`created`), MAX(tr.`modified`)
FROM `timedmap_runs` tr
GROUP BY tr.`run_id`
ON DUPLICATE KEY UPDATE `modified` = VALUES(`modified`);

INSERT IGNORE INTO `map_run_players` (`run_id`,`steamid`,`team`,`completed`,`created`)
SELECT `run_id`,`steamid`,2,1,MIN(`created`)
FROM `timedmap_runs`
GROUP BY `run_id`,`steamid`;

INSERT INTO `legacy_map_bests` (
  `source_hash`,`map`,`gamemode`,`mutation`,`ruleset_key`,`ruleset_version`,`timing_profile`,
  `difficulty_type`,`difficulty`,`steamid`,`plays`,`best_duration_ms`,`player_count`,
  `si_count`,`si_spawn_time`,`usebuy`,`auto`,`legacy_mode`,`created`,`modified`
)
SELECT
  SHA2(CONCAT_WS('|',src.`map`,src.`gamemode`,src.`difficulty`,src.`steamid`,src.`mutation`,src.`mode`,src.`sinum`,src.`sitime`,src.`usebuy`,src.`anneversion`,src.`auto`,src.`player_count`), 256),
  src.`map`, src.`gamemode`, src.`mutation`,
  CASE src.`mode`
    WHEN 1 THEN 'annehappy' WHEN 2 THEN 'witchparty' WHEN 3 THEN 'allcharger'
    WHEN 4 THEN 'alone' WHEN 5 THEN 'hunters' WHEN 6 THEN 'anne_hardcore'
    WHEN 7 THEN 'anne_shotgun'
    ELSE CASE src.`gamemode`
      WHEN 0 THEN 'legacy_coop' WHEN 1 THEN 'legacy_versus'
      WHEN 2 THEN 'legacy_realism' WHEN 3 THEN 'legacy_survival'
      WHEN 4 THEN 'legacy_scavenge' WHEN 5 THEN 'legacy_realism_versus'
      WHEN 6 THEN CONCAT('legacy_mutation_', COALESCE(NULLIF(src.`mutation`, ''), 'unknown'))
      ELSE 'legacy_unknown'
    END
  END,
  src.`anneversion`,
  CASE WHEN src.`gamemode` = 3 THEN 'survival'
       WHEN src.`gamemode` IN (1,4,5) AND src.`mode` = 0 THEN 'round_history'
       ELSE 'completion' END,
  CASE WHEN src.`mode` > 0 THEN 'anne_ai' ELSE 'game' END,
  src.`difficulty`,src.`steamid`,src.`plays`,ROUND(src.`best_time` * 1000),src.`player_count`,src.`sinum`,src.`sitime`,
  src.`usebuy`,src.`auto`,src.`mode`,src.`created`,src.`modified`
FROM (
  SELECT
    tm.`map`,tm.`gamemode`,tm.`mutation`,tm.`mode`,tm.`sinum`,tm.`sitime`,tm.`usebuy`,tm.`anneversion`,tm.`auto`,
    tm.`players` AS `player_count`,
    CASE WHEN tm.`mode` > 0 AND tm.`difficulty` = 3 AND tm.`modified` < '2026-05-19 00:00:00' THEN 4 ELSE tm.`difficulty` END AS `difficulty`,
    tm.`steamid`,SUM(tm.`plays`) AS `plays`,
    CASE WHEN tm.`gamemode` = 3 THEN MAX(tm.`time`) ELSE MIN(tm.`time`) END AS `best_time`,
    MIN(tm.`created`) AS `created`,MAX(tm.`modified`) AS `modified`
  FROM `timedmaps` tm
  GROUP BY tm.`map`,tm.`gamemode`,tm.`mutation`,tm.`mode`,tm.`sinum`,tm.`sitime`,tm.`usebuy`,tm.`anneversion`,tm.`auto`,tm.`players`,
    CASE WHEN tm.`mode` > 0 AND tm.`difficulty` = 3 AND tm.`modified` < '2026-05-19 00:00:00' THEN 4 ELSE tm.`difficulty` END,
    tm.`steamid`
) src
ON DUPLICATE KEY UPDATE
  `plays` = VALUES(`plays`),
  `best_duration_ms` = VALUES(`best_duration_ms`),
  `created` = VALUES(`created`),
  `modified` = VALUES(`modified`);
