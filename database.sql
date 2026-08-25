-- AnneHappy current MySQL schema bootstrap (MySQL 5.7+).
-- This file only creates shared tables required by the current plugins and NewAnneWeb.
-- NewAnneWeb-owned tables are initialized by NewAnneWeb/database/init.php.
-- SourceBans++ owns its own `sourcebans` database and is intentionally excluded.

SET NAMES utf8mb4;
SET time_zone = '+00:00';
SET foreign_key_checks = 0;

CREATE DATABASE IF NOT EXISTS `Anne` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS `chat` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE DATABASE IF NOT EXISTS `l4d2stats` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

USE `Anne`;

-- The current plugins do not own any Anne-specific tables. The schema remains
-- available for SourceMod's default database alias and external admin tooling.

USE `chat`;

CREATE TABLE IF NOT EXISTS `anne_global_chat` (
  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `created_at` datetime NOT NULL,
  `server` varchar(126) NOT NULL,
  `port` int(11) NOT NULL DEFAULT '0',
  `steamid` varchar(32) NOT NULL,
  `name` varchar(128) NOT NULL,
  `message` varchar(255) NOT NULL,
  PRIMARY KEY (`id`) USING BTREE,
  KEY `idx_anne_global_chat_created_at` (`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


CREATE TABLE IF NOT EXISTS `anne_global_chat_titles` (
  `steamid` varchar(32) NOT NULL,
  `title` varchar(64) NOT NULL,
  PRIMARY KEY (`steamid`) USING BTREE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


CREATE TABLE IF NOT EXISTS `anne_global_chat_usage` (
  `steamid` varchar(32) NOT NULL,
  `usage_date` date NOT NULL,
  `used_count` int(10) unsigned NOT NULL DEFAULT '0',
  `last_used_at` datetime NOT NULL,
  PRIMARY KEY (`steamid`,`usage_date`) USING BTREE,
  KEY `idx_anne_global_chat_usage_date` (`usage_date`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


CREATE TABLE IF NOT EXISTS `anne_lfg_chat_usage` (
  `steamid` varchar(32) NOT NULL,
  `usage_date` date NOT NULL,
  `used_count` int(10) unsigned NOT NULL DEFAULT '0',
  `last_used_at` datetime NOT NULL,
  PRIMARY KEY (`steamid`,`usage_date`) USING BTREE,
  KEY `idx_anne_lfg_chat_usage_date` (`usage_date`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


CREATE TABLE IF NOT EXISTS `chat_log` (
  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `date` datetime DEFAULT NULL,
  `map` varchar(128) NOT NULL,
  `steamid` varchar(21) NOT NULL,
  `name` varchar(128) NOT NULL,
  `message_style` tinyint(2) DEFAULT '0',
  `message` varchar(126) NOT NULL,
  `server` varchar(126) DEFAULT NULL,
  `port` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE,
  KEY `idx_chat_log_date` (`date`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


USE `l4d2stats`;

CREATE TABLE IF NOT EXISTS `ai_dynamic_ppm_thresholds` (
  `id` tinyint(3) unsigned NOT NULL DEFAULT '1',
  `source` varchar(32) NOT NULL DEFAULT 'daily',
  `sample_count` int(11) NOT NULL DEFAULT '0',
  `ppm_p60` float NOT NULL DEFAULT '30.89',
  `ppm_p75` float NOT NULL DEFAULT '43.23',
  `ppm_p90` float NOT NULL DEFAULT '63.7',
  `ppm_p95` float NOT NULL DEFAULT '77.57',
  `updated_at` int(11) NOT NULL DEFAULT '0',
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


CREATE TABLE IF NOT EXISTS `l4d_peak_state` (
  `state_key` varchar(64) NOT NULL,
  `hold_until` int(11) NOT NULL DEFAULT '0',
  `updated_at` int(11) NOT NULL DEFAULT '0',
  PRIMARY KEY (`state_key`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


CREATE TABLE IF NOT EXISTS `l4d_server_status` (
  `address_key` varchar(160) NOT NULL,
  `server_id` varchar(128) NOT NULL,
  `hostname` varchar(128) NOT NULL DEFAULT '',
  `ip` varchar(64) NOT NULL DEFAULT '',
  `port` int(11) NOT NULL DEFAULT '0',
  `players` int(11) NOT NULL DEFAULT '0',
  `updated_at` int(11) NOT NULL DEFAULT '0',
  `enabled` tinyint(4) NOT NULL DEFAULT '1',
  `is_good_server` tinyint(4) NOT NULL DEFAULT '0',
  PRIMARY KEY (`address_key`),
  KEY `server_id` (`server_id`),
  KEY `updated_at` (`updated_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


CREATE TABLE IF NOT EXISTS `lilac_detections` (
  `name` varchar(128) CHARACTER SET utf8mb4 NOT NULL,
  `steamid` varchar(32) CHARACTER SET utf8mb4 NOT NULL,
  `ip` varchar(16) CHARACTER SET utf8mb4 NOT NULL,
  `cheat` varchar(50) CHARACTER SET utf8mb4 NOT NULL,
  `timestamp` int(11) NOT NULL,
  `detection` int(11) NOT NULL,
  `pos1` float NOT NULL,
  `pos2` float NOT NULL,
  `pos3` float NOT NULL,
  `ang1` float NOT NULL,
  `ang2` float NOT NULL,
  `ang3` float NOT NULL,
  `map` varchar(128) CHARACTER SET utf8mb4 NOT NULL,
  `team` int(11) NOT NULL,
  `weapon` varchar(64) CHARACTER SET utf8mb4 NOT NULL,
  `data1` float NOT NULL,
  `data2` float NOT NULL,
  `latency_inc` float NOT NULL,
  `latency_out` float NOT NULL,
  `loss_inc` float NOT NULL,
  `loss_out` float NOT NULL,
  `choke_inc` float NOT NULL,
  `choke_out` float NOT NULL,
  `connection_ticktime` float NOT NULL,
  `game_ticktime` float NOT NULL,
  `lilac_version` varchar(20) CHARACTER SET utf8mb4 NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


CREATE TABLE IF NOT EXISTS `maps` (
  `name` varchar(255) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NOT NULL,
  `gamemode` int(1) NOT NULL DEFAULT '0',
  `custom` bit(1) NOT NULL DEFAULT b'0',
  `playtime_nor` int(11) NOT NULL DEFAULT '0',
  `playtime_adv` int(11) NOT NULL DEFAULT '0',
  `playtime_exp` int(11) NOT NULL DEFAULT '0',
  `restarts_nor` int(11) NOT NULL DEFAULT '0',
  `restarts_adv` int(11) NOT NULL DEFAULT '0',
  `restarts_exp` int(11) NOT NULL DEFAULT '0',
  `points_nor` int(11) NOT NULL DEFAULT '0',
  `points_adv` int(11) NOT NULL DEFAULT '0',
  `points_exp` int(11) NOT NULL DEFAULT '0',
  `points_infected_nor` int(11) NOT NULL DEFAULT '0',
  `points_infected_adv` int(11) NOT NULL DEFAULT '0',
  `points_infected_exp` int(11) NOT NULL DEFAULT '0',
  `kills_nor` int(11) NOT NULL DEFAULT '0',
  `kills_adv` int(11) NOT NULL DEFAULT '0',
  `kills_exp` int(11) NOT NULL DEFAULT '0',
  `survivor_kills_nor` int(11) NOT NULL DEFAULT '0',
  `survivor_kills_adv` int(11) NOT NULL DEFAULT '0',
  `survivor_kills_exp` int(11) NOT NULL DEFAULT '0',
  `infected_win_nor` int(11) NOT NULL DEFAULT '0',
  `infected_win_adv` int(11) NOT NULL DEFAULT '0',
  `infected_win_exp` int(11) NOT NULL DEFAULT '0',
  `survivors_win_nor` int(11) NOT NULL DEFAULT '0',
  `survivors_win_adv` int(11) NOT NULL DEFAULT '0',
  `survivors_win_exp` int(11) NOT NULL DEFAULT '0',
  `infected_smoker_damage_nor` bigint(20) NOT NULL DEFAULT '0',
  `infected_smoker_damage_adv` bigint(20) NOT NULL DEFAULT '0',
  `infected_smoker_damage_exp` bigint(20) NOT NULL DEFAULT '0',
  `infected_jockey_damage_nor` bigint(20) NOT NULL DEFAULT '0',
  `infected_jockey_damage_adv` bigint(20) NOT NULL DEFAULT '0',
  `infected_jockey_damage_exp` bigint(20) NOT NULL DEFAULT '0',
  `infected_jockey_ridetime_nor` double NOT NULL DEFAULT '0',
  `infected_jockey_ridetime_adv` double NOT NULL DEFAULT '0',
  `infected_jockey_ridetime_exp` double NOT NULL DEFAULT '0',
  `infected_charger_damage_nor` bigint(20) NOT NULL DEFAULT '0',
  `infected_charger_damage_adv` bigint(20) NOT NULL DEFAULT '0',
  `infected_charger_damage_exp` bigint(20) NOT NULL DEFAULT '0',
  `infected_tank_damage_nor` bigint(20) NOT NULL DEFAULT '0',
  `infected_tank_damage_adv` bigint(20) NOT NULL DEFAULT '0',
  `infected_tank_damage_exp` bigint(20) NOT NULL DEFAULT '0',
  `infected_boomer_vomits_nor` int(11) NOT NULL DEFAULT '0',
  `infected_boomer_vomits_adv` int(11) NOT NULL DEFAULT '0',
  `infected_boomer_vomits_exp` int(11) NOT NULL DEFAULT '0',
  `infected_boomer_blinded_nor` int(11) NOT NULL DEFAULT '0',
  `infected_boomer_blinded_adv` int(11) NOT NULL DEFAULT '0',
  `infected_boomer_blinded_exp` int(11) NOT NULL DEFAULT '0',
  `infected_spitter_damage_nor` int(11) NOT NULL DEFAULT '0',
  `infected_spitter_damage_adv` int(11) NOT NULL DEFAULT '0',
  `infected_spitter_damage_exp` int(11) NOT NULL DEFAULT '0',
  `infected_spawn_1_nor` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawn as Smoker',
  `infected_spawn_1_adv` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawn as Smoker',
  `infected_spawn_1_exp` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawn as Smoker',
  `infected_spawn_2_nor` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawn as Boomer',
  `infected_spawn_2_adv` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawn as Boomer',
  `infected_spawn_2_exp` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawn as Boomer',
  `infected_spawn_3_nor` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawn as Hunter',
  `infected_spawn_3_adv` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawn as Hunter',
  `infected_spawn_3_exp` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawn as Hunter',
  `infected_spawn_4_nor` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawn as Spitter',
  `infected_spawn_4_adv` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawn as Spitter',
  `infected_spawn_4_exp` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawn as Spitter',
  `infected_spawn_5_nor` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawn as Jockey',
  `infected_spawn_5_adv` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawn as Jockey',
  `infected_spawn_5_exp` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawn as Jockey',
  `infected_spawn_6_nor` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawn as Charger',
  `infected_spawn_6_adv` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawn as Charger',
  `infected_spawn_6_exp` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawn as Charger',
  `infected_spawn_8_nor` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawn as Tank',
  `infected_spawn_8_adv` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawn as Tank',
  `infected_spawn_8_exp` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawn as Tank',
  `infected_hunter_pounce_counter_nor` int(11) NOT NULL DEFAULT '0',
  `infected_hunter_pounce_counter_adv` int(11) NOT NULL DEFAULT '0',
  `infected_hunter_pounce_counter_exp` int(11) NOT NULL DEFAULT '0',
  `infected_hunter_pounce_damage_nor` int(11) NOT NULL DEFAULT '0',
  `infected_hunter_pounce_damage_adv` int(11) NOT NULL DEFAULT '0',
  `infected_hunter_pounce_damage_exp` int(11) NOT NULL DEFAULT '0',
  `infected_tanksniper_nor` int(11) NOT NULL DEFAULT '0',
  `infected_tanksniper_adv` int(11) NOT NULL DEFAULT '0',
  `infected_tanksniper_exp` int(11) NOT NULL DEFAULT '0',
  `caralarm_nor` int(11) NOT NULL DEFAULT '0',
  `caralarm_adv` int(11) NOT NULL DEFAULT '0',
  `caralarm_exp` int(11) NOT NULL DEFAULT '0',
  `jockey_rides_nor` int(11) NOT NULL DEFAULT '0',
  `jockey_rides_adv` int(11) NOT NULL DEFAULT '0',
  `jockey_rides_exp` int(11) NOT NULL DEFAULT '0',
  `charger_impacts_nor` int(11) NOT NULL DEFAULT '0',
  `charger_impacts_adv` int(11) NOT NULL DEFAULT '0',
  `charger_impacts_exp` int(11) NOT NULL DEFAULT '0',
  `mutation` varchar(64) NOT NULL DEFAULT '',
  PRIMARY KEY (`name`,`gamemode`,`mutation`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


CREATE TABLE IF NOT EXISTS `players` (
  `steamid` varchar(255) CHARACTER SET utf8mb4 NOT NULL,
  `name` tinyblob NOT NULL,
  `lastontime` varchar(255) CHARACTER SET utf8mb4 NOT NULL,
  `lastgamemode` int(1) NOT NULL DEFAULT '0',
  `lastannemode` int(1) NOT NULL DEFAULT '0',
  `ip` varchar(16) CHARACTER SET utf8mb4 NOT NULL DEFAULT '0.0.0.0',
  `lastservername` varchar(128) CHARACTER SET utf8mb4 NOT NULL DEFAULT '',
  `playtime` int(11) NOT NULL DEFAULT '0' COMMENT 'Playtime in Coop',
  `playtime_versus` int(11) NOT NULL DEFAULT '0' COMMENT 'Playtime in Versus',
  `playtime_realism` int(11) NOT NULL DEFAULT '0' COMMENT 'Playtime in Realism',
  `playtime_survival` int(11) NOT NULL DEFAULT '0' COMMENT 'Playtime in Survival',
  `playtime_scavenge` int(11) NOT NULL DEFAULT '0' COMMENT 'Playtime in Scavenge',
  `playtime_realismversus` int(11) NOT NULL DEFAULT '0' COMMENT 'Playtime in Realism',
  `points` int(11) NOT NULL DEFAULT '0',
  `points_realism` int(11) NOT NULL DEFAULT '0',
  `points_survival` int(11) NOT NULL DEFAULT '0',
  `points_survivors` int(11) NOT NULL DEFAULT '0',
  `points_infected` int(11) NOT NULL DEFAULT '0',
  `points_scavenge_survivors` int(11) NOT NULL DEFAULT '0',
  `points_scavenge_infected` int(11) NOT NULL DEFAULT '0',
  `points_realism_survivors` int(11) NOT NULL DEFAULT '0',
  `points_realism_infected` int(11) NOT NULL DEFAULT '0',
  `kills` int(11) NOT NULL DEFAULT '0',
  `melee_kills` int(11) NOT NULL DEFAULT '0',
  `headshots` int(11) NOT NULL DEFAULT '0',
  `kill_infected` int(11) NOT NULL DEFAULT '0',
  `kill_hunter` int(11) NOT NULL DEFAULT '0',
  `kill_smoker` int(11) NOT NULL DEFAULT '0',
  `kill_boomer` int(11) NOT NULL DEFAULT '0',
  `kill_spitter` int(11) NOT NULL DEFAULT '0',
  `kill_jockey` int(11) NOT NULL DEFAULT '0',
  `kill_charger` int(11) NOT NULL DEFAULT '0',
  `versus_kills_survivors` int(11) NOT NULL DEFAULT '0',
  `scavenge_kills_survivors` int(11) NOT NULL DEFAULT '0',
  `realism_kills_survivors` int(11) NOT NULL DEFAULT '0',
  `jockey_rides` int(11) NOT NULL DEFAULT '0',
  `charger_impacts` int(11) NOT NULL DEFAULT '0',
  `award_pills` int(11) NOT NULL DEFAULT '0',
  `award_adrenaline` int(11) NOT NULL DEFAULT '0',
  `award_fincap` int(11) NOT NULL DEFAULT '0' COMMENT 'Friendly incapacitation',
  `award_medkit` int(11) NOT NULL DEFAULT '0',
  `award_defib` int(11) NOT NULL DEFAULT '0',
  `award_charger` int(11) NOT NULL DEFAULT '0',
  `award_jockey` int(11) NOT NULL DEFAULT '0',
  `award_hunter` int(11) NOT NULL DEFAULT '0',
  `award_smoker` int(11) NOT NULL DEFAULT '0',
  `award_protect` int(11) NOT NULL DEFAULT '0',
  `award_revive` int(11) NOT NULL DEFAULT '0',
  `award_rescue` int(11) NOT NULL DEFAULT '0',
  `award_campaigns` int(11) NOT NULL DEFAULT '0',
  `award_tankkill` int(11) NOT NULL DEFAULT '0',
  `award_tankkillnodeaths` int(11) NOT NULL DEFAULT '0',
  `award_allinsafehouse` int(11) NOT NULL DEFAULT '0',
  `award_friendlyfire` int(11) NOT NULL DEFAULT '0',
  `award_teamkill` int(11) NOT NULL DEFAULT '0',
  `award_left4dead` int(11) NOT NULL DEFAULT '0',
  `award_letinsafehouse` int(11) NOT NULL DEFAULT '0',
  `award_witchdisturb` int(11) NOT NULL DEFAULT '0',
  `award_pounce_perfect` int(11) NOT NULL DEFAULT '0',
  `award_pounce_nice` int(11) NOT NULL DEFAULT '0',
  `award_perfect_blindness` int(11) NOT NULL DEFAULT '0',
  `award_infected_win` int(11) NOT NULL DEFAULT '0',
  `award_scavenge_infected_win` int(11) NOT NULL DEFAULT '0',
  `award_bulldozer` int(11) NOT NULL DEFAULT '0',
  `award_survivor_down` int(11) NOT NULL DEFAULT '0',
  `award_ledgegrab` int(11) NOT NULL DEFAULT '0',
  `award_gascans_poured` int(11) NOT NULL DEFAULT '0',
  `award_upgrades_added` int(11) NOT NULL DEFAULT '0',
  `award_matador` int(11) NOT NULL DEFAULT '0',
  `award_witchcrowned` int(11) NOT NULL DEFAULT '0',
  `award_scatteringram` int(11) NOT NULL DEFAULT '0',
  `infected_spawn_1` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawned as Smoker',
  `infected_spawn_2` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawned as Boomer',
  `infected_spawn_3` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawned as Hunter',
  `infected_spawn_4` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawned as Spitter',
  `infected_spawn_5` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawned as Jockey',
  `infected_spawn_6` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawned as Charger',
  `infected_spawn_8` int(11) NOT NULL DEFAULT '0' COMMENT 'Spawned as Tank',
  `infected_boomer_vomits` int(11) NOT NULL DEFAULT '0',
  `infected_boomer_blinded` int(11) NOT NULL DEFAULT '0',
  `infected_hunter_pounce_counter` int(11) NOT NULL DEFAULT '0',
  `infected_hunter_pounce_dmg` int(11) NOT NULL DEFAULT '0',
  `infected_smoker_damage` int(11) NOT NULL DEFAULT '0',
  `infected_jockey_damage` int(11) NOT NULL DEFAULT '0',
  `infected_jockey_ridetime` double NOT NULL DEFAULT '0',
  `infected_charger_damage` int(11) NOT NULL DEFAULT '0',
  `infected_tank_damage` int(11) NOT NULL DEFAULT '0',
  `infected_tanksniper` int(11) NOT NULL DEFAULT '0',
  `infected_spitter_damage` int(11) NOT NULL DEFAULT '0',
  `mutations_kills_survivors` int(11) NOT NULL DEFAULT '0',
  `playtime_mutations` int(11) NOT NULL DEFAULT '0',
  `points_mutations` int(11) NOT NULL DEFAULT '0',
  `totalpoints` int(11) GENERATED ALWAYS AS ((((((((((`points` + `points_survivors`) + `points_infected`) + `points_realism`) + `points_survival`) + `points_scavenge_survivors`) + `points_scavenge_infected`) + `points_realism_survivors`) + `points_realism_infected`) + `points_mutations`)) STORED,
  `totalplaytime` int(11) GENERATED ALWAYS AS (((((((`playtime` + `playtime_versus`) + `playtime_realism`) + `playtime_survival`) + `playtime_scavenge`) + `playtime_realismversus`) + `playtime_mutations`)) STORED,
  PRIMARY KEY (`steamid`),
  KEY `idx_lastontime` (`lastontime`),
  KEY `idx_players_totalpoints` (`totalpoints`),
  KEY `idx_players_totalplaytime` (`totalplaytime`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


CREATE TABLE IF NOT EXISTS `player_blocks` (
  `blocker` varchar(32) NOT NULL,
  `blocked` varchar(32) NOT NULL,
  `created_at` int(11) NOT NULL,
  PRIMARY KEY (`blocker`,`blocked`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


CREATE TABLE IF NOT EXISTS `player_mode_stats` (
  `steamid` varchar(64) NOT NULL,
  `mode_id` tinyint(4) NOT NULL,
  `anne_mode` tinyint(4) NOT NULL DEFAULT '0',
  `points` int(11) NOT NULL DEFAULT '0',
  `playtime` int(11) NOT NULL DEFAULT '0',
  `kills` int(11) NOT NULL DEFAULT '0',
  `headshots` int(11) NOT NULL DEFAULT '0',
  `updated` int(10) unsigned NOT NULL DEFAULT '0',
  PRIMARY KEY (`steamid`,`mode_id`,`anne_mode`),
  KEY `mode_ppm` (`mode_id`,`anne_mode`,`playtime`,`points`),
  KEY `mode_kpm` (`mode_id`,`anne_mode`,`playtime`,`kills`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


CREATE TABLE IF NOT EXISTS `RPG` (
  `steamid` varchar(255) CHARACTER SET utf8mb4 NOT NULL,
  `MELEE_DATA` int(10) NOT NULL DEFAULT '0',
  `BLOOD_DATA` int(10) NOT NULL DEFAULT '0',
  `HAT` int(10) NOT NULL DEFAULT '0',
  `HAT_ENABLED` tinyint(4) DEFAULT NULL,
  `HAT_VIEW_FIRST` tinyint(4) DEFAULT NULL,
  `HAT_VIEW_THIRD` tinyint(4) DEFAULT NULL,
  `HAT_SHOW_OTHERS` tinyint(4) DEFAULT NULL,
  `GLOW` int(10) NOT NULL DEFAULT '0',
  `SKIN` int(10) NOT NULL DEFAULT '0',
  `RECOIL` int(10) NOT NULL DEFAULT '0',
  `ANNE_GUIDE_PROMPT` tinyint(4) NOT NULL DEFAULT '1',
  `CHATTAG` varchar(128) CHARACTER SET utf8mb4 DEFAULT NULL,
  `hitsound_cfg` tinyint(4) NOT NULL DEFAULT '0',
  `hitsound_overlay` tinyint(4) NOT NULL DEFAULT '0',
  `hitsound_head` tinyint(4) NOT NULL DEFAULT '0',
  `hitsound_hit` tinyint(4) NOT NULL DEFAULT '0',
  `hitsound_kill` tinyint(4) NOT NULL DEFAULT '0',
  `hiticon_head` tinyint(4) NOT NULL DEFAULT '0',
  `hiticon_hit` tinyint(4) NOT NULL DEFAULT '0',
  `hiticon_kill` tinyint(4) NOT NULL DEFAULT '0',
  `hitsound_si_only` tinyint(4) NOT NULL DEFAULT '0',
  `hiticon_si_only` tinyint(4) NOT NULL DEFAULT '0',
  `hitsound_stack_mode` tinyint(4) DEFAULT NULL,
  `hitsound_headkill` tinyint(4) DEFAULT NULL,
  PRIMARY KEY (`steamid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


CREATE TABLE IF NOT EXISTS `rpgdamage` (
  `steamid` varchar(255) NOT NULL,
  `enable` tinyint(4) NOT NULL DEFAULT '0',
  `see_others` tinyint(4) NOT NULL DEFAULT '1',
  `share_scope` tinyint(4) NOT NULL DEFAULT '0',
  `size` float NOT NULL DEFAULT '5',
  `gap` float NOT NULL DEFAULT '5',
  `alpha` int(11) NOT NULL DEFAULT '70',
  `xoff` float NOT NULL DEFAULT '20',
  `yoff` float NOT NULL DEFAULT '10',
  `showdist` float NOT NULL DEFAULT '1500',
  `summode` tinyint(4) NOT NULL DEFAULT '1',
  `sg_merge` tinyint(4) NOT NULL DEFAULT '1',
  PRIMARY KEY (`steamid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


CREATE TABLE IF NOT EXISTS `infected_control_traitor_quota` (
  `auth_id` varchar(64) NOT NULL,
  `total_count` int NOT NULL DEFAULT '100',
  `used_count` int NOT NULL DEFAULT '0',
  `quota_day` int NOT NULL DEFAULT '0',
  `tank_block_until` int NOT NULL DEFAULT '0',
  `last_name` varchar(64) NOT NULL DEFAULT '',
  `updated_at` int NOT NULL DEFAULT '0',
  PRIMARY KEY (`auth_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


CREATE TABLE IF NOT EXISTS `scripted_hud_prefs` (
  `steamid` varchar(64) NOT NULL,
  `hud_mask` smallint unsigned NOT NULL DEFAULT '3',
  `hud2_mask` tinyint unsigned NOT NULL DEFAULT '255',
  `layout_preset` tinyint unsigned NOT NULL DEFAULT '0',
  `hud3_source` tinyint unsigned NOT NULL DEFAULT '0',
  `hud4_source` tinyint unsigned NOT NULL DEFAULT '0',
  `slot_sources` varchar(80) NOT NULL DEFAULT '',
  `kill_feed_enabled` tinyint unsigned DEFAULT NULL,
  `revision` int unsigned NOT NULL DEFAULT '0',
  `updated_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`steamid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


CREATE TABLE IF NOT EXISTS `score_log` (
  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `created` int(11) NOT NULL,
  `steamid` varchar(64) NOT NULL,
  `name` varchar(128) NOT NULL,
  `map` varchar(128) NOT NULL,
  `gamemode` int(2) NOT NULL DEFAULT '0',
  `difficulty` varchar(32) NOT NULL DEFAULT '',
  `team` int(2) NOT NULL DEFAULT '0',
  `score` int(11) NOT NULL DEFAULT '0',
  `score_after` int(11) NOT NULL DEFAULT '0',
  `reason` varchar(64) NOT NULL DEFAULT 'unknown',
  `formula` varchar(255) NOT NULL DEFAULT '',
  `round_valid` tinyint(1) NOT NULL DEFAULT '0',
  `usebuy` tinyint(1) NOT NULL DEFAULT '0',
  `newbie_count` int(4) NOT NULL DEFAULT '0',
  `newbie_multiplier` double NOT NULL DEFAULT '1',
  PRIMARY KEY (`id`),
  KEY `steamid_created` (`steamid`,`created`),
  KEY `reason_created` (`reason`,`created`),
  KEY `map_created` (`map`,`created`),
  KEY `score_created` (`score`,`created`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


CREATE TABLE IF NOT EXISTS `score_quarter` (
  `steamid` varchar(64) NOT NULL,
  `quarter_key` int(8) NOT NULL DEFAULT '0',
  `points` int(11) NOT NULL DEFAULT '0',
  `playtime` int(11) NOT NULL DEFAULT '0',
  `updated` int(11) NOT NULL DEFAULT '0',
  `points_coop` int(11) NOT NULL DEFAULT '0',
  `points_survivors` int(11) NOT NULL DEFAULT '0',
  `points_infected` int(11) NOT NULL DEFAULT '0',
  `points_survival` int(11) NOT NULL DEFAULT '0',
  `points_realism` int(11) NOT NULL DEFAULT '0',
  `points_scavenge_survivors` int(11) NOT NULL DEFAULT '0',
  `points_scavenge_infected` int(11) NOT NULL DEFAULT '0',
  `points_realism_survivors` int(11) NOT NULL DEFAULT '0',
  `points_realism_infected` int(11) NOT NULL DEFAULT '0',
  `points_mutations` int(11) NOT NULL DEFAULT '0',
  `kills` int(11) NOT NULL DEFAULT '0',
  `headshots` int(11) NOT NULL DEFAULT '0',
  `melee_kills` int(11) NOT NULL DEFAULT '0',
  `kill_infected` int(11) NOT NULL DEFAULT '0',
  `kill_hunter` int(11) NOT NULL DEFAULT '0',
  `kill_smoker` int(11) NOT NULL DEFAULT '0',
  `kill_boomer` int(11) NOT NULL DEFAULT '0',
  `kill_spitter` int(11) NOT NULL DEFAULT '0',
  `kill_jockey` int(11) NOT NULL DEFAULT '0',
  `kill_charger` int(11) NOT NULL DEFAULT '0',
  `award_medkit` int(11) NOT NULL DEFAULT '0',
  `award_pills` int(11) NOT NULL DEFAULT '0',
  `award_adrenaline` int(11) NOT NULL DEFAULT '0',
  `award_revive` int(11) NOT NULL DEFAULT '0',
  `award_defib` int(11) NOT NULL DEFAULT '0',
  `award_rescue` int(11) NOT NULL DEFAULT '0',
  `award_protect` int(11) NOT NULL DEFAULT '0',
  `award_friendlyfire` int(11) NOT NULL DEFAULT '0',
  `award_teamkill` int(11) NOT NULL DEFAULT '0',
  `award_fincap` int(11) NOT NULL DEFAULT '0',
  `award_left4dead` int(11) NOT NULL DEFAULT '0',
  `award_letinsafehouse` int(11) NOT NULL DEFAULT '0',
  `award_witchdisturb` int(11) NOT NULL DEFAULT '0',
  PRIMARY KEY (`steamid`,`quarter_key`),
  KEY `quarter_points` (`quarter_key`,`points`),
  KEY `points` (`points`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


CREATE TABLE IF NOT EXISTS `score_quarter_history` (
  `quarter_key` int(10) unsigned NOT NULL,
  `rank_num` int(10) unsigned NOT NULL,
  `steamid` varchar(64) COLLATE utf8mb4_unicode_ci NOT NULL,
  `name` varchar(255) COLLATE utf8mb4_unicode_ci NOT NULL DEFAULT '',
  `points` int(11) NOT NULL DEFAULT '0',
  `archived_at` int(10) unsigned NOT NULL,
  `playtime` int(11) NOT NULL DEFAULT '0',
  `points_coop` int(11) NOT NULL DEFAULT '0',
  `points_survivors` int(11) NOT NULL DEFAULT '0',
  `points_infected` int(11) NOT NULL DEFAULT '0',
  `points_survival` int(11) NOT NULL DEFAULT '0',
  `points_realism` int(11) NOT NULL DEFAULT '0',
  `points_scavenge_survivors` int(11) NOT NULL DEFAULT '0',
  `points_scavenge_infected` int(11) NOT NULL DEFAULT '0',
  `points_realism_survivors` int(11) NOT NULL DEFAULT '0',
  `points_realism_infected` int(11) NOT NULL DEFAULT '0',
  `points_mutations` int(11) NOT NULL DEFAULT '0',
  `kills` int(11) NOT NULL DEFAULT '0',
  `headshots` int(11) NOT NULL DEFAULT '0',
  `melee_kills` int(11) NOT NULL DEFAULT '0',
  `kill_infected` int(11) NOT NULL DEFAULT '0',
  `kill_hunter` int(11) NOT NULL DEFAULT '0',
  `kill_smoker` int(11) NOT NULL DEFAULT '0',
  `kill_boomer` int(11) NOT NULL DEFAULT '0',
  `kill_spitter` int(11) NOT NULL DEFAULT '0',
  `kill_jockey` int(11) NOT NULL DEFAULT '0',
  `kill_charger` int(11) NOT NULL DEFAULT '0',
  `award_medkit` int(11) NOT NULL DEFAULT '0',
  `award_pills` int(11) NOT NULL DEFAULT '0',
  `award_adrenaline` int(11) NOT NULL DEFAULT '0',
  `award_revive` int(11) NOT NULL DEFAULT '0',
  `award_defib` int(11) NOT NULL DEFAULT '0',
  `award_rescue` int(11) NOT NULL DEFAULT '0',
  `award_protect` int(11) NOT NULL DEFAULT '0',
  `award_friendlyfire` int(11) NOT NULL DEFAULT '0',
  `award_teamkill` int(11) NOT NULL DEFAULT '0',
  `award_fincap` int(11) NOT NULL DEFAULT '0',
  `award_left4dead` int(11) NOT NULL DEFAULT '0',
  `award_letinsafehouse` int(11) NOT NULL DEFAULT '0',
  `award_witchdisturb` int(11) NOT NULL DEFAULT '0',
  PRIMARY KEY (`quarter_key`,`rank_num`),
  UNIQUE KEY `quarter_steamid` (`quarter_key`,`steamid`),
  KEY `quarter_points` (`quarter_key`,`points`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;


CREATE TABLE IF NOT EXISTS `server_settings` (
  `sname` varchar(64) CHARACTER SET utf8mb4 NOT NULL,
  `svalue` blob,
  PRIMARY KEY (`sname`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


CREATE TABLE IF NOT EXISTS `settings` (
  `steamid` varchar(255) CHARACTER SET utf8mb4 NOT NULL,
  `mute` tinyint(1) NOT NULL DEFAULT '0',
  PRIMARY KEY (`steamid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


CREATE TABLE IF NOT EXISTS `timedmaps` (
  `map` varchar(255) CHARACTER SET utf8mb4 NOT NULL,
  `gamemode` int(1) unsigned NOT NULL,
  `difficulty` int(1) unsigned NOT NULL,
  `steamid` varchar(255) CHARACTER SET utf8mb4 NOT NULL,
  `plays` int(11) NOT NULL,
  `time` double NOT NULL,
  `players` int(2) NOT NULL,
  `modified` datetime NOT NULL,
  `created` date NOT NULL,
  `mutation` varchar(64) CHARACTER SET utf8mb4 NOT NULL DEFAULT '',
  `mode` int(1) unsigned NOT NULL DEFAULT '0',
  `sinum` int(1) unsigned NOT NULL DEFAULT '0',
  `sitime` int(1) unsigned NOT NULL DEFAULT '0',
  `usebuy` int(1) unsigned NOT NULL DEFAULT '0',
  `auto` int(1) unsigned NOT NULL DEFAULT '0',
  `anneversion` varchar(64) CHARACTER SET utf8mb4 NOT NULL DEFAULT 'None',
  PRIMARY KEY (`map`,`gamemode`,`difficulty`,`steamid`,`time`,`mutation`,`mode`,`sinum`,`sitime`,`usebuy`,`anneversion`,`auto`,`players`),
  KEY `idx_steamid` (`steamid`),
  KEY `idx_timedmaps_filter_time` (`anneversion`,`sinum`,`sitime`,`usebuy`,`auto`,`mode`,`time`),
  KEY `idx_timedmaps_filter_players_time` (`anneversion`,`sinum`,`sitime`,`usebuy`,`auto`,`mode`,`players`,`time`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


CREATE TABLE IF NOT EXISTS `timedmap_runs` (
  `run_id` varchar(64) NOT NULL,
  `map` varchar(255) CHARACTER SET utf8mb4 NOT NULL,
  `gamemode` int(1) unsigned NOT NULL,
  `difficulty` int(1) unsigned NOT NULL,
  `steamid` varchar(255) CHARACTER SET utf8mb4 NOT NULL,
  `time` double NOT NULL,
  `players` int(2) NOT NULL,
  `mutation` varchar(64) CHARACTER SET utf8mb4 NOT NULL DEFAULT '',
  `mode` int(1) unsigned NOT NULL DEFAULT '0',
  `sinum` int(1) unsigned NOT NULL DEFAULT '0',
  `sitime` int(1) unsigned NOT NULL DEFAULT '0',
  `usebuy` int(1) unsigned NOT NULL DEFAULT '0',
  `auto` int(1) unsigned NOT NULL DEFAULT '0',
  `anneversion` varchar(64) CHARACTER SET utf8mb4 NOT NULL DEFAULT 'None',
  `created` datetime NOT NULL,
  `modified` datetime NOT NULL,
  PRIMARY KEY (`run_id`,`steamid`),
  KEY `idx_timedmap_runs_filter_time` (`map`,`mode`,`difficulty`,`sinum`,`sitime`,`usebuy`,`anneversion`,`time`),
  KEY `idx_timedmap_runs_steamid` (`steamid`,`modified`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


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

SET foreign_key_checks = 1;
