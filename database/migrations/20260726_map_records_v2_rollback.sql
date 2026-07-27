-- Emergency rollback for map records v2.
-- The legacy timedmaps/timedmap_runs tables are not touched by the forward migration.
DROP TABLE IF EXISTS `map_run_players`;
DROP TABLE IF EXISTS `map_runs`;
DROP TABLE IF EXISTS `legacy_map_bests`;
