# chess-helper-ios
Dự án can thiệp trực tiếp vào Objective-C runtime của Chess.com để đọc object nội bộ `CHGame` qua method private:

```objc
fenForCurrentPosition:flipped:

```

### 1. Hook trực tiếp `CHBoardView` (lớp chính)

Hook các method cập nhật bàn cờ như `animateLastMove`, `updateMoveListDirectly`, `setupBoardForGame:updateHighlightsForLastMove:`, `setupWithFEN:`, `setupWithFEN:is960:`. Khi bàn cờ thay đổi, FEN được lấy từ `chessGame` hoặc đọc trực tiếp từ tham số truyền vào.

### 2. Hook generic (lớp quét vét)

`ChessFENExtractor` hook tuần tự `CHBoardView`, `CHLiveGameState`, `CHLiveGame`, `CHLiveChessClient` (cách nhau `0.4s`), duyệt danh sách method và thay thế IMP bằng block để bắt các method có tên chứa `fen`, `board`, `position`, `snapshot`, `gamestate`, `chessstate` có giá trị trả về.

### 3. Poll định kỳ mỗi 1.5s (lưới an toàn)

Tìm board view đang hiển thị qua `BoardPositionDetector` rồi gọi `fenForCurrentPosition:flipped:` để đảm bảo không bỏ sót trạng thái bàn cờ.

### Vì sao không hook `CHGame` trực tiếp?

Bot của Chess.com khởi tạo nhiều instance `CHGame` tạm thời để tính toán nội bộ; hook trực tiếp sẽ sinh ra FEN ảo và gây giật lag.

### Xử lý & lọc FEN

* **`FENValidator`**: Kiểm tra cấu trúc hợp lệ (8 hàng, mỗi hàng đủ 8 ô, lượt đi `w` hoặc `b`) và chuẩn hóa chỉ giữ 4 trường đầu (vị trí quân, lượt đi, quyền nhập thành, en passant).
* **Debounce & khử trùng**: Gom các FEN tới liên tục, chỉ phát FEN mới nhất sau `0.08s` và bỏ qua FEN trùng lặp.

### Nhận diện màu quân (Trắng / Đen)

- **Hook `CHBoardView` (`Tweak.xm`):** Hook `setFlipped:`, `setAllowUserToMakeBlackMoves:` và các method thiết lập ván cờ (`setupBoardForGame:...`) để nhận biết ngay khi vào ván, đổi bên hoặc đảo chiều bàn cờ, sau đó phát thông báo cập nhật trạng thái phe.
- **Đọc quyền & góc nhìn qua `BoardPositionDetector`:** Hàm `detectUserIsPlayingBlack` kiểm tra quyền đi (`allowUserToMakeWhiteMoves` / `allowUserToMakeBlackMoves`) trước; nếu cả hai đều mở (chế độ phân tích / Pass & Play) thì dựa vào `flipped` / `isFlipped` (`YES` là Đen, `NO` là Trắng).
- **Áp dụng & ghi đè:** Dùng kết quả nhận diện để đối chiếu lượt đi (`isOurTurnForFEN`) và lật tọa độ vẽ trên `ArrowOverlay`, đồng thời giữ công tắc chọn tay để override khi test thế cờ.

---

## Môi trường thử nghiệm & Lưu ý sử dụng
- **Phiên bản đã thử nghiệm**: Chess.com **4.8.18**, thử nghiệm trong các ván đấu với **bot**.
- **Mục đích nghiên cứu & học tập**: Dự án phục vụ mục đích tìm hiểu cơ chế runtime, kỹ thuật reverse/hooking và học tập. **Không sử dụng dự án để hack, cheat, gian lận** hoặc thực hiện các hành vi vi phạm điều khoản dịch vụ của Chess.com hay gây ảnh hưởng đến người chơi khác.
- **Miễn trừ trách nhiệm**: Người dùng tự chịu hoàn toàn trách nhiệm trước mọi rủi ro, hậu quả hoặc vi phạm phát sinh nếu sử dụng dự án .
