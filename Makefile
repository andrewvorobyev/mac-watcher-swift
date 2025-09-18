build:
	swift build -c release

watch-brave:
	swift run -c release watcher $$(pgrep -x "Brave Browser" | head -n 1)

watch-iterm:
	swift run -c release watcher $$(pgrep -x "iTerm2" | head -n 1)
