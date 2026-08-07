# TUI tests

`<<|` and `<<|?` cannot be tested through a pipe: they need a real terminal, and
a program reading from a pipe never reaches raw mode at all.  `ptydrive.py`
allocates a pty and feeds keystrokes as the program asks for them.

```bash
python3 tests/ptydrive.py ./zyml run tests/tui/keys_blocking.zy -- 'x' '\x1b[A' 'z'
python3 tests/ptydrive.py zymbol   run tests/tui/keys_blocking.zy -- 'x' '\x1b[A' 'z'
```

The two outputs must be byte-identical, escape sequences included.

Keys are sent **interleaved** with reading, not up front.  A program that has
not yet put the terminal into raw mode is still line-buffered, so anything sent
before that point is echoed by the terminal instead of reaching the program —
which is what made the first version of this driver hang.

`keys_blocking.zy` covers `<<|` and arrow decoding; `keys_polling.zy` covers
`<<|?` inside a game loop, together with `>>!`, `>>~` and `@~`.
