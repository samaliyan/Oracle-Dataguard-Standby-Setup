#!/usr/bin/python3
"""Small terminal emulator for the screen-layout tests (stdlib only).
Knows what dg_standby_setup.sh sends: text with autowrap, CR LF BS, CUP (H), CUU (A), ED (J), EL (K),
DECSTBM (r), DECSC/DECRC (ESC 7 / ESC 8), the alternate screen (?1049h/l), cursor hide/show, SGR colors.
Screen cells keep (char, fg, bold, dim) for an HTML picture."""
import re, html

class VT:
    def __init__(self, rows=24, cols=80):
        self.rows, self.cols = rows, cols
        self.main = self._blank(); self.alt = self._blank(); self.scr = self.main
        self.r = self.c = 0; self.top, self.bot = 0, rows - 1
        self.saved = (0, 0); self.alt_saved = (0, 0); self.in_alt = False
        self.attr = (None, False, False); self.wrap_next = False
        self.history = []      # lines scrolled off the top of the main screen (full-screen region only)
        self.buf = ""

    def _blank(self):
        return [[(" ", None, False, False) for _ in range(self.cols)] for _ in range(self.rows)]
    def _blank_line(self):
        return [(" ", None, False, False) for _ in range(self.cols)]

    def _lf(self):
        if self.r == self.bot:
            line = self.scr.pop(self.top)
            if not self.in_alt and self.top == 0: self.history.append(line)
            self.scr.insert(self.bot, self._blank_line())
        elif self.r < self.rows - 1:
            self.r += 1

    def _put(self, ch):
        if self.wrap_next:
            self.c = 0; self._lf(); self.wrap_next = False
        self.scr[self.r][self.c] = (ch,) + self.attr
        if self.c == self.cols - 1: self.wrap_next = True
        else: self.c += 1

    def _sgr(self, params):
        fg, bold, dim = self.attr
        ps = [int(x) if x else 0 for x in params.split(";")] if params else [0]
        for p in ps:
            if p == 0: fg, bold, dim = None, False, False
            elif p == 1: bold = True
            elif p == 2: dim = True
            elif 30 <= p <= 37: fg = p
        self.attr = (fg, bold, dim)

    def feed(self, data):
        self.buf += data
        s = self.buf; i = 0; n = len(s)
        while i < n:
            ch = s[i]
            if ch == "\x1b":
                if i + 1 >= n: break
                nx = s[i + 1]
                if nx == "7": self.saved = (self.r, self.c); i += 2; continue
                if nx == "8": self.r, self.c = self.saved; self.wrap_next = False; i += 2; continue
                if nx == "[":
                    m = re.match(r"\x1b\[([?0-9;]*)([A-Za-z])", s[i:])
                    if not m:
                        if n - i < 20: break
                        i += 2; continue
                    self._csi(m.group(1), m.group(2)); i += m.end(); continue
                i += 2; continue
            if ch == "\r": self.c = 0; self.wrap_next = False
            elif ch == "\n": self._lf(); self.wrap_next = False
            elif ch == "\b": self.c = max(0, self.c - 1); self.wrap_next = False
            elif ch == "\t": self.c = min(self.cols - 1, (self.c // 8 + 1) * 8)
            elif ch >= " ": self._put(ch)
            i += 1
        self.buf = s[i:]

    def _csi(self, p, f):
        if f == "m": self._sgr(p); return
        if p.startswith("?"):
            if p == "?1049" and f == "h" and not self.in_alt:
                self.alt_saved = (self.r, self.c); self.in_alt = True; self.alt = self._blank(); self.scr = self.alt
            elif p == "?1049" and f == "l" and self.in_alt:
                self.in_alt = False; self.scr = self.main; self.r, self.c = self.alt_saved
            return
        nums = [int(x) if x else 0 for x in p.split(";")] if p else []
        if f == "H":
            r = (nums[0] if nums and nums[0] else 1) - 1; c = (nums[1] if len(nums) > 1 and nums[1] else 1) - 1
            self.r, self.c = min(r, self.rows - 1), min(c, self.cols - 1); self.wrap_next = False
        elif f == "A": self.r = max(0, self.r - (nums[0] if nums and nums[0] else 1))
        elif f == "J":
            m = nums[0] if nums else 0
            if m == 0:
                self.scr[self.r][self.c:] = self._blank_line()[self.c:]
                for k in range(self.r + 1, self.rows): self.scr[k] = self._blank_line()
            elif m == 2:
                for k in range(self.rows): self.scr[k] = self._blank_line()
        elif f == "K":
            m = nums[0] if nums else 0
            if m == 0: self.scr[self.r][self.c:] = self._blank_line()[self.c:]
            elif m == 2: self.scr[self.r] = self._blank_line()
        elif f == "r":
            t = (nums[0] if nums and nums[0] else 1) - 1; b = (nums[1] if len(nums) > 1 and nums[1] else self.rows) - 1
            self.top, self.bot = t, min(b, self.rows - 1); self.r = self.c = 0; self.wrap_next = False

    def text(self):
        return "\n".join("".join(c[0] for c in row).rstrip() for row in self.scr)

    def html(self):
        col = {31: "#e06c75", 32: "#98c379", 33: "#e5c07b", 34: "#61afef", 35: "#c678dd", 36: "#56b6c2", 37: "#dcdfe4"}
        out = []
        for row in self.scr:
            line = []
            for ch, fg, bold, dim in row:
                st = []
                if fg: st.append("color:%s" % col.get(fg, "#dcdfe4"))
                if bold: st.append("font-weight:bold")
                if dim: st.append("opacity:.6")
                e = html.escape(ch)
                line.append('<span style="%s">%s</span>' % (";".join(st), e) if st else e)
            out.append("".join(line))
        return "\n".join(out)
