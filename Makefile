build:
	swift build

watch-brave:
	swift run watcher $$(pgrep -x "Brave Browser" | head -n 1)

watch-iterm:
	swift run watcher $$(pgrep -x "iTerm2" | head -n 1)
