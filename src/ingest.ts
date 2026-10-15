import { subscribeEvents } from "@atcute/jetstream";
import { AppBskyFeedPost, AppBskyFeedRepost } from "@atcute/bluesky";
import { is } from "@atcute/lexicons";
import { db, getConfig, setConfig } from "./db.ts";
import { pipe, didFromAturi } from "./utils.ts";

const CURSOR_KEY = "cursor";

const subscription = subscribeEvents({
	service: "wss://jetstream.us-east.bsky.network",
    collections: [
        "app.bsky.feed.post",
        "app.bsky.feed.repost"
    ],
    cursor: {
		load() {
			return pipe(getConfig(CURSOR_KEY), Number);
		},
		save(seq) {
			setConfig(CURSOR_KEY, String(seq));
            console.log(`committed cursor ${seq}`)
		},
	}
});

const maxPostsPerFeed = pipe(getConfig("maxPostsPerFeed"), parseInt);
if (maxPostsPerFeed !== undefined) {
    const getToPrune = db.prepare(`WITH postn AS (
        SELECT feed, ts,
            ROW_NUMBER() OVER (PARTITION BY feed ORDER BY ts DESC) AS n
        FROM posts)
        SELECT feed, ts FROM postn WHERE n = ?`);

    const prune = db.prepare(`DELETE FROM posts WHERE feed = ? AND ts < ?`);

    setInterval(() => {
        const toPrune = getToPrune.values(maxPostsPerFeed);
        for (const [feed,ts] of toPrune)
            prune.run(feed, ts);
    }, pipe(getConfig("pruneInterval"), parseInt) || 3600000);
}

const ingestRepost = db.prepare(`
    INSERT OR IGNORE INTO posts(feed, rt, aturi, ts)
    SELECT follower, ?, ?, ?
    FROM follows
    WHERE followee = ? AND reposts = 1`);

const ingestPost = db.prepare(`
    INSERT OR IGNORE INTO posts(feed, aturi, ts)
    SELECT follower, ?, ?
    FROM follows
    WHERE followee = ? AND posts = 1`);

const ingestReplier = db.prepare(`
    INSERT OR IGNORE INTO posts(feed, aturi, ts)
    SELECT follower, ?, ?
    FROM follows
    WHERE followee = ? AND replies = 1`);

const ingestRepliee = db.prepare(`
    INSERT OR IGNORE INTO posts(feed, aturi, ts)
    SELECT follower, ?, ?
    FROM follows
    WHERE followee = ? AND replies_to = 1`);

const ingestDelete = db.prepare(`DELETE FROM posts WHERE aturi = ?`);

console.log("ready to consume");
for await (const event of subscription) {
	if (event.$type !== 'network.bsky.jetstream.subscribeEvents#commit') continue;

	if (event.operation === "create") {
        const record = event.record;
        const aturi = `at://${event.did}/${event.collection}/${event.rkey}`;
        const time = Temporal.Instant.from("2024-09-09T19:46:02.329308Z").epochNanoseconds/1000n;
        switch (event.collection) {
            case "app.bsky.feed.post":
                if (!is(AppBskyFeedPost.mainSchema, record)) {
                    console.log(`ignoring invalid record ${aturi}`);
                    break;
                }
                if (record.reply === undefined) {
                    ingestPost.run(aturi, time, event.did);
                } else {
                    ingestReplier.run(aturi, time, event.did);
                    ingestRepliee.run(aturi, time, didFromAturi(record.reply.parent.uri));
                }
                break;

            case "app.bsky.feed.repost":
                if (!is(AppBskyFeedRepost.mainSchema, record)) {
                    console.log(`ignoring invalid record ${aturi}`);
                    break;
                }
                ingestRepost.run(aturi, record.subject.uri, time, event.did);
                break;
        }
    } else if (event.operation === "delete") {
        ingestDelete.run(`at://${event.did}/${event.collection}/${event.rkey}`);
    }
}
