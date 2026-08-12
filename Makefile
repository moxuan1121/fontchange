# RootHide packages use the iphoneos-arm64e Debian architecture. Standalone
# apps/tools remain arm64 to avoid the incompatible arm64e ABI on iOS 15.
ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = roothide

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = FontChangeExperimental
FontChangeExperimental_FILES = App/main.m App/AppDelegate.m App/ViewController.m
FontChangeExperimental_FRAMEWORKS = UIKit Foundation CoreFoundation CoreText UniformTypeIdentifiers
FontChangeExperimental_CFLAGS = -fobjc-arc -Wall -Wextra
FontChangeExperimental_CODESIGN_FLAGS = -SApp/FontChange.entitlements
FontChangeExperimental_RESOURCE_DIRS = App/Resources

include $(THEOS_MAKE_PATH)/application.mk

TOOL_NAME = fontchange-selfcontained-helper fontchange-bindfs
fontchange-selfcontained-helper_FILES = Helper/main.m
fontchange-selfcontained-helper_FRAMEWORKS = Foundation CoreFoundation
fontchange-selfcontained-helper_CFLAGS = -fobjc-arc -Wall -Wextra
fontchange-selfcontained-helper_CODESIGN_FLAGS = -SHelper/fontchange-helper.entitlements
fontchange-selfcontained-helper_INSTALL_PATH = /usr/libexec

fontchange-bindfs_FILES = MountTool/main.c
fontchange-bindfs_CFLAGS = -Wall -Wextra
fontchange-bindfs_CODESIGN_FLAGS = -SMountTool/fontchange-bindfs.entitlements
fontchange-bindfs_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk

after-stage::
	chmod 6755 $(THEOS_STAGING_DIR)/usr/libexec/fontchange-selfcontained-helper
	chmod 0755 $(THEOS_STAGING_DIR)/usr/libexec/fontchange-bindfs
