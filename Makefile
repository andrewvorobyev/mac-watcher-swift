build:
	swift build -c release

capture-brave:
	swift run -c release capture $$(pgrep -x "Brave Browser" | head -n 1)

capture-iterm:
	swift run -c release capture $$(pgrep -x "iTerm2" | head -n 1)

observe-brave:
	swift run -c release observe $$(pgrep -x "Brave Browser" | head -n 1)

observe-iterm:
	swift run -c release observe $$(pgrep -x "iTerm2" | head -n 1)

screenshot-brave:
	swift run -c release screenshot $$(pgrep -x "Brave Browser" | head -n 1)

screenshot-iterm:
	swift run -c release screenshot $$(pgrep -x "iTerm2" | head -n 1)
