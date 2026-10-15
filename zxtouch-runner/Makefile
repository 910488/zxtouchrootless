include $(THEOS)/makefiles/common.mk

TOOL_NAME = zxtouch-runner
zxtouch-runner_ARCHS = arm64 arm64e
zxtouch-runner_FILES = main.m
zxtouch-runner_CFLAGS = -fobjc-arc -O2 -DNDEBUG -Wno-module-import-in-extern-c
zxtouch-runner_FRAMEWORKS = Foundation
zxtouch-runner_INSTALL_PATH = /usr/libexec

include $(THEOS_MAKE_PATH)/tool.mk
