# CI/CD GitHub Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Thiết lập pipeline CI/CD tự động build Docker image, push lên ghcr.io, và deploy lên VPS DigitalOcean khi push vào branch `develop`.

**Architecture:** GitHub Actions chạy 2 job tuần tự: `build-and-push` build 1 Docker image dùng chung cho 3 app (wms/ecommerce/notification), push lên `ghcr.io/pbvm-ecom-warehouse/be-wms-ecom` với 2 tag (`:latest` + `:<sha7>`). Job `deploy` SSH vào VPS, scp `docker-compose.prod.yml` lên, rồi `docker compose pull && up -d`.

**Tech Stack:** GitHub Actions, Docker Buildx, ghcr.io, docker compose v2, SSH (webfactory/ssh-agent).

## Global Constraints

- Image registry: `ghcr.io/pbvm-ecom-warehouse/be-wms-ecom`
- Trigger branch: `develop`
- VPS working dir: `/home/deploy/wms-ecom/`
- `docker-compose.prod.yml` được scp lên VPS mỗi lần deploy — VPS luôn sync với git
- `.env.production` KHÔNG được Action động vào — quản lý thủ công trên VPS
- Compose chạy với `--env-file .env.production` trên VPS

---

## File Structure

| File | Trạng thái | Vai trò |
|---|---|---|
| `.github/workflows/deploy.yml` | Tạo mới | Toàn bộ pipeline CI/CD |
| `be/docker-compose.prod.yml` | Sửa | Đổi image từ local sang ghcr.io |

---

## Task 1: Sửa `docker-compose.prod.yml` — dùng image từ ghcr.io

**Files:**
- Modify: `be/docker-compose.prod.yml`

**Interfaces:**
- Produces: `docker-compose.prod.yml` dùng `image: ghcr.io/pbvm-ecom-warehouse/be-wms-ecom:latest` cho cả 3 service app; bỏ `build: .` khỏi service `wms`

---

- [ ] **Bước 1: Sửa service `wms` — bỏ `build:`, đổi `image:`**

Mở `be/docker-compose.prod.yml`. Service `wms` hiện có:
```yaml
wms:
  build: .
  image: wms-ecom-be:latest # build 1 lần, 3 container tái dùng
```

Sửa thành:
```yaml
wms:
  image: ghcr.io/pbvm-ecom-warehouse/be-wms-ecom:latest
```

- [ ] **Bước 2: Sửa service `ecommerce` — đổi `image:`**

```yaml
# Trước
ecommerce:
  image: wms-ecom-be:latest

# Sau
ecommerce:
  image: ghcr.io/pbvm-ecom-warehouse/be-wms-ecom:latest
```

- [ ] **Bước 3: Sửa service `notification` — đổi `image:`**

```yaml
# Trước
notification:
  image: wms-ecom-be:latest

# Sau
notification:
  image: ghcr.io/pbvm-ecom-warehouse/be-wms-ecom:latest
```

- [ ] **Bước 4: Kiểm tra file kết quả**

Chạy lệnh sau để xác nhận không còn `wms-ecom-be:latest` hay `build: .`:
```bash
grep -n "wms-ecom-be\|build:" be/docker-compose.prod.yml
```
Expected: không có output (0 matches).

- [ ] **Bước 5: Sửa comment header trong file**

Dòng 9 hiện có `docker compose --env-file .env.production -f docker-compose.prod.yml up -d --build`. Bỏ `--build` vì không build tại chỗ nữa:

```yaml
#   docker compose --env-file .env.production -f docker-compose.prod.yml up -d
```

- [ ] **Bước 6: Commit**

```bash
git add be/docker-compose.prod.yml
git commit -m "chore(docker): dùng image ghcr.io thay vì build tại chỗ trên VPS"
```

---

## Task 2: Tạo GitHub Actions workflow

**Files:**
- Tạo mới: `be/.github/workflows/deploy.yml`

**Interfaces:**
- Consumes: `docker-compose.prod.yml` đã sửa ở Task 1
- Consumes: GitHub Secrets `SSH_HOST`, `SSH_USER`, `SSH_PRIVATE_KEY`, `SSH_PORT`
- Produces: workflow chạy khi push vào `develop`, build + push image, deploy lên VPS

