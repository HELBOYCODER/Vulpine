.PHONY: all build run test clean

all: build

build:
	@bash scripts/build.sh

run: build
	open build/Vulpine.app

test:
	swift run --target VulpineTests

clean:
	rm -rf .build build
