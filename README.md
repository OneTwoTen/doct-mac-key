# DoctKey — bộ gõ tiếng Việt / tiếng Anh cá nhân cho macOS

Bộ gõ cá nhân chạy ở tầng hệ thống (InputMethodKit), **lõi xử lý ngôn ngữ viết bằng Rust**,
hỗ trợ **Telex**, **VNI**, chế độ **tiếng Việt / tiếng Anh**, chuyển đổi bằng phím tắt toàn cục.

```
┌─────────────────────────────── macOS ───────────────────────────────┐
│  App bất kỳ (TextEdit, Chrome, VSCode, Terminal, Notes, …)          │
│        ▲ text đã ghép                                                │
│  DoctKey.app  (Swift, InputMethodKit)                               │
│    • hứng keyDown, giao tiếp host, hotkey, menu bar, cấu hình       │
│    • không chứa logic tiếng Việt                                     │
│        │ JSON qua C ABI (doctkey.h)                                 │
│  libdoctkey_core.a  (Rust)                                          │
│    • Telex / VNI, đặt dấu, chữ hoa, ưu tiên tiếng Việt, undo/restore │
└─────────────────────────────────────────────────────────────────────┘
```

## Tính năng

- **Telex**: `aa→â, ee→ê, oo→ô, aw→ă, ow→ơ, uw→ư, w→ư, dd→đ`, dấu `s f r x j`, `z` xoá dấu.
- **VNI**: dấu `1 2 3 4 5`, `0` xoá dấu, `6` â/ê/ô, `7` ơ/ư, `8` ă, `9` đ.
- **Đặt dấu thông minh**: `tiếng`, `đường`, `người`, `hoà`/`hòa`, `thuỷ`/`thủy` (kiểu mới / kiểu cũ),
  xử lý đúng `qu`, `gi`, nguyên âm đôi/ba, âm cuối.
- **Ưu tiên tiếng Việt như UniKey**: cách gõ nào tạo được âm tiết Việt thì ra tiếng
  Việt (`test→tét`, `this→thí`, `queen→quên`, `treen→trên`); từ tiếng Anh chỉ giữ
  nguyên khi không thể là tiếng Việt (`hello`, `meeting`, `google`, `text`).
  Muốn gõ tiếng Anh đúng từng chữ thì chuyển chế độ EN bằng `⌃⌥V`.
- **Phím `w` như UniKey**: `w`→`ư`, `tw`→`tư`, `chw`→`chư`, `nw`→`nư`; còn `kw`,
  `ew`, `new`, `threw` vẫn là `w`.
- **Khôi phục / undo**: gõ lặp phím biến đổi để huỷ (`aaa→aa`, `ass→as`), `z` xoá dấu,
  `Esc` trả lại đúng các phím đã gõ, `Backspace` xoá từng phím gốc.
- **Phím tắt toàn cục** đổi chế độ tức thì, có menu bar hiển thị VI/EN.
- Cấu hình bằng file JSON, sửa hotkey/kiểu gõ/kiểu đặt dấu.

## Yêu cầu

- macOS 13 trở lên (đã kiểm tra trên macOS 26 Tahoe, Apple Silicon).
- Để build: Xcode Command Line Tools (`xcode-select --install`) và Rust (`rustup`).
- Cài đặt vào thư mục hệ thống trên macOS 26 cần quyền admin (script sẽ gọi `sudo`).

## Cài đặt

```bash
cd doct-mac-key
make build          # build lõi Rust + app Swift -> build/DoctKey.app
make test           # chạy toàn bộ test của lõi (Rust) và của app (Swift)
make install        # cài vào hệ thống (macOS 26+: /Library/Input Methods, cần sudo)
```

`make install` in ra hướng dẫn. Sau khi cài:

1. **Đăng xuất và đăng nhập lại** (macOS 26 bắt buộc để hệ thống nhận bộ gõ mới).
2. **System Settings → Keyboard → Input Sources → ＋** → chọn **DoctKey** → **Add**.
3. Chuyển nhanh giữa các bộ gõ bằng `⌃Space` (phím tắt hệ thống) và chuyển
   Việt/Anh của DoctKey bằng `⌃⌥V`.

Nếu sau khi đăng nhập lại vẫn chưa thấy DoctKey trong danh sách, chạy:

```bash
make enable          # đăng ký + bật input source đã cài
scripts/diagnose.sh  # in chẩn đoán (phiên bản macOS, chữ ký, TIS, config)
```

Nếu DoctKey không xuất hiện trong danh sách: xem mục *Khắc phục sự cố* bên dưới.

### Cập nhật tự động và phát hành

