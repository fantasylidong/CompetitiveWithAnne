-- Add per-player hitsound playback preferences.
-- hitsound_headkill stores a sound-set ID (0=use the regular headshot sound).
-- NULL lets the plugin migrate an existing player's SoundSelect.txt values on first load.

ALTER TABLE `RPG`
  ADD COLUMN `hitsound_stack_mode` tinyint(4) DEFAULT NULL AFTER `hiticon_si_only`,
  ADD COLUMN `hitsound_headkill` tinyint(4) DEFAULT NULL AFTER `hitsound_stack_mode`;
