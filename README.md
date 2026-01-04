# priv

Private follows for Bluesky.

## Usage

Subscribe to [the "labeler"](https://bsky.app/profile/did:plc:hrxxvz6q4u67z4puuyek4qpt) so that you can send reports to it, and pin [the feed](https://bsky.app/profile/priv.merkletr.ee/feed/3m5h4ao75nd2k).

Report a user with the "Other" reason type, and enter a combination of these commands:
- `+` or `+posts`: follow a user's posts
- `+rt`: follow someone's reposts
- `+r`: follow someone's replies
- `-` or `-all`: completely unfollow someone
- `-posts`: unfollow someone's posts
- `-rt`: unfollow someone's reposts
- `-r`: unfollow someone's replies

Join multiple commands together with spaces.

The default command if you enter none is `+ +rt` (following someone and their retweets).

## Deploying

1. Choose a domain for your feed generator, e.g. `priv.merkletr.ee`.

   **Config** `feedDid`: `did:web:priv.merkletr.ee`, `svcUrl`: `https://priv.merkletr.ee`

1. Create a main DID for the "labeler" and Bluesky account. You can do this through your PDS.

   **Config** `mainDid`: `did:plc:hrxxvz6q4u67z4puuyek4qpt`

1. Add the `atproto_labeler` service to your main DID. You can do this through `goat plc` or `goat account plc`.

   ```json
   {
     "did": "did:plc:hrxxvz6q4u67z4puuyek4qpt",
     // ...
     "services": {
       "atproto_pds": {
         // ...
       },
       "atproto_labeler": {
         "type": "AtprotoLabeler",
         "endpoint": "https://priv.merkletr.ee"
       }
     }
   }
   ```

1. Initialize the database: `cat schema.sql | sqlite3 path/to/priv.db`

1. Start your instance!

1. Create the `app.bsky.labeler.service` labeler definition record, e.g.:

   ```json
   {
     "$type": "app.bsky.labeler.service",
     "policies": {
       "labelValues": []
     },
     "reasonTypes": [
       "com.atproto.moderation.defs#reasonOther",
       "tools.ozone.report.defs#reasonOther"
     ],
     "createdAt": "2025-11-11T00:00:00.000Z"
   }
   ```

1. Create the `app.bsky.feed.generator` feed generator definition record, e.g.:

   ```json
   {
     "$type": "app.bsky.feed.generator",
     "did": "did:web:priv.merkletr.ee",
     "createdAt": "2025-11-11T00:00:00.000Z",
     "description": "https://github.com/TechnoJo4/priv",
     "displayName": "Private follows"
   }
   ```
