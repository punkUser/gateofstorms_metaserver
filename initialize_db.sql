CREATE TABLE IF NOT EXISTS `metaserver_difficulty_levels` (
  `difficulty` tinyint(4) NOT NULL,
  `difficulty_name` varchar(32) NOT NULL,
  PRIMARY KEY (`difficulty`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `metaserver_join_room_messages` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `priority` int(11) NOT NULL DEFAULT '10000',
  `guest_only` tinyint(4) NOT NULL DEFAULT '0',
  `message` varchar(256) NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `metaserver_room_types` (
  `room_type` tinyint(4) NOT NULL,
  `room_type_name` varchar(32) NOT NULL,
  PRIMARY KEY (`room_type`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `metaserver_scorings` (
  `scoring` tinyint(4) NOT NULL,
  `scoring_name` varchar(32) NOT NULL,
  PRIMARY KEY (`scoring`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `metaserver_users` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `nick_name` varchar(32) NOT NULL,
  `team_name` varchar(32) NOT NULL,
  `primary_color` int(11) NOT NULL DEFAULT '0',
  `secondary_color` int(11) NOT NULL DEFAULT '0',
  `coat_of_arms_bitmap_index` smallint(6) NOT NULL DEFAULT '0',
  `city` text NOT NULL,
  `state` text NOT NULL,
  `country` text NOT NULL,
  `quote` text NOT NULL,
  `admin_level` smallint(6) NOT NULL DEFAULT '0',
  `registration_datetime` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `last_login_datetime` timestamp NULL DEFAULT NULL,
  `banned_until` datetime DEFAULT NULL,
  `banned_reason` varchar(32) NOT NULL DEFAULT '',
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `metaserver_login_tokens` (
  `user_id` int(11) NOT NULL,
  `steam_id` bigint(20) unsigned NOT NULL,
  `user_name_token` varchar(32) NOT NULL,
  `password_token` varchar(32) NOT NULL,
  UNIQUE KEY `steam_id` (`steam_id`),
  KEY `FK_metaserver_login_www_tokens_metaserver_users` (`user_id`),
  CONSTRAINT `FK_metaserver_login_www_tokens_metaserver_users` FOREIGN KEY (`user_id`) REFERENCES `metaserver_users` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `metaserver_games` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `room_type` tinyint(4) NOT NULL,
  `team_count` int(11) NOT NULL DEFAULT '0',
  `player_count` int(11) NOT NULL DEFAULT '0',
  `game_name` varchar(32) NOT NULL,
  `map_name` varchar(64) NOT NULL,
  `scoring` tinyint(4) NOT NULL,
  `difficulty` tinyint(4) NOT NULL,
  `time_limit` int(11) NOT NULL,
  `planning_time_limit` int(11) NOT NULL,
  `cooperative` tinyint(1) NOT NULL,
  `allow_teams` tinyint(1) NOT NULL,
  `allow_unit_trading` tinyint(1) NOT NULL,
  `allow_veterans` tinyint(1) NOT NULL,
  `allow_alliances` tinyint(1) NOT NULL,
  `overhead_map` tinyint(1) NOT NULL,
  `deathmatch` tinyint(1) NOT NULL,
  `vtfl` tinyint(1) NOT NULL,
  `anti_clump` tinyint(1) NOT NULL,
  `start_datetime` timestamp NOT NULL DEFAULT '0000-00-00 00:00:00',
  `end_datetime` timestamp NOT NULL DEFAULT '0000-00-00 00:00:00',
  `ended_code` tinyint(4) NOT NULL,
  `duration` int(11) NOT NULL,
  `recording_file_name` varchar(256) NOT NULL,
  `recording_url` varchar(256) DEFAULT NULL,
  `insert_datetime` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`),
  KEY `scoring` (`scoring`),
  KEY `difficulty` (`difficulty`),
  KEY `room_type` (`room_type`),
  CONSTRAINT `metaserver_games_ibfk_1` FOREIGN KEY (`scoring`) REFERENCES `metaserver_scorings` (`scoring`),
  CONSTRAINT `metaserver_games_ibfk_2` FOREIGN KEY (`difficulty`) REFERENCES `metaserver_difficulty_levels` (`difficulty`),
  CONSTRAINT `metaserver_games_ibfk_3` FOREIGN KEY (`room_type`) REFERENCES `metaserver_room_types` (`room_type`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `metaserver_games_teams` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `metaserver_games_id` int(11) NOT NULL,
  `place` tinyint(4) NOT NULL,
  `place_tie` tinyint(1) NOT NULL,
  `spectators` tinyint(1) NOT NULL,
  `eliminated` tinyint(1) NOT NULL,
  `team_name` varchar(32) NOT NULL,
  PRIMARY KEY (`id`),
  KEY `metaserver_games_id` (`metaserver_games_id`),
  CONSTRAINT `metaserver_games_teams_ibfk_1` FOREIGN KEY (`metaserver_games_id`) REFERENCES `metaserver_games` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `metaserver_games_teams_players` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `metaserver_games_teams_id` int(11) NOT NULL,
  `user_id` int(11) DEFAULT NULL,
  `nick_name` varchar(32) NOT NULL,
  `team_name` varchar(32) NOT NULL,
  `primary_color` int(11) NOT NULL,
  `secondary_color` int(11) NOT NULL,
  `coat_of_arms_bitmap_index` int(11) NOT NULL,
  `game_version` int(11) NOT NULL,
  `build_number` int(11) NOT NULL,
  `ip_address` varchar(45) NOT NULL,
  `host` tinyint(1) NOT NULL,
  `captain` tinyint(1) NOT NULL,
  `dropped` tinyint(1) NOT NULL,
  `units_killed` int(11) NOT NULL,
  `units_lost` int(11) NOT NULL,
  `damage_given` int(11) NOT NULL,
  `damage_taken` int(11) NOT NULL,
  PRIMARY KEY (`id`),
  KEY `metaserver_games_teams_id` (`metaserver_games_teams_id`),
  KEY `user_id` (`user_id`),
  CONSTRAINT `metaserver_games_teams_players_ibfk_1` FOREIGN KEY (`metaserver_games_teams_id`) REFERENCES `metaserver_games_teams` (`id`),
  CONSTRAINT `metaserver_games_teams_players_ibfk_2` FOREIGN KEY (`user_id`) REFERENCES `metaserver_users` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `metaserver_tournaments` (
  `tournament_id` int(11) NOT NULL AUTO_INCREMENT,
  `organizer_user_id` int(11) DEFAULT NULL,
  `tournament_name` varchar(32) NOT NULL,
  `tournament_short_name` varchar(12) NOT NULL,
  `start_date` date NOT NULL DEFAULT '1980-01-01',
  `created_datetime` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (`tournament_id`),
  UNIQUE KEY `tournament_short_name` (`tournament_short_name`),
  KEY `FK_metaserver_tournaments_metaserver_users` (`organizer_user_id`),
  CONSTRAINT `FK_metaserver_tournaments_metaserver_users` FOREIGN KEY (`organizer_user_id`) REFERENCES `metaserver_users` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `metaserver_tournaments_rounds` (
  `round_id` int(11) NOT NULL AUTO_INCREMENT,
  `tournament_id` int(11) DEFAULT NULL,
  `round_name` varchar(32) NOT NULL,
  PRIMARY KEY (`round_id`),
  KEY `tournament_id` (`tournament_id`),
  CONSTRAINT `tournament_id` FOREIGN KEY (`tournament_id`) REFERENCES `metaserver_tournaments` (`tournament_id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE TABLE IF NOT EXISTS `metaserver_tournaments_rounds_games` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `round_id` int(11) NOT NULL,
  `game_id` int(11) NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `unique_round_game` (`round_id`,`game_id`),
  KEY `game_id` (`game_id`),
  CONSTRAINT `metaserver_tournaments_rounds_games_ibfk_1` FOREIGN KEY (`round_id`) REFERENCES `metaserver_tournaments_rounds` (`round_id`),
  CONSTRAINT `metaserver_tournaments_rounds_games_ibfk_2` FOREIGN KEY (`game_id`) REFERENCES `metaserver_games` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8;

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `metaserver_players_stats_view` AS select `metaserver_users`.`id` AS `user_id`,`metaserver_users`.`nick_name` AS `nick_name`,`metaserver_games_teams_players`.`captain` AS `captain`,`metaserver_games_teams_players`.`units_killed` AS `units_killed`,`metaserver_games_teams_players`.`units_lost` AS `units_lost`,`metaserver_games_teams_players`.`damage_given` AS `damage_given`,`metaserver_games_teams_players`.`damage_taken` AS `damage_taken`,if(((`metaserver_games_teams`.`place` = 1) and (`metaserver_games_teams`.`place_tie` <> 1)),1,0) AS `win`,if(((`metaserver_games_teams`.`place` = 1) and (`metaserver_games_teams`.`place_tie` = 1)),1,0) AS `tie`,if((`metaserver_games_teams`.`place` <> 1),1,0) AS `loss` from (((`metaserver_users` join `metaserver_games_teams_players` on((`metaserver_games_teams_players`.`user_id` = `metaserver_users`.`id`))) join `metaserver_games_teams` on((`metaserver_games_teams`.`id` = `metaserver_games_teams_players`.`metaserver_games_teams_id`))) join `metaserver_games` on((`metaserver_games`.`id` = `metaserver_games_teams`.`metaserver_games_id`))) where ((`metaserver_games_teams`.`spectators` = 0) and (`metaserver_games`.`cooperative` = 0));

CREATE ALGORITHM=UNDEFINED DEFINER=`root`@`localhost` SQL SECURITY DEFINER VIEW `metaserver_tournaments_players_stats_view` AS select `metaserver_tournaments_rounds`.`tournament_id` AS `tournament_id`,`metaserver_tournaments_rounds`.`round_id` AS `round_id`,`metaserver_users`.`id` AS `user_id`,`metaserver_users`.`nick_name` AS `nick_name`,`metaserver_games_teams_players`.`captain` AS `captain`,`metaserver_games_teams_players`.`units_killed` AS `units_killed`,`metaserver_games_teams_players`.`units_lost` AS `units_lost`,`metaserver_games_teams_players`.`damage_given` AS `damage_given`,`metaserver_games_teams_players`.`damage_taken` AS `damage_taken`,if(((`metaserver_games_teams`.`place` = 1) and (`metaserver_games_teams`.`place_tie` <> 1)),1,0) AS `win`,if(((`metaserver_games_teams`.`place` = 1) and (`metaserver_games_teams`.`place_tie` = 1)),1,0) AS `tie`,if((`metaserver_games_teams`.`place` <> 1),1,0) AS `loss` from (((((`metaserver_users` join `metaserver_games_teams_players` on((`metaserver_games_teams_players`.`user_id` = `metaserver_users`.`id`))) join `metaserver_games_teams` on((`metaserver_games_teams`.`id` = `metaserver_games_teams_players`.`metaserver_games_teams_id`))) join `metaserver_games` on((`metaserver_games`.`id` = `metaserver_games_teams`.`metaserver_games_id`))) join `metaserver_tournaments_rounds_games` on((`metaserver_tournaments_rounds_games`.`game_id` = `metaserver_games`.`id`))) join `metaserver_tournaments_rounds` on((`metaserver_tournaments_rounds`.`round_id` = `metaserver_tournaments_rounds_games`.`round_id`))) where (`metaserver_games_teams`.`spectators` = 0);

INSERT INTO `metaserver_difficulty_levels` (`difficulty`, `difficulty_name`) VALUES
	(0, 'Timid'),
	(1, 'Simple'),
	(2, 'Normal'),
	(3, 'Heroic'),
	(4, 'Legendary');
	
INSERT INTO `metaserver_join_room_messages` (`priority`, `guest_only`, `message`) VALUES
	(1, 0, 'Welcome to GateOfStorms.net!'),
	(100, 1, 'You are logged in as a guest, so ranked and tournament rooms are unavailable.'),
	(101, 1, 'If you wish to create an account, please visit http://gateofstorms.net.');
	
INSERT INTO `metaserver_room_types` (`room_type`, `room_type_name`) VALUES
	(0, 'Unranked'),
	(1, 'Ranked'),
	(2, 'Tournament');
	
INSERT INTO `metaserver_scorings` (`scoring`, `scoring_name`) VALUES
	(0, 'Body Count'),
	(1, 'Steal the Bacon'),
	(2, 'Last Man on the Hill'),
	(3, 'Scavenger Hunt'),
	(4, 'Flag Rally'),
	(5, 'Capture the Flag'),
	(6, 'Balls on Parade'),
	(7, 'Territories'),
	(8, 'Captures'),
	(9, 'King of the Hill'),
	(10, 'Stampede'),
	(11, 'Assassin'),
	(12, 'Hunting'),
	(13, 'Co-op'),
	(14, 'King of the Hill (TFL)'),
	(15, 'King of the Map');
