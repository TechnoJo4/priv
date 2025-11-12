FROM fossa/haskell-static-alpine:ghc-9.8.2 AS build
COPY . .
RUN cabal update
RUN cabal build --enable-executable-static
RUN cp $(cabal -v0 list-bin exe:priv) /priv

FROM alpine:3
WORKDIR /app
COPY --from=build /priv priv
ENTRYPOINT ["/app/priv"]