---

- [ ] **Bước 1: Tạo thư mục**

```bash
mkdir -p be/.github/workflows
```

- [ ] **Bước 2: Tạo file `deploy.yml`**

Tạo file `be/.github/workflows/deploy.yml` với nội dung sau:

```yaml
name: Build & Deploy

on:
  push:
    branches: [develop]

jobs:
  build-and-push:
    name: Build image & push ghcr.io
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Login ghcr.io
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build & Push
        uses: docker/build-push-action@v5
        with:
          context: .
          push: true
          tags: |
            ghcr.io/pbvm-ecom-warehouse/be-wms-ecom:latest
            ghcr.io/pbvm-ecom-warehouse/be-wms-ecom:${{ github.sha }}
          cache-from: type=gha
          cache-to: type=gha,mode=max

  deploy:
    name: Deploy lên VPS
    runs-on: ubuntu-latest
    needs: build-and-push

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Setup SSH agent
        uses: webfactory/ssh-agent@v0.9.0
        with:
          ssh-private-key: ${{ secrets.SSH_PRIVATE_KEY }}

      - name: Add VPS to known_hosts
        run: |
          ssh-keyscan -p ${{ secrets.SSH_PORT }} -H ${{ secrets.SSH_HOST }} >> ~/.ssh/known_hosts

      - name: SCP docker-compose.prod.yml lên VPS
        run: |
          scp -P ${{ secrets.SSH_PORT }} \
            docker-compose.prod.yml \
            ${{ secrets.SSH_USER }}@${{ secrets.SSH_HOST }}:/home/deploy/wms-ecom/docker-compose.prod.yml

      - name: Pull image mới & restart containers
        run: |
          ssh -p ${{ secrets.SSH_PORT }} ${{ secrets.SSH_USER }}@${{ secrets.SSH_HOST }} \
            "cd /home/deploy/wms-ecom && \
             docker compose --env-file .env.production -f docker-compose.prod.yml pull && \
             docker compose --env-file .env.production -f docker-compose.prod.yml up -d --remove-orphans"
```

- [ ] **Bước 3: Kiểm tra YAML hợp lệ**

```bash
python3 -c "import yaml, sys; yaml.safe_load(open('be/.github/workflows/deploy.yml'))" && echo "YAML OK"
```
Expected: `YAML OK`

- [ ] **Bước 4: Commit**

```bash
git add be/.github/workflows/deploy.yml
git commit -m "ci: thêm GitHub Actions pipeline build + deploy lên VPS"
```

---

## Task 3: Chuẩn bị VPS (thực hiện thủ công 1 lần)

Đây là các bước chạy **trực tiếp trên VPS** qua SSH — không phải trong repo. Không có file nào được tạo/sửa trong codebase.

- [ ] **Bước 1: SSH vào VPS**

```bash
ssh deploy@<VPS_IP>
```

- [ ] **Bước 2: Kiểm tra user `deploy` trong group `docker`**

```bash
groups deploy
```
Nếu không thấy `docker` trong output:
```bash
sudo usermod -aG docker deploy
# Sau đó logout và login lại để group có hiệu lực
```

- [ ] **Bước 3: Tạo thư mục làm việc**

```bash
mkdir -p /home/deploy/wms-ecom
```

- [ ] **Bước 4: Tạo PAT trên GitHub để pull image**

Vào GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token:
- **Repository access:** chỉ repo `pbvm-ecom-warehouse/be-wms-ecom`
- **Permissions:** `Read` cho `Packages`
- Lưu token lại (chỉ hiển thị 1 lần)

- [ ] **Bước 5: Login ghcr.io trên VPS**

```bash
echo "<PAT_VỪA_TẠO>" | docker login ghcr.io -u <github-username> --password-stdin
```
Expected: `Login Succeeded`

- [ ] **Bước 6: Copy `.env.production` lên VPS**

Chạy từ **máy local** (không phải VPS):
```bash
scp be/.env.production deploy@<VPS_IP>:/home/deploy/wms-ecom/.env.production
```

