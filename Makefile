SNELL_VERSION ?= 6.0.0
IMAGE         ?= snell-server
PLATFORMS     ?= linux/amd64,linux/arm64,linux/386

.PHONY: build buildx-push up down logs psk

# 只构建本机架构，供 docker compose 使用
build:
	docker compose build

# 多架构构建并推送到镜像仓库（IMAGE 需含仓库前缀，如 ghcr.io/you/snell-server）
buildx-push:
	docker buildx build --platform $(PLATFORMS) \
	  --build-arg SNELL_VERSION=$(SNELL_VERSION) \
	  -t $(IMAGE):$(SNELL_VERSION) -t $(IMAGE):latest --push .

up:
	docker compose up -d

down:
	docker compose down

logs:
	docker compose logs -f snell

# 查看当前生效的 PSK（只在本机终端显示）
psk:
	@grep -E '^[[:space:]]*psk' config/snell-server.conf
