FROM denoland/deno:2.6.3
WORKDIR /app
COPY --chown=deno:deno deno.json deno.lock .
RUN deno install
COPY --chown=deno:deno scripts scripts
RUN deno run -A scripts/deno-dl-sqlite.ts
COPY --chown=deno:deno . .
