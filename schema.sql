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

# INSERT INTO posts(feed, aturi, ts)
# SELECT follower, ?, ?
# FROM follows
# WHERE followee = ? AND posts = 1

# SELECT aturi, rt, ts
# FROM posts
# WHERE feed = ? AND ts < ?
# ORDER BY ts DESC
# LIMIT ?

# INSERT INTO posts(feed, aturi, ts)
# VALUES ('did:plc:ezhjhbzqt32bqprrn6qjlkri', 'at://did:plc:5kr7qxme46hlriffmq3k74rj/app.bsky.feed.post/3m4nuy5vdgdl2', 1762918497216630);
