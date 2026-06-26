# CI/CD GitHub Actions — WMS-ECOM Backend

**Ngày:** 2026-06-26
**Scope:** Pipeline tự động build Docker image và deploy lên VPS DigitalOcean khi push vào branch `develop`.

---

## Tổng quan

```
push to develop
      │
      ▼
[GitHub Actions]
  1. Build Docker image (Dockerfile hiện có)
  2. Push lên ghcr.io/pbvm-ecom-warehouse/be-wms-ecom
      - tag :latest
      - tag :<git-sha>
      │
      ▼
  3. SSH vào VPS
  4. scp docker-compose.prod.yml lên VPS
  5. docker compose pull
  6. docker compose up -d --remove-orphans
```

---

## Registry

- **ghcr.io** (GitHub Container Registry)
- Image: `ghcr.io/pbvm-ecom-warehouse/be-wms-ecom`
- Tags: `:latest` (deploy) + `:<sha7>` (rollback)
- Auth: dùng `GITHUB_TOKEN` tự động — không cần PAT riêng cho bước push từ Action.
- VPS cần login ghcr.io 1 lần thủ công để pull (xem mục Chuẩn bị VPS).

---

## Workflow file

**Path:** `.github/workflows/deploy.yml`

### Job 1 — `build-and-push`

| Bước | Action / Lệnh |
|---|---|
| Checkout | `actions/checkout@v4` |
| Setup QEMU (multi-arch nếu cần) | `docker/setup-qemu-action@v3` |
| Setup Buildx | `docker/setup-buildx-action@v3` |
| Login ghcr.io | `docker/login-action@v3` với `registry: ghcr.io`, `username: ${{ github.actor }}`, `password: ${{ secrets.GITHUB_TOKEN }}` |
| Build & Push | `docker/build-push-action@v5` — push 2 tag `:latest` và `:<sha>` (7 ký tự) |

### Job 2 — `deploy`

Chạy sau `build-and-push` (needs).

| Bước | Lệnh |
|---|---|
| SSH setup | `webfactory/ssh-agent@v0` nạp `SSH_PRIVATE_KEY` |
| SCP compose file | `scp docker-compose.prod.yml $SSH_USER@$SSH_HOST:/home/deploy/wms-ecom/` |
| Pull & restart | SSH vào VPS, chạy `docker compose pull && docker compose up -d --remove-orphans` |

---

## GitHub Secrets cần khai báo

Vào **Settings → Secrets and variables → Actions** của repo, thêm:

| Secret | Giá trị |
|---|---|
| `SSH_HOST` | IP public của VPS DigitalOcean |
| `SSH_USER` | `deploy` |
| `SSH_PRIVATE_KEY` | Nội dung private key để SSH vào VPS (Ed25519 hoặc RSA) |
| `SSH_PORT` | `22` (hoặc port custom nếu đã đổi) |

> `GITHUB_TOKEN` có sẵn tự động — không cần thêm.

---

## Thay đổi `docker-compose.prod.yml`

Hiện tại service `wms` có `build: .` → build tại chỗ trên VPS. Cần đổi sang pull từ registry.

**Trước:**
```yaml
wms:
  build: .
  image: wms-ecom-be:latest
```

**Sau:**
```yaml
wms:
  image: ghcr.io/pbvm-ecom-warehouse/be-wms-ecom:latest
```

Tương tự `ecommerce` và `notification` — chỉ đổi tên image (không có `build:`, chỉ cần đổi giá trị `image:`).

---

## Chuẩn bị VPS (thực hiện 1 lần)

1. **Tạo PAT trên GitHub** (Settings → Developer settings → Personal access tokens → Fine-grained):
   - Permission: `read:packages`
   - Scope: repo `pbvm-ecom-warehouse/be-wms-ecom`

2. **Login ghcr.io trên VPS:**
   ```bash
   echo "<PAT>" | docker login ghcr.io -u <github-username> --password-stdin
   ```

3. **Đảm bảo user `deploy` trong group `docker`:**
   ```bash
   sudo usermod -aG docker deploy
   ```

4. **Tạo thư mục làm việc:**
   ```bash
   mkdir -p /home/deploy/wms-ecom
   ```

5. **Copy `.env.production` lên VPS** (không commit vào git):
   ```bash
   scp .env.production deploy@<VPS_IP>:/home/deploy/wms-ecom/.env.production
   ```
   File này không được Action động vào — quản lý thủ công, chỉ update khi thêm biến mới.

---

## Rollback

Khi cần rollback về commit trước:

```bash
# Trên VPS
docker compose stop
# Sửa image tag trong docker-compose.prod.yml từ :latest sang :<sha-cũ>
docker compose up -d
```

Hoặc đơn giản hơn: revert commit trên `develop` → Action tự deploy lại.

---

## Giới hạn & lưu ý

- **Downtime nhỏ** trong khi `docker compose up -d` restart container. Chấp nhận được với scale hiện tại (không cần blue-green).
- **`.env.production` không được commit** vào git và không được Action scp lên — quản lý hoàn toàn thủ công trên VPS.
- **`docker-compose.prod.yml` được scp lên mỗi lần deploy** để VPS luôn sync với git.
- Redis data được persist qua volume `redis-data` — không mất khi restart container.
- `proxy-network` phải tồn tại trên VPS trước khi chạy compose (Nginx Proxy Manager tạo network này).
