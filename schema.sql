BEGIN TRANSACTION;
CREATE TABLE IF NOT EXISTS posts(
    feed TEXT NOT NULL,
    rt TEXT,
    aturi TEXT NOT NULL,
    ts INTEGER NOT NULL,
    PRIMARY KEY (feed, aturi)
) STRICT;
CREATE INDEX IF NOT EXISTS post_time ON posts (feed, ts);

CREATE TABLE IF NOT EXISTS follows(
    follower TEXT NOT NULL,
    followee TEXT NOT NULL,
    posts INTEGER NOT NULL,
    replies INTEGER NOT NULL,
    replies_to INTEGER NOT NULL,
    reposts INTEGER NOT NULL,
    PRIMARY KEY (follower, followee)
) STRICT;
CREATE INDEX IF NOT EXISTS follow_followee ON follows (followee);
COMMIT;
