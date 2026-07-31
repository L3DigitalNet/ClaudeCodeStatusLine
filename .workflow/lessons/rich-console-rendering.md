Use Rich `Style.render` over raw segments for Bash-parity styling; high-level Rich `Text` normalizes embedded terminal controls.

Evidence: the installed Rich 14.3.2 probe showed that high-level `Text` changed BEL, carriage return, backspace, and tab content, while `Style.render(..., ColorSystem.TRUECOLOR)` preserved it; differential control-byte tests now pass byte-for-byte.
