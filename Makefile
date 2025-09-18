build:
	swift build

watch-brave:
	swift run watcher $$(pgrep -x "Brave Browser" | head -n 1)
