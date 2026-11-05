ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:14.0
INSTALL_TARGET_PROCESSES = Aweme

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = DouyinClearScreen

# Tweak.x 负责 hook 与四层清屏逻辑，Icons.h 是悬浮按钮的两张 PNG（base64）
DouyinClearScreen_FILES = Tweak.x
DouyinClearScreen_CFLAGS = -fobjc-arc -Wno-unused-function
DouyinClearScreen_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
