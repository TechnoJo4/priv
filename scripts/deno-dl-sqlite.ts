// Force deno to download libsqlite (e.g. during docker build so that it's not re-downloaded by ) by opening an in-memory database
import { Database } from "@db/sqlite";
new Database(":memory:");
