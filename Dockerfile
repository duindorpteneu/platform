# syntax=docker/dockerfile:1.7
FROM node:22-bookworm-slim@sha256:d649c27dae7ba0137b3cef5dd75baa422c08dc3d9e3fc0c23dfb172dc3cc6436 AS base
ENV PNPM_HOME=/pnpm \
    PATH=/pnpm:$PATH \
    NEXT_TELEMETRY_DISABLED=1
RUN corepack enable && corepack prepare pnpm@11.5.2 --activate

FROM base AS dependencies
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN pnpm install --frozen-lockfile

FROM dependencies AS builder
COPY . .
RUN pnpm build

FROM gcr.io/distroless/nodejs22-debian13:nonroot@sha256:939d6f1671529d230f50b563578e9b5d206af58f038b10ebd7e1233023d4e167 AS runtime
ENV NODE_ENV=production \
    HOSTNAME=0.0.0.0 \
    PORT=3000 \
    NEXT_TELEMETRY_DISABLED=1 \
    PATH=/nodejs/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WORKDIR /app
COPY --from=builder --chown=65532:65532 /app/.next/standalone ./
# Next.js output tracing does not follow sharp's optional pnpm libvips symlink.
# Copy the pinned native runtime explicitly so image optimization remains usable.
COPY --from=builder --chown=65532:65532 /app/node_modules/.pnpm/@img+sharp-libvips-linux-x64@1.3.0 ./node_modules/.pnpm/@img+sharp-libvips-linux-x64@1.3.0
COPY --from=builder --chown=65532:65532 /app/node_modules/.pnpm/sharp@0.35.0/node_modules/@img/sharp-libvips-linux-x64 ./node_modules/.pnpm/sharp@0.35.0/node_modules/@img/sharp-libvips-linux-x64
COPY --from=builder --chown=65532:65532 /app/node_modules/.pnpm/@img+sharp-linux-x64@0.35.0/node_modules/@img/sharp-libvips-linux-x64 ./node_modules/.pnpm/@img+sharp-linux-x64@0.35.0/node_modules/@img/sharp-libvips-linux-x64
COPY --from=builder --chown=65532:65532 /app/.next/static ./.next/static
COPY --from=builder --chown=65532:65532 /app/public ./public
COPY --from=builder --chown=65532:65532 /app/scripts/operations/scheduler.mjs ./operations-scheduler.mjs
USER 65532:65532
EXPOSE 3000
ENTRYPOINT ["/nodejs/bin/node"]
CMD ["server.js"]
