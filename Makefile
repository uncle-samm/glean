.PHONY: build test push tag publish release

build:
	gleam build

test:
	gleam test

push:
	sh scripts/push.sh

tag:
	sh scripts/tag.sh

publish:
	/usr/bin/expect scripts/publish.sh

release: push tag publish
