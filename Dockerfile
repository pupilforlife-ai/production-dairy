
FROM node:22-alpine AS build
WORKDIR /app

COPY package*.json ./
RUN npm config set fetch-retry-maxtimeout 120000 && npm ci

COPY . .
RUN npm run build -- --configuration=production

FROM nginx:alpine

COPY --from=build /app/dist/production-dairy /usr/share/nginx/html

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
