# 便捷包装：直接调用 build.sh（需要 theos 工具链与 iOS SDK）
#   make        -> build/YuanbaoCheckin.dylib
#   make clean
.PHONY: all clean

all:
	./build.sh

clean:
	rm -rf build .theos