- [ ] **Bước 7: Xác nhận `proxy-network` tồn tại**

```bash
docker network ls | grep proxy-network
```
Nếu chưa có (Nginx Proxy Manager chưa tạo), chạy Nginx Proxy Manager trước, hoặc tạo thủ công:
```bash
docker network create proxy-network
```

---

## Task 4: Khai báo GitHub Secrets

Thực hiện trên **GitHub web** — không có file nào thay đổi trong repo.

- [ ] **Bước 1: Mở trang Secrets**

Vào repo `pbvm-ecom-warehouse/be-wms-ecom` → Settings → Secrets and variables → Actions → New repository secret.

- [ ] **Bước 2: Thêm `SSH_HOST`**

- Name: `SSH_HOST`
- Secret: IP public của VPS DigitalOcean (ví dụ `165.22.xxx.xxx`)

- [ ] **Bước 3: Thêm `SSH_USER`**

- Name: `SSH_USER`
- Secret: `deploy`

- [ ] **Bước 4: Thêm `SSH_PRIVATE_KEY`**

Trên máy local, tạo SSH key pair dành riêng cho CI (không dùng key cá nhân):
```bash
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/id_deploy_ci -N ""
```

Copy public key lên VPS:
```bash
ssh-copy-id -i ~/.ssh/id_deploy_ci.pub deploy@<VPS_IP>
```

Nội dung secret là **private key**:
```bash
cat ~/.ssh/id_deploy_ci
```
Copy toàn bộ output (bao gồm `-----BEGIN OPENSSH PRIVATE KEY-----` và `-----END OPENSSH PRIVATE KEY-----`) dán vào secret `SSH_PRIVATE_KEY`.

- [ ] **Bước 5: Thêm `SSH_PORT`**

- Name: `SSH_PORT`
- Secret: `22` (hoặc port SSH custom nếu VPS đã đổi)

---

## Task 5: Chạy pipeline lần đầu & xác nhận

- [ ] **Bước 1: Push lên `develop` để trigger**

```bash
git push origin develop
```

- [ ] **Bước 2: Theo dõi job `build-and-push`**

Vào GitHub → Actions → workflow run mới nhất. Job `build-and-push` phải pass. Build lần đầu ~3-5 phút (chưa có cache). Các lần sau ~1-2 phút nhờ GHA cache.

- [ ] **Bước 3: Xác nhận image có trên ghcr.io**

Vào `https://github.com/orgs/pbvm-ecom-warehouse/packages` hoặc tab Packages của repo. Phải thấy package `be-wms-ecom` với tag `:latest` và `:<sha>`.

- [ ] **Bước 4: Theo dõi job `deploy`**

Job `deploy` chạy sau `build-and-push`. Kiểm tra log từng step. Nếu SSH fail → kiểm tra lại secret `SSH_PRIVATE_KEY` và `SSH_HOST`.

- [ ] **Bước 5: Xác nhận containers chạy trên VPS**

SSH vào VPS:
```bash
docker ps
```
Expected: thấy 4 container đang Up — `wms`, `ecommerce`, `notification`, `wms-ecom-redis`.

- [ ] **Bước 6: Smoke test**

Từ máy local (hoặc qua nginx đã có):
```bash
curl http://<VPS_IP>:3001/api/wms/health  # nếu có health endpoint
# hoặc kiểm tra qua nginx domain đã cấu hình
```

Nếu chưa có health endpoint, chỉ cần xác nhận `docker ps` không có container ở trạng thái `Restarting`.

---

## Rollback (tham khảo, không phải task)

Khi cần rollback nhanh — chạy trên VPS:

```bash
cd /home/deploy/wms-ecom
# Thay :latest bằng <sha> của commit cũ trong docker-compose.prod.yml
sed -i 's|:latest|:<SHA_CŨ>|g' docker-compose.prod.yml
docker compose --env-file .env.production -f docker-compose.prod.yml up -d
```

Hoặc đơn giản hơn: `git revert` commit trên `develop` → push → Action tự deploy lại bản cũ.
