// Force deno to download libsqlite by opening an in-memory database
// Use e.g. during docker build so that it's not re-downloaded by every serve worker
import { Database } from "@db/sqlite";
new Database(":memory:");
