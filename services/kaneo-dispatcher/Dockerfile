# Distroless: static binary (CGO_ENABLED=0), so a shell would add attack
# surface and nothing else. :nonroot already runs as uid 65532, matching
# the generated securityContext.
#
# bin/app is built by CI before this runs; `docker build` alone does not
# produce a working image. Run `make build` first.
FROM gcr.io/distroless/static-debian12:nonroot

COPY --chown=65532:65532 bin/app /app/app

USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/app/app"]
