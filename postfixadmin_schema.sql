-- PostfixAdmin database schema (from upgrade.php)
-- Tables: admin, alias, domain, mailbox, log, vacation, config, domain_admins

CREATE TABLE IF NOT EXISTS admin (
    username varchar(255) NOT NULL,
    password varchar(255) NOT NULL,
    superadmin tinyint(1) NOT NULL DEFAULT 0,
    created datetime NOT NULL,
    modified datetime NOT NULL,
    active tinyint(1) NOT NULL DEFAULT 1,
    PRIMARY KEY (username)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS alias (
    id int(11) NOT NULL AUTO_INCREMENT,
    domain_id int(11) NOT NULL,
    source varchar(100) NOT NULL,
    destination varchar(100) NOT NULL,
    created datetime NOT NULL,
    modified datetime NOT NULL,
    active tinyint(1) NOT NULL DEFAULT 1,
    PRIMARY KEY (id),
    FOREIGN KEY (domain_id) REFERENCES virtual_domains(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS domain (
    id int(11) NOT NULL AUTO_INCREMENT,
    name varchar(50) NOT NULL,
    description varchar(255) DEFAULT NULL,
    aliases int(11) NOT NULL DEFAULT 0,
    mailboxes int(11) NOT NULL DEFAULT 0,
    maxquota int(11) NOT NULL DEFAULT 0,
    quota int(11) NOT NULL DEFAULT 0,
    transport varchar(50) DEFAULT NULL,
    default_aliases_id int(11) DEFAULT NULL,
    backupmx tinyint(1) NOT NULL DEFAULT '0',
    created datetime NOT NULL,
    modified datetime NOT NULL,
    active tinyint(1) NOT NULL DEFAULT 1,
    PRIMARY KEY (id),
    UNIQUE KEY name (name)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS mailbox (
    id int(11) NOT NULL AUTO_INCREMENT,
    domain_id int(11) NOT NULL,
    username varchar(100) NOT NULL,
    password varchar(255) NOT NULL,
    name varchar(255) DEFAULT NULL,
    maildir varchar(255) DEFAULT NULL,
    quota int(11) NOT NULL DEFAULT 0,
    local_part varchar(100) NOT NULL,
    created datetime NOT NULL,
    modified datetime NOT NULL,
    active tinyint(1) NOT NULL DEFAULT 1,
    PRIMARY KEY (id),
    UNIQUE KEY username (username),
    FOREIGN KEY (domain_id) REFERENCES domain(id) ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS log (
    id int(11) NOT NULL AUTO_INCREMENT,
    username varchar(255) NOT NULL,
    domain varchar(255) NOT NULL,
    timestamp datetime NOT NULL,
    action varchar(255) NOT NULL,
    data varchar(255) DEFAULT NULL,
    PRIMARY KEY (id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS vacation (
    id int(11) NOT NULL AUTO_INCREMENT,
    email varchar(255) NOT NULL,
    subject varchar(255) NOT NULL,
    body text NOT NULL,
    cache text,
    created datetime NOT NULL,
    PRIMARY KEY (id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS config (
    id int(11) NOT NULL AUTO_INCREMENT,
    name varchar(255) NOT NULL,
    value text,
    PRIMARY KEY (id),
    UNIQUE KEY name (name)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS domain_admins (
    id int(11) NOT NULL AUTO_INCREMENT,
    username varchar(255) NOT NULL,
    domain_id int(11) NOT NULL,
    PRIMARY KEY (id),
    FOREIGN KEY (domain_id) REFERENCES domain(id) ON DELETE CASCADE
) ENGINE=InnoDB;
