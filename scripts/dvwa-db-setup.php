<?php
// Minimal DVWA DB setup - creates tables and the admin user
// admin password = 'password' (MD5: 5f4dcc3b5aa765d61d8327deb882cf99)

$conn = new mysqli('127.0.0.1', 'app', 'vulnerables', 'dvwa');
if ($conn->connect_error) {
    die("Connection failed: " . $conn->connect_error . "\n");
}

$queries = [
    'DROP TABLE IF EXISTS guestbook',
    'DROP TABLE IF EXISTS users',
    'CREATE TABLE guestbook (
        comment_id INT UNSIGNED NOT NULL AUTO_INCREMENT,
        comment VARCHAR(300) NOT NULL,
        name VARCHAR(100) NOT NULL,
        PRIMARY KEY (comment_id)
    )',
    "INSERT INTO guestbook (comment, name) VALUES ('This is a test comment', 'test')",
    'CREATE TABLE users (
        user_id INT(6) UNSIGNED AUTO_INCREMENT,
        first_name VARCHAR(15) NOT NULL,
        last_name VARCHAR(15) NOT NULL,
        user VARCHAR(15),
        password VARCHAR(32),
        avatar VARCHAR(70),
        last_login TIMESTAMP,
        failed_login INT(3),
        PRIMARY KEY(user_id)
    )',
    "INSERT INTO users VALUES ('1','admin','admin','admin','5f4dcc3b5aa765d61d8327deb882cf99','http://127.0.0.1/hackable/users/admin.jpg', NOW(), '0')",
    "INSERT INTO users VALUES ('2','Gordon','Brown','gordonb','e99a18c428cb38d5f260853678922e03','http://127.0.0.1/hackable/users/gordonb.jpg', NOW(), '0')",
    "INSERT INTO users VALUES ('3','Hack','Me','1337','8d3533d75ae2c3966d7e0d4fcc69216b','http://127.0.0.1/hackable/users/1337.jpg', NOW(), '0')",
    "INSERT INTO users VALUES ('4','Pablo','Picasso','pablo','0d107d09f5bbe40cade3de5c71e9e9b7','http://127.0.0.1/hackable/users/pablo.jpg', NOW(), '0')",
    "INSERT INTO users VALUES ('5','Bob','Smith','smithy','5f4dcc3b5aa765d61d8327deb882cf99','http://127.0.0.1/hackable/users/smithy.jpg', NOW(), '0')",
];

foreach ($queries as $q) {
    $result = $conn->query($q);
    $label = substr(trim(preg_replace('/\s+/', ' ', $q)), 0, 60);
    if ($result === false) {
        echo "FAIL: $label -> " . $conn->error . "\n";
    } else {
        echo "OK: $label\n";
    }
}

echo "\nVerification:\n";
$r = $conn->query('SELECT user, password FROM users');
while ($row = $r->fetch_assoc()) {
    echo "  User: {$row['user']}  Hash: {$row['password']}\n";
}

$conn->close();
