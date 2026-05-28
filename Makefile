IMAGE   ?= ghcr.io/0xkernel/romestead-docker
TAG     ?= dev
PLATFORM ?= linux/amd64

.PHONY: help build run install update backup shell logs ps lint clean

help:
	@echo "Romestead dedicated server — task runner"
	@echo ""
	@echo "  make build              build local image  ($(IMAGE):$(TAG))"
	@echo "  make install            run one-shot DepotDownloader inside the container"
	@echo "  make update             update existing install in-place"
	@echo "  make run                start the server in the foreground"
	@echo "  make backup             create a save-dir tarball"
	@echo "  make shell              open a bash shell inside the running server"
	@echo "  make logs               tail server logs"
	@echo "  make ps                 list running services"
	@echo "  make lint               shellcheck + hadolint + yamllint locally"
	@echo "  make clean              remove local containers (keeps the volume)"

build:
	docker buildx build --platform $(PLATFORM) -f docker/Dockerfile -t $(IMAGE):$(TAG) --load .

install:
	docker compose -f compose/docker-compose.yml --profile maintenance run --rm install

update:
	docker compose -f compose/docker-compose.yml --profile maintenance run --rm update

run:
	docker compose -f compose/docker-compose.yml up -d server

backup:
	docker compose -f compose/docker-compose.yml --profile maintenance run --rm backup

shell:
	docker compose -f compose/docker-compose.yml exec server bash

logs:
	docker compose -f compose/docker-compose.yml logs -f --tail=200 server

ps:
	docker compose -f compose/docker-compose.yml ps

lint:
	shellcheck scripts/rs scripts/lib/*.sh
	hadolint docker/Dockerfile
	yamllint -d "{extends: default, rules: {line-length: disable, document-start: disable, truthy: {check-keys: false}}}" compose/ k8s/ .github/

clean:
	docker compose -f compose/docker-compose.yml down
