FROM denoland/deno:2.6.3
WORKDIR /app
COPY --chown=deno:deno . .
RUN deno install
