-- Real keystrokes into a process by pid (used by scripted checks).
-- osascript scripts/keys.applescript PID ACTION...
--   text:STRING      keystroke STRING (mapped through the current keyboard layout)
--   return           Return key
--   cmd:KEY | cmdshift:KEY | cmdopt:CODE | ctrlcmd:CODE | opt:KEY   chords (CODE = key code, e.g. 123 left)
--   code:N           key code N
--   delay:SECONDS
on run argv
	set p to (item 1 of argv) as integer
	tell application "System Events"
		set frontmost of (first process whose unix id is p) to true
		delay 0.4
		repeat with i from 2 to count of argv
			set a to item i of argv
			if a starts with "text:" then
				keystroke (text 6 thru -1 of a)
			else if a is "return" then
				key code 36
			else if a starts with "cmdshift:" then
				keystroke (text 10 thru -1 of a) using {command down, shift down}
			else if a starts with "cmdopt:" then
				key code ((text 8 thru -1 of a) as integer) using {command down, option down}
			else if a starts with "ctrlcmd:" then
				key code ((text 9 thru -1 of a) as integer) using {command down, control down}
			else if a starts with "cmd:" then
				keystroke (text 5 thru -1 of a) using {command down}
			else if a starts with "optcode:" then
				key code ((text 9 thru -1 of a) as integer) using {option down}
			else if a starts with "opt:" then
				keystroke (text 5 thru -1 of a) using {option down}
			else if a starts with "code:" then
				key code ((text 6 thru -1 of a) as integer)
			else if a starts with "delay:" then
				delay ((text 7 thru -1 of a) as real)
			end if
			delay 0.15
		end repeat
	end tell
end run
