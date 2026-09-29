# ---------------------------------------------------------
# Stage 1: Base image with core tools & system libraries
# ---------------------------------------------------------
FROM node:20-alpine AS base

RUN apk add --no-cache libc6-compat openssl
WORKDIR /app

# Enable pnpm via Corepack
ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
RUN corepack enable && corepack prepare pnpm@latest --activate

# ---------------------------------------------------------
# Stage 2: Install dependencies
# ---------------------------------------------------------
FROM base AS dependencies

# Python & build tools needed for native module compilation (e.g. bcrypt, sharp)
RUN apk add --no-cache python3 make g++

WORKDIR /app

# Copy dependency definition files
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY apps/backend/package.json ./apps/backend/
COPY apps/frontend/package.json ./apps/frontend/
COPY packages/*/package.json ./packages/*/

# Install all dependencies (including devDependencies for building)
RUN --mount=type=cache,id=pnpm,target=/pnpm/store \
    pnpm install --frozen-lockfile

# ---------------------------------------------------------
# Stage 3: Build application & generate Prisma client
# ---------------------------------------------------------
FROM dependencies AS builder

WORKDIR /app

# Copy full monorepo source
COPY . .

# Generate Prisma client before building
ENV PRISMA_CLI_BINARY_TARGETS="linux-musl-openssl-3.0.x"
RUN pnpm prisma generate || pnpm --filter @postiz/backend prisma generate

# Build frontend, backend, and internal packages
ENV NODE_ENV=production
RUN pnpm build

# Prune devDependencies to keep image size small
RUN pnpm prune --prod --no-optional

# ---------------------------------------------------------
# Stage 4: Production Runner
# ---------------------------------------------------------
FROM node:20-alpine AS runner

RUN apk add --no-cache libc6-compat openssl bash dumb-init
WORKDIR /app

ENV NODE_ENV=production
ENV PORT=5200

# Run container as non-root user
USER node

# Copy node_modules and built assets from builder stage
COPY --chown=node:node --from=builder /app/node_modules ./node_modules
COPY --chown=node:node --from=builder /app/package.json ./package.json
COPY --chown=node:node --from=builder /app/apps ./apps
COPY --chown=node:node --from=builder /app/packages ./packages

EXPOSE 5200 3000

# Use dumb-init to properly handle signal termination (SIGTERM, SIGINT)
ENTRYPOINT ["/usr/bin/dumb-init", "--"]

# Run the backend API service (or custom launch script)
CMD ["node", "apps/backend/dist/main.js"]