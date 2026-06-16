# WMS-ECOM — Tài liệu Phân tích Nghiệp vụ

## Tổng quan kiến trúc

| Tài liệu                                         | Nội dung                                          |
| ------------------------------------------------ | ------------------------------------------------- |
| [System Context](./overview/system-context.md)   | Kiến trúc tổng thể, Nginx, BullMQ, Infrastructure |
| [Frontend Architecture](./overview/frontend-architecture.md) | 2 FE app (WMS FE nội bộ + Ecom FE public), route layout, phân quyền menu theo role |
| [NestJS Monorepo](./overview/nestjs-monorepo.md) | Monorepo mode, Auth tách biệt WMS vs Ecommerce    |
| [Data Ownership](./overview/data-ownership.md)   | Phân chia collection, sync tồn kho qua event, Quy ước Audit |
| [Main Flow](./overview/main-flow.md)             | Luồng nghiệp vụ end-to-end toàn hệ thống (P0→P7)   |
| [DB Guide](./db/)                                | **Giải thích sâu 45 bảng** (tại sao + ví dụ) — đọc theo dòng nghiệp vụ |
| [ERD](./overview/erd.dbml)                       | Sơ đồ ER: [erd.dbml](./overview/erd.dbml) (dbdiagram.io) · [erd.md](./overview/erd.md) (Mermaid) · [concept](./overview/erd-concept.md) |

## Danh mục module

| Module                            | Use Cases                      | Data Model                              | Workflow                            |
| --------------------------------- | ------------------------------ | --------------------------------------- | ----------------------------------- |
| [Kho hàng (WMS)](./warehouse/)    | [UC](./warehouse/use-cases.md) | [Data Model](./warehouse/data-model.md) | [Workflow](./warehouse/workflow.md) |
| [Auth-WMS (Nhân viên)](./auth-wms/) | [UC](./auth-wms/use-cases.md)  | [Data Model](./auth-wms/data-model.md)  | [Workflow](./auth-wms/workflow.md)  |
| [Auth-Ecom (Khách hàng)](./auth-ecom/) | [UC](./auth-ecom/use-cases.md) | [Data Model](./auth-ecom/data-model.md) | [Workflow](./auth-ecom/workflow.md) |
| [Catalog (Ecommerce)](./catalog/) | [UC](./catalog/use-cases.md) | [Data Model](./catalog/data-model.md) | [Workflow](./catalog/workflow.md) |
| [Đơn hàng & E-commerce](./order/) | [UC](./order/use-cases.md)     | [Data Model](./order/data-model.md)     | [Workflow](./order/workflow.md)     |
| [Nhà cung cấp](./supplier/)       | [UC](./supplier/use-cases.md)  | [Data Model](./supplier/data-model.md)  | [Workflow](./supplier/workflow.md)  |
| [Vận chuyển](./shipping/)         | [UC](./shipping/use-cases.md)  | [Data Model](./shipping/data-model.md)  | [Workflow](./shipping/workflow.md)  |
| [Báo cáo](./report/)              | —                              | —                                       | —                                   |

## DB Guide — giải thích sâu cơ sở dữ liệu

> Bộ [db/](./db/) đào sâu **tại sao** thiết kế từng bảng (kèm ví dụ số liệu), khác với `*/data-model.md` (chỉ định nghĩa schema). Đọc theo **dòng nghiệp vụ**, bắt đầu từ khái niệm lõi.

| # | Bài | # | Bài |
|---|---|---|---|
| 00 | [Khái niệm lõi](./db/00-khai-niem-loi.md) | 07 | [Shipping](./db/07-shipping.md) |
| 01 | [Kho & vị trí](./db/01-kho-va-vi-tri.md) | 08 | [Auth-WMS](./db/08-auth-wms.md) |
| 02 | [Hàng hóa & tồn 2 lớp](./db/02-hang-hoa-va-ton-kho.md) | 09 | [Catalog](./db/09-catalog.md) |
| 03 | [Nhập kho](./db/03-nhap-kho.md) | 10 | [Order](./db/10-order.md) |
| 04 | [In ly](./db/04-in-ly.md) | 11 | [Auth-Ecom](./db/11-auth-ecom.md) |
| 05 | [Xuất kho & nội bộ](./db/05-xuat-kho-va-noi-bo.md) | 12 | [Luồng end-to-end](./db/12-luong-end-to-end.md) |
| 06 | [Supplier](./db/06-supplier.md) | | [⌂ Index db/](./db/README.md) |

## Danh mục hàng hóa

| Loại              | Ký hiệu       | Ví dụ                                   |
| ----------------- | ------------- | --------------------------------------- |
| Nguyên liệu F&B   | `MATERIAL`    | Trà, sữa, đường, topping, syrup, bột... |
| Ly chưa in        | `CUP_BLANK`   | Ly nhựa, ly giấy (theo size S/M/L/XL)   |
| Ly đã in          | `CUP_PRINTED` | Ly in logo/design theo đơn khách        |
| Bao bì & Phụ kiện | `PACKAGING`   | Nắp ly, ống hút, túi, bao bì các loại   |

## Cấu trúc kho

```
Warehouse (Kho trung tâm — 1 kho duy nhất)
  └── Zone (Khu vực: A, B, C...)
        └── Rack (Kệ: A1, A2...)
              └── Shelf (Tầng: 1, 2, 3...)
```

## Actors

> 1 user có thể giữ **nhiều role** (`User.roles[]`). RolesGuard cho qua nếu roles giao với role yêu cầu.

| Role     | Quyền hạn                                                           |
| -------- | ------------------------------------------------------------------- |
| ADMIN        | (`wms_db.users`) Toàn quyền WMS, bypass mọi guard                  |
| MANAGER      | (`wms_db.users`) Tạo/duyệt phiếu nhập-xuất, lệnh in, kiểm kho      |
| RECEIVER     | (`wms_db.users`) Nhận hàng (GRN), put-away                         |
| PICKER       | (`wms_db.users`) Soạn & xuất hàng                                  |
| PRINTER      | (`wms_db.users`) Vận hành in, xác nhận in xong                     |
| COUNTER      | (`wms_db.users`) Kiểm đếm tồn thực tế                              |
| ECOM_MANAGER | (`ecom_db.admin_users`) Set giá, CRUD catalog, xem/can thiệp đơn — **auth riêng Ecom** |
