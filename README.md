# VT-110 – Idempotency

## 1. Giới thiệu

Đây là repository cá nhân thực hiện bài tập Software Engineering – biến thể **VT-110 (Idempotency)** trên dự án GAME-2D-02: Procedural Dungeon.

Mục tiêu là đảm bảo `start_new_run()` có tính idempotency: khi cùng một request ID và payload được gửi lại, hệ thống trả về kết quả trước đó mà không tạo run, record hoặc signal trùng lặp.

## 2. Môi trường

- Godot Engine: `4.7.2.stable.official.ed1daf0bf`
- Ngôn ngữ: GDScript
- Chế độ kiểm thử: Headless

## 3. Cấu trúc liên quan

```text
scripts/
└── run_management/
    ├── run_manager.gd
    └── run_record_repository.gd

tests/
├── test_run_manager.gd
├── run_tests.gd
└── load_test_vt110.gd
```

## 4. Cách chạy test

Mở Terminal tại thư mục gốc repository và chạy:

```bash
godot --headless --path . -s res://tests/run_tests.gd
```

Nếu sử dụng Windows và chưa thêm Godot vào PATH, có thể gọi trực tiếp executable:

```powershell
& "C:\Godot_v4.7.2-stable_win64\Godot_v4.7.2-stable_win64_console.exe" --headless --path . -s res://tests/run_tests.gd
```

Kết quả mong đợi:

```text
Tests: 50
Passed: 50
Failed: 0
```

Một thông báo `ERROR: Could not create directory` xuất hiện trong test `test_storage_failure_blocks_run_start` là lỗi lưu trữ được cố ý tạo để kiểm tra failure handling. Test này vẫn PASS.

## 5. Load test

Harness thử nghiệm tải nằm tại:

```text
tests/load_test_vt110.gd
```

Chạy bằng:

```bash
godot --headless --path . -s res://tests/load_test_vt110.gd
```

Thử nghiệm gồm 120 request logic được xử lý tuần tự trên một manager, không phải 120 tác vụ đồng thời thực sự. Kết quả và giới hạn của phép thử được trình bày trong báo cáo cá nhân.

## 6. Thông tin nộp bài

- Repository: https://github.com/Des19305/SE-VT110-Idempotency
- Submission branch: `assignment/vt110-idempotency`
- Baseline commit: `4000089`
- Final implementation commit: `a8b09ef`

Mutation experiment được thực hiện trên branch riêng `mutation/vt110-response-mapping`, không nằm trong submission branch.
