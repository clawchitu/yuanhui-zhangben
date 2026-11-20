# 服务器镜像。构建上下文是仓库根目录（要带上 contracts/，S03 的 guard 读 permissions.json）：
#   docker build -f server/Dockerfile -t yuanhui-api .
# 大陆拉不动 Docker Hub：发布时用 --build-arg NODE_IMAGE=<ACR 里镜像过去的 node:24>（§1、S10a）。
# Node 24 直接跑 .ts（类型擦除），不需要编译步骤。
ARG NODE_IMAGE=node:24-bookworm-slim

FROM ${NODE_IMAGE} AS deps
WORKDIR /app/server
COPY server/package.json server/package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force

FROM ${NODE_IMAGE}
ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=3000
WORKDIR /app
COPY contracts/ ./contracts/
COPY --from=deps /app/server/node_modules ./server/node_modules
COPY server/package.json ./server/
COPY server/src ./server/src
COPY server/migrations ./server/migrations
COPY server/scripts ./server/scripts
WORKDIR /app/server
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/healthz').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"
# 迁移由 deploy.sh 先单独跑：docker compose run --rm api node scripts/migrate.ts
CMD ["node", "src/server.ts"]
