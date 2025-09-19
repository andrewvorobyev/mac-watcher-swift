
## Browser rendering

So far, even rendering google.com is a huge output. A lot can still be pruned but it might be hard to do in a generic way.

## iTerm2 rendering

...

## Layout updates

Accessibility API allows observing changes: https://chatgpt.com/share/68cc4405-5324-8004-8977-d78dd6e44ca5

## Thoughts

- How do voice over readers work? They also need to make sense of the big and messy tree and probably deal with updates.
- It might be worth to have our own layout representation for the LLM and use it to map both DOM and Accessibility Trees to. Potentially just the ATs because DOM is already reduced to AT.

**What is going to be tough?**
- Dynamic sites. E.g. counters, SVG animations, ads banners etc.
- Long content on the websites, potentially hidden under the elements.
- User scrolling fast and internally paying attention to specific things, while the model will likely get the entire document.
- Fast switching across apps / tabs. Probably need a serios caching layer.
- Tabs / apps with video stream (e.g. google meet).
- Do we need to mix ATs with screenshots to better percept the layout?
- Multitasking

- Capturing a tree of Youtube page is slow

- Need to limit capturing to visible elements only. Currently I'm capturing menus content as well (including the top of the screen menu bar).
    - After changes, there're still some invisible elements returned (e.g. hover views). That can be further optimized.


