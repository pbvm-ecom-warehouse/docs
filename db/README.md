# DB Guide — Giải thích sâu cơ sở dữ liệu WMS-ECOM

> Bộ tài liệu **đào sâu** 45 bảng / 29 enum của hệ WMS-ECOM: giải thích **tại sao** thiết kế như vậy, kèm ví dụ số liệu từng bước. Khác với `*/data-model.md` (chỉ **định nghĩa schema**) và [erd.dbml](../overview/erd.dbml) (sơ đồ trực quan) — bộ này dạy **cách hiểu & cách kể**.

## Đọc theo thứ tự nào?

Đừng đọc theo bảng — đọc theo **dòng chảy nghiệp vụ**. Bắt đầu từ [khái niệm lõi](00-khai-niem-loi.md), rồi đi theo hàng đi vào → tồn → bán → xuất → giao.

| # | Bài | Bảng được giải thích |
|---|---|---|
| 00 | [5 khái niệm lõi](00-khai-niem-loi.md) | (xương sống mọi bảng bám theo) |
| 01 | [Kho & vị trí](01-kho-va-vi-tri.md) | warehouses, zones, racks, shelves |
| 02 | [Hàng hóa & tồn kho 2 lớp](02-hang-hoa-va-ton-kho.md) | warehouse_items, stock_balances, inventory_stocks, lots, stock_movements |
| 03 | [Nhập kho](03-nhap-kho.md) | purchase_orders, goods_receive_notes, putaway_tasks (+items) |
| 04 | [In ly (make-to-order)](04-in-ly.md) | print_jobs, print_job_items |
| 05 | [Xuất kho & nội bộ](05-xuat-kho-va-noi-bo.md) | goods_issues, stock_counts, stock_transfers, scrap_notes, goods_returns (+items) |
| 06 | [Supplier](06-supplier.md) | suppliers, supplier_items |
| 07 | [Shipping](07-shipping.md) | carriers, shipments |
| 08 | [Auth-WMS](08-auth-wms.md) | users, user_refresh_tokens |
| 09 | [Catalog (Ecommerce)](09-catalog.md) | categories, products, product_variants, designs |
| 10 | [Order (Ecommerce)](10-order.md) | carts, orders, payment_transactions (+items) |
| 11 | [Auth-Ecom](11-auth-ecom.md) | customers, customer_refresh_tokens, customer_auth_tokens |
| 12 | [Luồng end-to-end](12-luong-end-to-end.md) | (ráp 45 bảng vào 1 vòng đời đơn hàng) |
| 13 | [Tổng quan hệ thống](13-tong-quan-he-thong.md) | Bản phân tích và tóm tắt toàn diện hệ thống |

## Bản đồ nhanh — 2 DB, 7 module, 45 bảng

```
wms_db (WMS — nội bộ)                    ecom_db (Ecommerce — public)
├── warehouse  (27 bảng)                 ├── catalog   (4 bảng)
│   kho/vị trí · item · tồn 2 lớp ·      │   categories · products ·
│   nhập · in · xuất · kiểm · chuyển ·   │   product_variants · designs
│   hủy · hoàn                           ├── order     (5 bảng)
├── supplier   (2 bảng)                  │   carts · orders ·
├── shipping   (2 bảng)                  │   payment_transactions (+items)
└── auth-wms   (2 bảng)                  └── auth-ecom (3 bảng)
        users · token                        customers · 2 token
                    ▲
        Nối nhau DUY NHẤT qua `sku` + event (BullMQ+Redis) — KHÔNG đọc chéo DB
```

## Liên quan

- Schema gốc (nguồn chuẩn): các `*/data-model.md` từng module.
- Sơ đồ: [erd.dbml](../overview/erd.dbml) (dbdiagram.io) · [erd.md](../overview/erd.md) (Mermaid đầy đủ) · [erd-concept.md](../overview/erd-concept.md) (concept 1 slide).
- Phân chia sở hữu & sync: [data-ownership.md](../overview/data-ownership.md).
- Luồng end-to-end nghiệp vụ: [main-flow.md](../overview/main-flow.md).
