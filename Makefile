ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FontLanguageDiagnostics
FontLanguageDiagnostics_FILES = Diagnostic/Tweak.xm
FontLanguageDiagnostics_FRAMEWORKS = Foundation CoreFoundation
FontLanguageDiagnostics_CFLAGS = -fobjc-arc -Wall -Wextra

include $(THEOS_MAKE_PATH)/tweak.mk
