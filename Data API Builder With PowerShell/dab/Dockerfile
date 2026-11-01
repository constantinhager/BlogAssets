# Data API builder with the configuration baked in.
# No connection string, no key in the image: everything environment-specific comes
# from environment variables (DAB_CONNECTION_STRING, DAB_JWT_AUDIENCE, DAB_JWT_ISSUER).
ARG DAB_VERSION=2.1.5
FROM mcr.microsoft.com/azure-databases/data-api-builder:${DAB_VERSION}

COPY dab-config.json /App/dab-config.json
