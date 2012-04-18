--
-- NSS schema (with sample queries)
-- Rootnode, http://rootnode.net
--
-- Copyright (C) 2012 Marcin Hlybin
-- All rights reserved.
--

CREATE DATABASE nss; 
USE nss;

CREATE TABLE all_groups (
	group_id int(11) NOT NULL auto_increment primary key,
	gid smallint unsigned UNIQUE NOT NULL,
	group_name varchar(30) DEFAULT '' NOT NULL, 
	status char(1) DEFAULT 'A', 
	group_password char(1) DEFAULT 'x' NOT NULL,
	owner smallint unsigned NOT NULL,
	KEY(gid),
	KEY(owner)
) ENGINE=InnoDB, CHARACTER SET=UTF8;

CREATE TABLE all_users (
	user_id int(11) NOT NULL auto_increment primary key,
	uid smallint unsigned UNIQUE NOT NULL, 
	gid smallint unsigned DEFAULT '100' NOT NULL, 
	user_name varchar(50) DEFAULT '' NOT NULL, 	
	realname varchar(32) DEFAULT '' NOT NULL, 
	shell varchar(20) DEFAULT '/bin/bash' NOT NULL, 	
	password varchar(40) DEFAULT '' NOT NULL, 
	status char(1) DEFAULT 'N' NOT NULL, 
	homedir varchar(32) DEFAULT '' NOT NULL, 	
	lastchange varchar(50) NOT NULL default '', 
	min int(11) NOT NULL default '0', 
	max int(11) NOT NULL default '0',
	warn int(11) NOT NULL default '7', 
	inact int(11) NOT NULL default '-1', 
	expire int(11) NOT NULL default '-1',
	owner smallint unsigned NOT NULL,
	KEY(uid),
	KEY(owner)
) ENGINE=InnoDB, CHARACTER SET=UTF8;

CREATE TABLE all_user_group ( 
	user_id int(11) DEFAULT '0' NOT NULL, 
	group_id int(11) DEFAULT '0' NOT NULL,
	owner smallint unsigned NOT NULL,
	PRIMARY KEY(user_id,group_id),
	KEY(user_id),
	KEY(owner)
) ENGINE=InnoDB, CHARACTER SET=UTF8;

CREATE VIEW user       AS SELECT * FROM all_users      WHERE CONCAT(owner, '-passwd') = SUBSTRING_INDEX(USER(), '@', 1) OR CONCAT(owner, '-shadow') = SUBSTRING_INDEX(USER(), '@', 1 ); 
CREATE VIEW groups     AS SELECT * FROM all_groups     WHERE CONCAT(owner, '-passwd') = SUBSTRING_INDEX(USER(), '@', 1) OR CONCAT(owner, '-shadow') = SUBSTRING_INDEX(USER(), '@', 1 );
CREATE VIEW user_group AS SELECT * FROM all_user_group WHERE CONCAT(owner, '-passwd') = SUBSTRING_INDEX(USER(), '@', 1) OR CONCAT(owner, '-shadow') = SUBSTRING_INDEX(USER(), '@', 1 ); 

-- Sample grants --
GRANT select(user_name,user_id,uid,gid,realname,shell,homedir,status) on user       to '6666-passwd' identified by 'PASSWORD_HERE'
GRANT select(group_name,group_id,gid,group_password,status)           on groups     to '6666-passwd' identified by 'PASSWORD_HERE'; 
GRANT select(user_id,group_id)                                        on user_group to '6666-passwd' identified by 'PASSWORD_HERE';
GRANT select(user_name,password,uid,gid,realname,shell,homedir,status,lastchange,min,max,warn,inact,expire) on user to '6666-shadow' identified by 'PASSWORD_HERE'; 
GRANT update(user_name,password,uid,gid,realname,shell,homedir,status,lastchange,min,max,warn,inact,expire) on user to '6666-shadow' identified by 'PASSWORD_HERE'; 
FLUSH PRIVILEGES;

-- Sample users --
insert into all_users(user_id,uid,gid,user_name,realname,password,status,homedir,lastchange,owner) values (1,6666,100,'user1','user1','','A','/home/user1',0,6666);
insert into all_users(user_id,uid,gid,user_name,realname,password,status,homedir,lastchange,owner) values (2,6667,100,'user2','user2','','A','/home/user2',0,6667);
insert into all_groups(group_id,gid,group_name,owner) values(1,6666,'user1',6666);
insert into all_groups(group_id,gid,group_name,owner) values(2,6667,'user2',6667);
insert into all_user_group(user_id,group_id,owner) values(1,1,6666);
insert into all_user_group(user_id,group_id,owner) values(2,2,6667);
