ARCHS = arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = FontChange
FontChange_FILES = App/main.m App/AppDelegate.m App/ViewController.m Shared/LanguagePreferences.m
FontChange_FRAMEWORKS = UIKit Foundation CoreFoundation
FontChange_CFLAGS = -fobjc-arc -Wall -Wextra
FontChange_CODESIGN_FLAGS = -SApp/FontChange.entitlements
FontChange_RESOURCE_DIRS = App/Resources

include $(THEOS_MAKE_PATH)/application.mk

TOOL_NAME = fontchange-helper
fontchange-helper_FILES = Helper/main.m Shared/LanguagePreferences.m
fontchange-helper_FRAMEWORKS = Foundation CoreFoundation
fontchange-helper_CFLAGS = -fobjc-arc -Wall -Wextra
fontchange-helper_CODESIGN_FLAGS = -SHelper/fontchange-helper.entitlements
fontchange-helper_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk

after-stage::
	chmod 6755 $(THEOS_STAGING_DIR)/usr/libexec/fontchange-helper
