import { XRPCRouter, AuthRequiredError, InvalidRequestError, json } from "@atcute/xrpc-server";
import { ServiceJwtVerifier, type VerifiedJwt } from "@atcute/xrpc-server/auth";
import { cors } from "@atcute/xrpc-server/middlewares/cors";
import { ComAtprotoModerationCreateReport } from "@atcute/atproto";
import { AppBskyFeedGetFeedSkeleton } from "@atcute/bluesky";
import { CompositeDidDocumentResolver, PlcDidDocumentResolver, WebDidDocumentResolver } from "@atcute/identity-resolver";
import { ResourceUri, Did } from "@atcute/lexicons";
import { db, getConfig } from "./db.ts";

const router = new XRPCRouter({ middlewares: [cors()] });

const assert = <T>(v: T | undefined, err: string): T => {
    if (v === undefined) throw new Error(err);
    return v;
}

const config = {
    plc: assert(getConfig("plc"), "config: plc must be provided"),
    mainDid: assert(getConfig("mainDid"), "config: mainDid must be provided"),
    feedDid: assert(getConfig("feedDid"), "config: feedDid must be provided"),
    svcUrl: assert(getConfig("svcUrl"), "config: svcUrl must be provided"),
};

const resolver  = new CompositeDidDocumentResolver({
    methods: {
        plc: new PlcDidDocumentResolver({
            apiUrl: config.plc
        }),
        web: new WebDidDocumentResolver(),
    },
});

const mainJwtVerifier = new ServiceJwtVerifier({ resolver, serviceDid: config.mainDid as Did });
const feedJwtVerifier = new ServiceJwtVerifier({ resolver, serviceDid: config.feedDid as Did });

const verifyServiceAuth = async (request: Request, jwtVerifier: ServiceJwtVerifier, lxm: `${string}.${string}.${string}`): Promise<VerifiedJwt> => {
    const authHeader = request.headers.get("authorization");
    if (!authHeader?.startsWith("Bearer "))
        throw new AuthRequiredError({ description: `missing or invalid authorization header` });

    const result = await jwtVerifier.verify(authHeader.slice(7), { lxm });
    if (!result.ok)
        throw new AuthRequiredError({ description: result.error.description });

    return result.value;
};

const getPosts = db.prepare(`SELECT rt, aturi, ts
        FROM posts
        WHERE feed = ? AND ts < ?
        ORDER BY ts DESC LIMIT ?`);

router.addQuery(AppBskyFeedGetFeedSkeleton, {
    async handler({ request, params }) {
        const auth = await verifyServiceAuth(request, feedJwtVerifier, "app.bsky.feed.getFeedSkeleton");
        const cursor = BigInt(params.cursor || "99999999999999999");
        if (params.limit < 0 || params.limit > 100) params.limit = 100;
        const feed = getPosts.values<[ResourceUri | null, ResourceUri, bigint]>(auth.issuer, cursor, params.limit);
        return json({
            feed: feed.map(([rt, aturi, _]) => ({
                post: aturi,
                reason: rt === null ? undefined : {
                    $type: "app.bsky.feed.defs#skeletonReasonRepost",
                    repost: rt
                }
            })),
            cursor: feed[feed.length-1][2].toString()
        });
    }
});

const getRelation = db.prepare(`
    SELECT posts, replies, replies_to, reposts
    FROM follows
    WHERE follower = ? AND followee = ?`);

const setRelation = db.prepare(`INSERT OR REPLACE INTO follows VALUES (?,?,?,?,?,?)`);

const EMPTY_REL = { posts: 0, replies: 0, replies_to: 0, reposts: 0 };

router.addProcedure(ComAtprotoModerationCreateReport, {
    async handler({ request, input }) {
        const auth = await verifyServiceAuth(request, mainJwtVerifier, "com.atproto.moderation.createReport");
        if (input.subject.$type !== "com.atproto.admin.defs#repoRef")
            throw new InvalidRequestError({ description: "report subject must be an account" })

        let rel = getRelation.all<{posts: number, replies: number, replies_to: number, reposts: number}>(auth.issuer, input.subject.did)[0];
        if (!rel) rel = {...EMPTY_REL};

        (input.reason || "+ +rt").split(" ").forEach(cmd => {
            switch (cmd) {
                case "+": case "+posts": rel.posts = 1; break;
                case "+rt": rel.reposts = 1; break;
                case "+r": rel.replies = 1; break;
                case "+to": rel.replies_to = 1; break;
                case "+all": rel.posts = 1; rel.replies = 1; rel.reposts = 1; break;

                case "-": case "-all": rel = {...EMPTY_REL}; break;
                case "-posts": rel.posts = 0; break;
                case "-rt": rel.reposts = 0; break;
                case "-r": rel.replies = 0; break;
                case "-to": rel.replies_to = 0; break;

                default:
                    throw new InvalidRequestError({ description: "invalid command" });
            }
        });

        setRelation.run(auth.issuer, input.subject.did, rel.posts, rel.replies, rel.replies_to, rel.reposts);

        return json({
            reportedBy: auth.issuer,
            id: 0,
            reasonType: input.reasonType,
            reason: input.reason,
            subject: input.subject,
            createdAt: (new Date()).toISOString()
        });
    }
});

export default {
    async fetch(req, _info): Promise<Response> {
        const pathname = decodeURIComponent(new URL(req.url).pathname);
        switch (pathname) {
            case "/":
                return new Response(`# This is https://github.com/TechnoJo4/priv\n\n`, { headers: { "content-type": "text/plain" } });
            case "/.well-known/atproto-did":
                return new Response(config.mainDid, { headers: { "content-type": "text/plain" } });
            case "/.well-known/did.json":
                return new Response(JSON.stringify({
                    "@context": ["https://www.w3.org/ns/did/v1"],
                    "id": config.feedDid,
                    "service": [
                        {
                            "id": "#bsky_fg",
                            "type": "BskyFeedGenerator",
                            "serviceEndpoint": config.svcUrl
                        }
                    ]
                }), { headers: { "content-type": "application/json" } });
            default:
                return await router.fetch(req);
        }
    }
} satisfies Deno.ServeDefaultExport;
