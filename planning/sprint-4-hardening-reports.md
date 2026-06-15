# Sprint 4 — Hoàn thiện & Báo cáo (Week 4)

**Mục tiêu:** Bịt nốt 2 nghiệp vụ ngoại lệ (scrap, return), dựng báo cáo tồn read-only, gắn consumer notification thật, rồi seed + E2E + bug bash để demo.

**Định nghĩa Done sprint:** chạy được kịch bản E2E happy-path WMS từ seed; báo cáo tồn theo SKU/kho/lô trả số khớp `stock_movements`; notification nhận `stock.low`/`stock.near_expiry`; docs Report viết xong.

## Issues

- [ ] [S4-01](issues/S4-01-scrap.md) — UC-08 Scrap (hủy hết hạn/hỏng) · `feat/M`
- [ ] [S4-02](issues/S4-02-return-rma.md) — UC-09 Return / RMA · `feat/M`
- [ ] [S4-03](issues/S4-03-report-module.md) — Module Report (tồn theo SKU/kho/lô, hiệu suất) · `feat/L`
- [ ] [S4-04](issues/S4-04-notification-consumer.md) — Notification consumer (`stock.low`, `stock.near_expiry`) · `feat/M` *(dep S1-05)*
- [ ] [S4-05](issues/S4-05-seed-e2e-demo.md) — Seed data + E2E happy-path + bug bash + demo · `test/L`
- [ ] [S4-06](issues/S4-06-docs-report.md) — *(docs)* Viết module Report · `docs/M`

## Lưu ý điều phối

S4-05 là việc cuối, gom cả đội. S4-01/S4-02/S4-03/S4-04 song song. Nếu tiến độ trượt, ưu tiên giữ S4-03 (báo cáo) + S4-05 (E2E/demo); S4-01/S4-02 có thể cắt sang phase sau.
