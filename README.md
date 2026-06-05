# WMS-ECOM — Tài liệu Phân tích Nghiệp vụ

## Tổng quan kiến trúc

| Tài liệu                                         | Nội dung                                          |
| ------------------------------------------------ | ------------------------------------------------- |
| [System Context](./overview/system-context.md)   | Kiến trúc tổng thể, Nginx, BullMQ, Infrastructure |
| [NestJS Monorepo](./overview/nestjs-monorepo.md) | Monorepo mode, Auth tách biệt WMS vs Ecommerce    |
| [Data Ownership](./overview/data-ownership.md)   | Phân chia collection, sync tồn kho qua event      |
| [Main Flow](./overview/main-flow.md)             | Luồng nghiệp vụ end-to-end toàn hệ thống (P0→P7)   |

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

## Danh mục hàng hóa

| Loại              | Ký hiệu       | Ví dụ                                   |
| ----------------- | ------------- | --------------------------------------- |
| Nguyên liệu F&B   | `MATERIAL`    | Trà, sữa, đường, topping, syrup, bột... |
| Ly chưa in        | `CUP_BLANK`   | Ly nhựa, ly giấy (theo size S/M/L/XL)   |
| Ly đã in          | `CUP_PRINTED` | Ly in logo/design theo đơn khách        |
| Bao bì & Phụ kiện | `PACKAGING`   | Nắp ly, ống hút, túi, bao bì các loại   |

## Cấu trúc kho

```
Warehouse (Kho trung tâm / Kho phụ)
  └── Zone (Khu vực: A, B, C...)
        └── Rack (Kệ: A1, A2...)
              └── Shelf (Tầng: 1, 2, 3...)
```

## Actors

> 1 user có thể giữ **nhiều role** (`User.roles[]`). RolesGuard cho qua nếu roles giao với role yêu cầu.

| Role     | Quyền hạn                                                           |
| -------- | ------------------------------------------------------------------- |
| ADMIN    | Xem tất cả, cấu hình hệ thống, báo cáo toàn diện (bypass mọi guard) |
| MANAGER  | Tạo/duyệt phiếu nhập-xuất, lệnh in, kiểm kho, chuyển kho            |
| RECEIVER | Nhận hàng (GRN), put-away, nhận hàng chuyển kho                     |
| PICKER   | Soạn & xuất hàng, xuất hàng chuyển kho                              |
| PRINTER  | Vận hành in, xác nhận in xong                                       |
| COUNTER  | Kiểm đếm tồn thực tế                                                |
