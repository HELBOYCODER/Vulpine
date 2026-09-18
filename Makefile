.PHONY: all build run dmg test clean

all: build

build:
	@bash scripts/build.sh

dmg:
	@bash scripts/build-dmg.sh

run: build
	open build/Vulpine.app

clean:
	rm -rf .build build
