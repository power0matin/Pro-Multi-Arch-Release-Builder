FROM golang:1.22-bookworm

RUN apt-get update && apt-get install -y --no-install-recommends \
      zip ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /work
COPY . .

# Example:
# docker build -t pro-release .
# docker run --rm -v "$PWD:/work" pro-release bash -lc './build.sh input/project.zip'
