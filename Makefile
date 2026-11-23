TARGET := iphone:clang:latest:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
_THEOS_PLATFORM_DPKG_DEB_COMPRESSION = gzip

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = ChessAssistant

ChessAssistant_FILES = \
    Tweak.xm \
    ChessAssistantView.m \
    ChessFENExtractor.m \
    ChessLogStore.m \
    BoardPositionDetector.m \
    ChessAPIClient.m \
    ArrowOverlay.m \
    ChessOfflineEngineClient.m \
    Core/CrashHandler.m \
    ChessEngine/FENValidator.m \
    ChessEngine/SuggestionPlanner.m
ChessAssistant_FRAMEWORKS = UIKit Foundation Security
ChessAssistant_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Oz

# ── Nhúng icon.jpeg và stockfish-arm64 trực tiếp vào dylib dưới dạng section __DATA ──
STOCKFISH_BIN := $(THEOS_PROJECT_DIR)/stockfish-arm64

ifeq ($(wildcard $(STOCKFISH_BIN)),)
$(warning ⚠️ stockfish-arm64 không tồn tại — chạy scripts/build_stockfish_ios.sh)
STOCKFISH_SECTCREATE :=
else
STOCKFISH_SECTCREATE := -Wl,-sectcreate,__DATA,__stockfish,$(STOCKFISH_BIN)
endif

ChessAssistant_LDFLAGS = \
    -Wl,-sectcreate,__DATA,__icon,$(THEOS_PROJECT_DIR)/icon.jpeg \
    $(STOCKFISH_SECTCREATE)

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 \"$(TARGET_APP_PROCESS)\" || true"
