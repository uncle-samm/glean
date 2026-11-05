.PHONY: build test bench push tag publish release

build:
	gleam build

test:
	gleam test

bench:
	gleam run -m glean_bench

push:
	sh scripts/push.sh

tag:
	sh scripts/tag.sh

publish:
	/usr/bin/expect scripts/publish.sh

release:
	sh scripts/release.sh
