--
-- Vsftpd PAM auth schema
-- Rootnode, http://rootnode.net
--
-- Copyright (C) 2012 Marcin Hlybin
-- All rights reserved.
--

-- Database --
CREATE DATABASE ftp;
USE ftp;

-- Tables --
CREATE TABLE all_users (
	uid SMALLINT UNSIGNED NOT NULL,
	user_name VARCHAR(32) NOT NULL,
	server_name VARCHAR(16) NOT NULL,
	password CHAR(41) NOT NULL,
	directory VARCHAR(255) NOT NULL,
	mkdir_priv BOOLEAN DEFAULT 1,
	delete_priv BOOLEAN DEFAULT 1,
	upload_priv BOOLEAN DEFAULT 1,
	read_priv BOOLEAN DEFAULT 1,
	ssl_priv BOOLEAN DEFAULT 1,
	created_at DATETIME NOT NULL,
	updated_at TIMESTAMP NOT NULL,
	owner SMALLINT UNSIGNED NOT NULL,
	PRIMARY KEY(uid, user_name)
) ENGINE=InnoDB, CHARACTER SET=UTF8;

-- Views --
CREATE VIEW users AS SELECT * FROM all_users WHERE CONCAT(owner, '-ftp') = SUBSTRING_INDEX(USER(), '@', 1);

-- Sample grants --
GRANT SELECT on users to 'UID_HERE-ftp' identified by 'PASSWORD_HERE';
FLUSH PRIVILEGES;

