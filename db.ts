import { Database } from "@db/sqlite";

export const db = new Database("./priv.db");

const qGetConfig = db.prepare("SELECT v FROM config WHERE k = ?");
const qSetConfig = db.prepare("INSERT OR REPLACE INTO config(k,v) VALUES (?,?)");
export const getConfig = (k: string) => qGetConfig.value<string[]>(k)?.[0];
export const setConfig = (k: string, v: string) => qSetConfig.run(k, v);

db.exec(`pragma journal_mode = WAL;`);

db.exec(`
CREATE TABLE IF NOT EXISTS config(k TEXT PRIMARY KEY NOT NULL, v TEXT NOT NULL) STRICT;

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
`);
