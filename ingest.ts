import { JetstreamSubscription } from "@atcute/jetstream";
import { AppBskyFeedPost, AppBskyFeedRepost } from "@atcute/bluesky";
import { is } from "@atcute/lexicons";
import { db, getConfig, setConfig } from "./db.ts";

const CURSOR_KEY = "cursor";

const subscription = new JetstreamSubscription({
	url: [
		"wss://jetstream1.us-east.bsky.network",
		"wss://jetstream2.us-east.bsky.network",
	],
    wantedCollections: [
        "app.bsky.feed.post",
        "app.bsky.feed.repost"
    ],
    cursor: parseInt(getConfig(CURSOR_KEY) || "0"),
});

setInterval(() => {
    console.log(`committing cursor ${subscription.cursor}`);
	setConfig(CURSOR_KEY, String(subscription.cursor));
}, 5_000);

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

const didFromAturi = (aturi: string): string => aturi.substring(4).split("/")[0]

console.log("ready to consume");
for await (const event of subscription) {
	if (event.kind === "commit" && event.commit.operation === "create") {
        const record = event.commit.record;
        const aturi = `at://${event.did}/${event.commit.collection}/${event.commit.rkey}`;
        switch (event.commit.collection) {
            case "app.bsky.feed.post":
                if (!is(AppBskyFeedPost.mainSchema, record)) {
                    console.log(`ignoring invalid record ${aturi}`);
                    break;
                }
                if (record.reply === undefined) {
                    ingestPost.run(aturi, event.time_us, event.did);
                } else {
                    ingestReplier.run(aturi, event.time_us, event.did);
                    ingestRepliee.run(aturi, event.time_us, didFromAturi(record.reply.parent.uri));
                }
                break;

            case "app.bsky.feed.repost":
                if (!is(AppBskyFeedRepost.mainSchema, record)) {
                    console.log(`ignoring invalid record ${aturi}`);
                    break;
                }
                ingestRepost.run(aturi, record.subject.uri, event.time_us, event.did);
                break;
        }
    } else if (event.kind === "commit" && event.commit.operation === "delete") {
        ingestDelete.run(`at://${event.did}/${event.commit.collection}/${event.commit.rkey}`);
    }
}
