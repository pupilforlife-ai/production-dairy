
FROM node:22-alpine AS build
WORKDIR /app

ARG BUILD_CONFIGURATION=production

COPY package*.json ./
RUN npm config set fetch-retry-maxtimeout 120000 && npm ci

COPY . .
RUN npm run build -- --configuration=${BUILD_CONFIGURATION}

FROM nginx:alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist/production-dairy/browser /usr/share/nginx/html

EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
