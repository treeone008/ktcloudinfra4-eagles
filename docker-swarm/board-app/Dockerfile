FROM node:20-alpine

# wget 설치 (healthcheck용)
RUN apk add --no-cache wget

WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY server.js db.js ./
COPY public ./public

RUN chown -R node:node /app

USER node
EXPOSE 3000

CMD ["node", "server.js"]