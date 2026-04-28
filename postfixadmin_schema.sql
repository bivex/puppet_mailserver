-- PostfixAdmin 3.3 database schema
-- Matches the tables created by postfixadmin upgrade.php
-- PK uses natural keys (domain varchar, username varchar, address varchar)

CREATE TABLE IF NOT EXISTS admin (
    username varchar(255) NOT NULL,
    password varchar(255) NOT NULL,
    created datetime NOT NULL DEFAULT '2000-01-01 00:00:00',
    modified datetime NOT NULL DEFAULT '2000-01-01 00:00:00',
    active tinyint(1) NOT NULL DEFAULT 1,
    superadmin tinyint(1) NOT NULL DEFAULT 0,
    phone varchar(30) NOT NULL DEFAULT '',
    email_other varchar(255) NOT NULL DEFAULT '',
    token varchar(255) NOT NULL DEFAULT '',
    token_validity datetime NOT NULL DEFAULT '2000-01-01 00:00:00',
    PRIMARY KEY (username)
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_general_ci;

CREATE TABLE IF NOT EXISTS domain (
    domain varchar(255) NOT NULL,
    description varchar(255) NOT NULL DEFAULT '',
    aliases int(10) NOT NULL DEFAULT 0,
    mailboxes int(10) NOT NULL DEFAULT 0,
    maxquota bigint(20) NOT NULL DEFAULT 0,
    quota bigint(20) NOT NULL DEFAULT 0,
    transport varchar(255) NOT NULL DEFAULT '',
    backupmx tinyint(1) NOT NULL DEFAULT 0,
    created datetime NOT NULL DEFAULT '2000-01-01 00:00:00',
    modified datetime NOT NULL DEFAULT '2000-01-01 00:00:00',
    active tinyint(1) NOT NULL DEFAULT 1,
    password_expiry int(11) DEFAULT 0,
    PRIMARY KEY (domain)
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_general_ci;

CREATE TABLE IF NOT EXISTS domain_admins (
    id int(11) NOT NULL AUTO_INCREMENT,
    username varchar(255) NOT NULL,
    domain varchar(255) NOT NULL,
    created datetime NOT NULL DEFAULT '2000-01-01 00:00:00',
    active tinyint(1) NOT NULL DEFAULT 1,
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_general_ci;

CREATE TABLE IF NOT EXISTS mailbox (
    username varchar(255) NOT NULL,
    password varchar(255) NOT NULL,
    name varchar(255) NOT NULL DEFAULT '',
    maildir varchar(255) NOT NULL DEFAULT '',
    quota bigint(20) NOT NULL DEFAULT 0,
    local_part varchar(255) NOT NULL DEFAULT '',
    domain varchar(255) NOT NULL DEFAULT '',
    created datetime NOT NULL DEFAULT '2000-01-01 00:00:00',
    modified datetime NOT NULL DEFAULT '2000-01-01 00:00:00',
    active tinyint(1) NOT NULL DEFAULT 1,
    phone varchar(30) NOT NULL DEFAULT '',
    email_other varchar(255) NOT NULL DEFAULT '',
    token varchar(255) NOT NULL DEFAULT '',
    token_validity datetime NOT NULL DEFAULT '2000-01-01 00:00:00',
    password_expiry datetime NOT NULL DEFAULT '2000-01-01 00:00:00',
    PRIMARY KEY (username)
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_general_ci;

CREATE TABLE IF NOT EXISTS alias (
    address varchar(255) NOT NULL,
    goto text NOT NULL,
    domain varchar(255) NOT NULL,
    created datetime NOT NULL DEFAULT '2000-01-01 00:00:00',
    modified datetime NOT NULL DEFAULT '2000-01-01 00:00:00',
    active tinyint(1) NOT NULL DEFAULT 1,
    PRIMARY KEY (address)
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_general_ci;

CREATE TABLE IF NOT EXISTS alias_domain (
    alias_domain varchar(255) NOT NULL DEFAULT '',
    target_domain varchar(255) NOT NULL DEFAULT '',
    created datetime NOT NULL DEFAULT '2000-01-01 00:00:00',
    modified datetime NOT NULL DEFAULT '2000-01-01 00:00:00',
    active tinyint(1) NOT NULL DEFAULT 1,
    PRIMARY KEY (alias_domain)
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_general_ci;

CREATE TABLE IF NOT EXISTS log (
    id int(11) NOT NULL AUTO_INCREMENT,
    timestamp datetime NOT NULL DEFAULT '2000-01-01 00:00:00',
    username varchar(255) NOT NULL,
    domain varchar(255) NOT NULL,
    action varchar(255) NOT NULL,
    data text NOT NULL,
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_general_ci;

CREATE TABLE IF NOT EXISTS vacation (
    email varchar(255) NOT NULL,
    subject varchar(255) NOT NULL DEFAULT '',
    body text NOT NULL,
    cache text NOT NULL,
    domain varchar(255) NOT NULL DEFAULT '',
    created datetime NOT NULL DEFAULT '2000-01-01 00:00:00',
    active tinyint(1) NOT NULL DEFAULT 1,
    activefrom timestamp NOT NULL DEFAULT '2000-01-01 00:00:00',
    activeuntil timestamp NOT NULL DEFAULT '2038-01-18 00:00:00',
    interval_time int(11) NOT NULL DEFAULT 0,
    PRIMARY KEY (email)
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_general_ci;

CREATE TABLE IF NOT EXISTS vacation_notification (
    id int(11) NOT NULL AUTO_INCREMENT,
    on_vacation varchar(255) NOT NULL,
    notified varchar(255) NOT NULL,
    notified_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    CONSTRAINT vacation_notification_pkey UNIQUE (on_vacation, notified)
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_general_ci;

CREATE TABLE IF NOT EXISTS quota (
    username varchar(255) NOT NULL,
    path varchar(100) NOT NULL,
    current bigint(20) NOT NULL DEFAULT 0,
    PRIMARY KEY (username, path)
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_general_ci;

CREATE TABLE IF NOT EXISTS quota2 (
    username varchar(255) NOT NULL,
    bytes bigint(20) NOT NULL DEFAULT 0,
    messages int(11) NOT NULL DEFAULT 0,
    PRIMARY KEY (username)
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_general_ci;

CREATE TABLE IF NOT EXISTS config (
    id int(11) NOT NULL AUTO_INCREMENT,
    name varchar(20) NOT NULL DEFAULT '',
    value varchar(20) NOT NULL DEFAULT '',
    PRIMARY KEY (id),
    UNIQUE KEY name (name)
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_general_ci;

CREATE TABLE IF NOT EXISTS fetchmail (
    id int(11) unsigned NOT NULL AUTO_INCREMENT,
    mailbox varchar(255) NOT NULL DEFAULT '',
    src_server varchar(255) NOT NULL DEFAULT '',
    src_auth enum('password','kerberos_v5','kerberos','kerberos_v4','gssapi','cram-md5','otp','ntlm','msn','ssh','any') DEFAULT NULL,
    src_user varchar(255) NOT NULL DEFAULT '',
    src_password varchar(255) NOT NULL DEFAULT '',
    src_folder varchar(255) NOT NULL DEFAULT '',
    poll_time int(11) unsigned NOT NULL DEFAULT 10,
    fetchall tinyint(1) unsigned NOT NULL DEFAULT 0,
    keep tinyint(1) unsigned NOT NULL DEFAULT 0,
    protocol enum('POP3','IMAP','POP2','ETRN','AUTO') DEFAULT NULL,
    usessl tinyint(1) unsigned NOT NULL DEFAULT 0,
    extra_options text DEFAULT NULL,
    returned_text text DEFAULT NULL,
    mda varchar(255) NOT NULL DEFAULT '',
    date timestamp NOT NULL DEFAULT '2000-01-01 00:00:00',
    sslcertck tinyint(1) NOT NULL DEFAULT 0,
    sslcertpath varchar(255) DEFAULT '',
    sslfingerprint varchar(255) DEFAULT '',
    domain varchar(255) DEFAULT '',
    active tinyint(1) NOT NULL DEFAULT 0,
    created timestamp NOT NULL DEFAULT '2000-01-01 00:00:00',
    modified timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    src_port int(11) NOT NULL DEFAULT 0,
    PRIMARY KEY (id)
) ENGINE=InnoDB DEFAULT CHARSET=latin1 COLLATE=latin1_general_ci;
