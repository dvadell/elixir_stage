ARG NODE_VERSION=22.20.0

FROM node:${NODE_VERSION}-slim AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci

FROM node:${NODE_VERSION}-slim
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY src ./src
ENV NODE_ENV=production
USER node
EXPOSE 8080
CMD ["node", "src/server.mjs"]