INPUT ?= input/project.zip
NUM_JOBS ?= $(shell getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)

.PHONY: build clean docker-build docker-run
build:
	NUM_JOBS=$(NUM_JOBS) ./build.sh $(INPUT)

clean:
	rm -rf */Assets */RELEASE.md */release.manifest.json */src \
	       */*-source.zip */*-source.tar.gz

docker-build:
	docker build -t pro-release .

docker-run:
	docker run --rm -v "$$(pwd):/work" pro-release bash -lc './build.sh $(INPUT)'
