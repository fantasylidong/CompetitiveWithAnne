-- Adminer 4.8.1 MySQL 5.7.41 dump

SET NAMES utf8;
SET time_zone = '+00:00';
SET foreign_key_checks = 0;
SET sql_mode = 'NO_AUTO_VALUE_ON_ZERO';

SET NAMES utf8mb4;

DROP TABLE IF EXISTS `chat_log`;
CREATE TABLE `chat_log` (
  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `date` datetime DEFAULT NULL,
  `map` varchar(128) NOT NULL,
  `steamid` varchar(21) NOT NULL,
  `name` varchar(128) NOT NULL,
  `message_style` tinyint(2) DEFAULT '0',
  `message` varchar(126) NOT NULL,
  `server` varchar(126) DEFAULT NULL,
  `port` int(11) DEFAULT NULL,
  PRIMARY KEY (`id`) USING BTREE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;


-- 2023-09-14 02:09:31
