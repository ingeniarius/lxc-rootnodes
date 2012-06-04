--
-- Adduser and Signup database schema
-- Rootnode, http://rootnode.net
--
-- Copyright (C) 2012 Marcin Hlybin
-- All rights reserved.
--

CREATE DATABASE adduser;
USE adduser;

CREATE TABLE users (
	uid SMALLINT UNSIGNED,
	user_name VARCHAR(32) NOT NULL,
	mail VARCHAR(255) NOT NULL,
	created_at DATETIME,
	updated_at TIMESTAMP,	
	expires_at DATETIME,
	valid_to DATETIME DEFAULT NULL,
	PRIMARY KEY (uid),
	KEY (user_name),
	KEY (mail)
) ENGINE=InnoDB, CHARACTER SET=UTF8;

CREATE TABLE containers (
	uid SMALLINT UNSIGNED,
	server_type CHAR(8) NOT NULL,
	server_no SMALLINT NOT NULL,
	status VARCHAR(32) DEFAULT NULL,
	created_at DATETIME,
	updated_at TIMESTAMP,
	PRIMARY KEY(uid, server_type),
	FOREIGN KEY (uid) REFERENCES users(uid) ON DELETE CASCADE
) ENGINE=InnoDB, CHARACTER SET=UTF8;

CREATE TABLE credentials (
	uid SMALLINT UNSIGNED,
	satan_key VARCHAR(128),
	pam_passwd VARCHAR(128),
	pam_shadow VARCHAR(128),
	user_password VARCHAR(128),
	user_password_p VARCHAR(128),
	PRIMARY KEY(uid),
	FOREIGN KEY (uid) REFERENCES users(uid) ON DELETE CASCADE
) ENGINE=InnoDB, CHARACTER SET=UTF8;

CREATE DATABASE signup;
USE signup;

CREATE TABLE users (
	id INT AUTO_INCREMENT,
	user_name VARCHAR(32) UNIQUE,
	mail VARCHAR(255) NOT NULL,
	status VARCHAR(255) DEFAULT NULL,
	created_at DATETIME,
	updated_at TIMESTAMP,
	PRIMARY KEY (id)
) ENGINE=InnoDB, CHARACTER SET=UTF8;
