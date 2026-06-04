# Supplier — Workflow

> Trạng thái: 🔄 Đang phân tích

## Luồng tổng quan

```
[WF-S01 Vòng đời trạng thái NCC] ── quyết định ──▶ [WF-S02 Tạo PO có gợi ý + guard]
        ACTIVE / INACTIVE / BLACKLIST                  chỉ ACTIVE mới qua guard
```

---

## WF-S01: Vòng đời trạng thái NCC

```
        tạo mới
          │
          ▼
       ACTIVE  ◀──────────  INACTIVE        (MANAGER toggle 2 chiều)
          │    ──────────▶
          │
          │ BLACKLIST (MANAGER)
          ▼
      BLACKLIST  ──(gỡ: chỉ ADMIN)──▶  ACTIVE
```

> - Chỉ NCC `ACTIVE` qua được guard tạo PO ([WF-S02](#wf-s02-tạo-po-có-gợi-ý-giá--guard-blacklist)).
> - Đổi trạng thái **không** đụng tới PO đang dở — chúng vẫn nhận hàng (GRN) bình thường.

---

## WF-S02: Tạo PO có gợi ý giá + guard blacklist

```
MANAGER                 SUPPLIER MODULE            WAREHOUSE (PO)
  |                          |                          |
  |-- chọn SKU ------------->| tra SupplierItem theo itemId
  |<-- gợi ý NCC + giá ------| (purchasePrice, leadTime, MOQ)
  |-- sửa/giữ giá ---------->|                          |
  |-- xác nhận (CONFIRM) -------------------------------▶| guard: supplier.status == ACTIVE?
  |                          |                  YES → CONFIRMED
  |                          |                  NO  → chặn + báo lý do (INACTIVE/BLACKLIST)
```

> - `purchasePrice` chỉ là **gợi ý** — MANAGER sửa tay được; giá chốt lưu ở `PurchaseOrderItem.unitPrice`.
> - PO đã `CONFIRMED`/`SENT` trước khi NCC bị chặn → [GRN (UC-02)](../warehouse/use-cases.md#uc-02-good-receive-note-grn) nhận hàng bình thường, không qua guard.