DoctKey kiểm tra **GitHub Releases công khai** khi bộ gõ khởi động. Khi có bản mới,
menu bar đổi thành **“Cập nhật DoctKey lên …”**. Chọn mục đó để tải, kiểm tra chữ ký
và cài bản cập nhật; DoctKey tự khởi động lại sau khi thay thế app. Cấu hình người dùng
được giữ nguyên. Trên macOS 26, vì app nằm trong `/Library/Input Methods`, macOS có thể
yêu cầu xác nhận quyền quản trị lúc cài bản mới.

Mã nguồn và các bản phát hành được lưu công khai tại
[OneTwoTen/doct-mac-key trên GitHub](https://github.com/OneTwoTen/doct-mac-key), không qua
Apple App Store. Để phát hành bản mới từ máy phát triển:

```bash
git push origin main
make release VERSION=0.2.1
```

Lệnh phát hành cần GitHub CLI đã đăng nhập (`gh auth login`) và chứng chỉ **Apple
Development** hoặc **Developer ID Application** trong Keychain. Nó tạo app đã ký, đóng
gói `DoctKey-<version>-macos-arm64.zip` rồi tải lên GitHub Releases. Người dùng đã cài
DoctKey sẽ nhận được bản mới qua bộ cập nhật tích hợp.

### Cài cho riêng người dùng (macOS cũ hơn)

Trên macOS 13–15, app có thể cài vào `~/Library/Input Methods` không cần sudo;
`scripts/install.sh` tự chọn vị trí theo phiên bản macOS. Có thể ép vị trí:

```bash
TARGET_DIR="$HOME/Library/Input Methods" ./scripts/install.sh
```

### Ký app bằng chứng chỉ Apple (nếu hệ thống chặn chữ ký ad-hoc)

Mặc định app được ký ad-hoc. Nếu macOS từ chối nạp bộ gõ (thường gặp trên macOS 26),
ký lại bằng chứng chỉ **Apple Development** hoặc **Developer ID Application**:

1. Mở **Xcode → Settings → Accounts**, thêm Apple ID của bạn.
2. Chọn **Manage Certificates… → ＋ → Apple Development** để tạo chứng chỉ miễn phí.
3. Xem tên chứng chỉ:

   ```bash
   security find-identity -v -p codesigning
   ```

4. Cài lại với chứng chỉ đó:

   ```bash
   SIGN_ID="Apple Development: Tên Bạn (TEAMID)" make install
   ```

Nếu sau khi đăng xuất/đăng nhập vẫn không thấy DoctKey trong Input Sources, thử đổi
thư mục cài (một số bản macOS 26 dùng lại đường dẫn cũ):

```bash
TARGET_DIR="$HOME/Library/Input Methods" ./scripts/install.sh
```

## Giao diện quản lý (Settings)

App có cửa sổ quản lý đầy đủ, mở bằng một trong các cách:

- Menu bar → **Cài đặt…** (hoặc `⌘,` khi cửa sổ đang mở), hay chạy `make settings`;
- Mở `DoctKey.app` từ Finder (double-click) — nếu bộ gõ đang chạy nền thì app mở cửa sổ này;
- Chạy trực tiếp: `"/Library/Input Methods/DoctKey.app/Contents/MacOS/DoctKey" --settings`.

Cửa sổ gồm 4 tab:

| Tab | Nội dung |
|---|---|
| **Chung** | Chế độ gõ (Tiếng Việt / English), kiểu gõ (Telex / VNI), kiểu đặt dấu (Hiện đại / Truyền thống), Ưu tiên tiếng Việt, chế độ chèn (Marked / Direct), **chế độ tương thích (CGEvent)** + cấp quyền Accessibility + **khởi động cùng macOS**, mở/nạp lại file cấu hình. Mọi thay đổi áp dụng ngay và được lưu. |
| **Phím tắt** | Sửa 5 phím tắt toàn cục dạng `ctrl+alt+v`, kiểm tra hợp lệ, **Áp dụng** (đăng ký lại ngay) và **Khôi phục mặc định**. |
| **Trạng thái** | Đường dẫn bản đang chạy/bản đã cài, phiên bản, chữ ký (ad-hoc / Apple Development / Developer ID), danh sách chứng chỉ ký mã, trạng thái nguồn nhập (đã đăng ký & bật / chưa bật / **chưa được hệ thống nhận**), nút **Đăng ký bộ gõ**, **Bật**, **Chọn**, **Mở System Settings → Input Sources**, **Sao chép chẩn đoán**, và phần **Cài / cập nhật vào hệ thống…** (có chọn chứng chỉ ký) / **Gỡ cài đặt…**. |
| **Giới thiệu** | Phiên bản, đường dẫn cấu hình, hướng dẫn nhanh. |

Trạng thái **“Chưa được hệ thống nhận”** là bình thường ngay sau khi cài trên macOS 26:
hệ thống chỉ quét lại nguồn nhập khi **đăng xuất/đăng nhập**. Sau khi đăng nhập lại, bấm
**Đăng ký bộ gõ** (hoặc thêm trực tiếp trong System Settings → Keyboard → Input Sources).

## Chế độ tương thích (CGEvent) — dùng khi bộ gõ chuẩn chưa được macOS nhận

Trên macOS 26, bộ gõ InputMethodKit **chỉ được hệ thống nhận nếu app được ký hợp lệ**
(Apple Development/Developer ID) — sau khi cài vẫn cần đăng xuất/đăng nhập. Nếu vì lý do
nào đó DoctKey không xuất hiện trong Input Sources, app có sẵn **chế độ tương thích**:
app chạy nền, bắt phím bằng CGEventTap và ghép tiếng Việt trực tiếp vào app đang focus,
**không cần cài làm nguồn nhập**.

Cách bật:

1. Mở **Cài đặt → Chung** → bật **“Bật chế độ tương thích (CGEvent)”**.
2. Cấp quyền: **System Settings → Privacy & Security → Accessibility** → thêm
   `DoctKey.app` (bản đã cài trong `/Library/Input Methods`) và bật công tắc.
   App sẽ hiện hộp thoại yêu cầu quyền ở lần bật đầu tiên; bấm **“Kiểm tra lại”** sau khi cấp.
3. Chọn bố cục **ABC** trong Input Sources (đừng chọn DoctKey làm nguồn nhập cùng lúc).
4. Bật **“Khởi động DoctKey cùng macOS”** (cùng tab) để chế độ tương thích chạy sau khi đăng nhập.
5. Gõ thử `vieejt ` ở bất kỳ app nào → ra `việt`. Trạng thái phải là
   *“Đang chạy — gõ tiếng Việt trực tiếp…”*.

Lưu ý: cần quyền Accessibility; một số app (ô mật khẩu, game, secure input) có thể không
nhận; nên tắt chế độ này khi dùng bộ gõ DoctKey chuẩn để tránh ghép đôi.

## Phím tắt mặc định

| Tổ hợp | Tác dụng |
|---|---|
| `⌃⌥V` | Chuyển **Tiếng Việt ⇄ English** |
| `⌃⌥T` | Chuyển **Telex ⇄ VNI** |
| `⌃⌥D` | Chuyển **kiểu đặt dấu mới ⇄ cũ** |
| `⌃⌥E` | Bật/tắt **ưu tiên tiếng Việt** (tắt = luôn bỏ dấu tiếng Việt) |
| `⌃⌥R` | Nạp lại file cấu hình |

Menu bar hiển thị `VI` hoặc `EN`; bấm vào để đổi nhanh, xem cấu hình, mở file cấu hình
hoặc thoát app.

## Cách gõ

**Telex cơ bản**

```
vieejt   → việt          tieengs  → tiếng
dduwowngf → đường        nguwowif → người
hoawcj   → hoặc          quas     → quá
giaf     → già           giuwx    → giữ
```

**VNI cơ bản**

```
vie65t      → việt        tie61ng    → tiếng
d9u7o7ng2   → đường       ngu7o7i2   → người
hoa8c5      → hoặc        thuy3      → thuỷ
```

**Mẹo**

- Gõ lặp phím biến đổi để huỷ dấu: `aaa → aa`, `ass → as`, `ddd → dd`.
- `z` xoá dấu: `aasz → â`, `aaszz → a`.
- `Esc` khi đang gõ dở: trả lại đúng chuỗi phím gốc (ví dụ `vieejt<Esc> → vieejt`).
- Muốn gõ tiếng Anh chắc chắn: nhấn `⌃⌥V` để sang chế độ EN (giống UniKey).

## Cấu hình

File: `~/.config/doctkey/config.json` (tự tạo khi chạy lần đầu; menu bar có mục mở file
và nạp lại).

```json
{
  "mode": "vi",
  "method": "telex",
  "tone_style": "modern",
  "smart_english": true,
  "insert_mode": "marked",
  "hotkeys": {
    "toggle_mode": "ctrl+alt+v",
    "toggle_method": "ctrl+alt+t",
    "toggle_tone_style": "ctrl+alt+d",
    "toggle_smart": "ctrl+alt+e",
    "reload_config": "ctrl+alt+r"
  }
}
```

| Khoá | Giá trị | Ý nghĩa |
|---|---|---|
| `mode` | `vi` / `en` | chế độ gõ mặc định |
| `method` | `telex` / `vni` | kiểu gõ |
| `tone_style` | `modern` / `traditional` | `hoà/thuỷ/khoẻ` hay `hòa/thủy/khỏe` |
| `smart_english` | `true` / `false` | tự nhận biết từ không phải tiếng Việt |
| `insert_mode` | `marked` / `direct` | cách chèn chữ: dùng marked text (mặc định) hoặc tự thay thế trực tiếp |
| `hotkeys` | chuỗi | dạng `ctrl+alt+v`, `cmd+shift+1`, … |

Ghi chú: chế độ `vi`/`en` và kiểu gõ là **toàn cục** cho mọi app; khi đổi bằng phím tắt
hay menu, cấu hình được ghi lại vào file.

## Kiểm thử & phát triển

```bash
make test-core    # toàn bộ fixture Telex/VNI/dấu/smart/editing + unit test Rust
make test-swift   # chạy cùng bộ fixture qua tầng Swift (KeyHandler) ở cả 2 insert mode
make cli          # gõ thử trực tiếp trên terminal với lõi Rust
```

Bộ fixture nằm ở `core/tests/fixtures/*.tsv` — mỗi dòng là
`method,mode,smart,tone_style <TAB> phím <TAB> kết quả mong đợi`; đây là hợp đồng
hành vi của lõi và được cả test Rust lẫn test Swift dùng chung.

Gõ thử bằng CLI:

```bash
cargo run --manifest-path core/Cargo.toml --bin doctkey-cli -- --keys "vieejt nam"
# việt nam
cargo run --manifest-path core/Cargo.toml --bin doctkey-cli -- --repl
```

## Khắc phục sự cố

| Hiện tượng | Cách xử lý |
|---|---|
| Không thấy DoctKey trong Input Sources | Mở cửa sổ **Cài đặt → Trạng thái** để xem lý do; đăng xuất/đăng nhập lại là bắt buộc trên macOS 26; bấm **Đăng ký bộ gõ**; nếu vẫn không được, xem chữ ký (ad-hoc?) và ký lại bằng Apple Development trong tab Trạng thái; hoặc chạy `scripts/diagnose.sh`. |
| Đã chọn DoctKey nhưng gõ không ra dấu | Kiểm tra menu bar đang là `VI` (nhấn `⌃⌥V`); kiểm tra kiểu gõ đúng (`Telex`/`VNI`); thử đổi `insert_mode` sang `direct` nếu app không hiển thị marked text. |
| macOS chặn bộ gõ chuẩn (không thấy trong Input Sources, chữ ký ad-hoc) | Dùng **Chế độ tương thích (CGEvent)**: tab Chung → bật, cấp quyền Accessibility, chọn bố cục ABC, bật khởi động cùng macOS. |
| Gõ tiếng Anh bị bẻ dấu | Chuyển sang chế độ EN (`⌃⌥V`) — bộ gõ ưu tiên tiếng Việt giống UniKey. |
| Không gõ được trong Terminal / VSCode / một số app | Đổi `insert_mode` sang `direct` trong config rồi nạp lại (`⌃⌥R`). |
| App không chạy / menu bar không hiện | `pkill -f DoctKey` rồi chọn lại bộ gõ; xem log: `log stream --predicate 'process == "DoctKey"'`. |
| macOS báo app không hợp lệ / chặn chữ ký | Ký bằng chứng chỉ Apple Development/Developer ID: `SIGN_ID="..." make install`. |
| Muốn gỡ hoàn toàn | `make uninstall`, sau đó xoá DoctKey trong System Settings → Input Sources. |

## Cấu trúc dự án

```
core/        lõi Rust: engine, Telex, VNI, đặt dấu, validator tiếng Việt, C ABI, CLI, test
  include/doctkey.h        C ABI (hợp đồng với app Swift)
  tests/fixtures/*.tsv     bộ kiểm thử hành vi (dùng chung)
macos/       app Swift InputMethodKit: hứng phím, chèn chữ, hotkey, menu bar, config
  Tests/                 test harness chạy fixture qua tầng Swift
scripts/     build / test / install / uninstall / enable input source
docs/SPEC.md đặc tả chi tiết (hành vi engine, giao thức JSON, thiết kế app)
```

## Ghi chú kỹ thuật

- App Swift **không** chứa quy tắc tiếng Việt. Mọi phím được chuyển cho lõi Rust qua
  C ABI; lõi trả về JSON mô tả thao tác cần làm (`append` / `replace` / `commit` /
  `pass` / `none`) và tầng Swift chỉ thi hành.
- Lõi **tính lại từ đầu** chuỗi phím gốc của từ đang gõ sau mỗi phím, nhờ vậy
  `Backspace`, `Esc`, huỷ dấu và ưu tiên tiếng Việt luôn nhất quán, tất định.
- Mode/kiểu gõ là trạng thái toàn cục của engine trong tiến trình bộ gõ; phần soạn
  từ của từng client được reset khi đổi app.

## Giấy phép

Dự án cá nhân, dùng cho mục đích học tập và sử dụng cá nhân.
