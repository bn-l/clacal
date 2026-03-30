"""Clacal menu-bar widget showcase — Manim animation."""

# ruff: noqa: F403, F405

from __future__ import annotations

import colorsys

from manim import *

ICON_S = 2.5
BG = "#0d1117"
ICON_BG = "#1e1e1e"


def _hsv_hex(h: float, s: float = 0.6, v: float = 0.925) -> str:
    r, g, b = colorsys.hsv_to_rgb(h, s, v)
    return f"#{int(r * 255):02x}{int(g * 255):02x}{int(b * 255):02x}"


def usage_color(value: float) -> str:
    """Green (on pace) → Red (max deviation)."""
    mag = min(max(abs(value), 0), 1)
    return _hsv_hex((1 - mag) * (120 / 360))


def budget_color(remaining: float) -> str:
    """Green (full budget) → Red (depleted)."""
    return _hsv_hex(min(max(remaining, 0), 1) * (120 / 360))


class ClacalShowcase(Scene):
    def construct(self):
        self.camera.background_color = BG
        self._calibrator_mode()
        self._dual_bar_mode()
        self._side_by_side()
        self._outro()

    # ── sections ───────────────────────────────────────

    def _calibrator_mode(self):
        header = Text("Single Bar Mode", font_size=40, weight=BOLD)
        header.to_edge(UP, buff=0.5)
        self.play(Write(header, run_time=0.6))

        val = ValueTracker(0)
        ic = LEFT * 1.2

        icon = always_redraw(lambda: _calibrator_icon(val.get_value(), ic))
        status = always_redraw(
            lambda: _status_label(val.get_value()).next_to(
                ic, DOWN, buff=ICON_S / 2 + 0.35
            )
        )
        readout = always_redraw(
            lambda: Text(
                f"{val.get_value():+.0%}", font_size=28, color=GRAY_B
            ).next_to(ic, DOWN, buff=ICON_S / 2 + 0.7)
        )

        desc = VGroup(
            Text("■ Single center-zero bar", font_size=20, color=GRAY_C),
            Text("■ Green = on pace", font_size=20, color=GRAY_C),
            Text("■ Red = deviation", font_size=20, color=GRAY_C),
            Text("■ Arrow at 15–50%", font_size=20, color=GRAY_C),
        ).arrange(DOWN, aligned_edge=LEFT, buff=0.18)
        desc.next_to(ic, RIGHT, buff=ICON_S / 2 + 0.8).shift(DOWN * 0.2)

        self.play(FadeIn(icon), FadeIn(status), FadeIn(readout), FadeIn(desc))
        self.wait(1)

        for target, hold in [
            (+0.30, 1.0),
            (+0.85, 1.2),
            (0, 0.6),
            (-0.30, 1.0),
            (-0.85, 1.2),
            (0, 0.8),
        ]:
            self.play(
                val.animate.set_value(target), run_time=2, rate_func=smooth
            )
            self.wait(hold)

        for m in [icon, status, readout]:
            m.clear_updaters()
        self.play(
            FadeOut(icon),
            FadeOut(status),
            FadeOut(readout),
            FadeOut(desc),
            FadeOut(header),
        )

    def _dual_bar_mode(self):
        header = Text("Dual Bar Mode", font_size=40, weight=BOLD)
        header.to_edge(UP, buff=0.5)
        self.play(Write(header, run_time=0.6))

        sv = ValueTracker(0)
        bv = ValueTracker(1.0)
        ic = LEFT * 1.2

        icon = always_redraw(
            lambda: _dual_bar_icon(sv.get_value(), bv.get_value(), ic)
        )

        gap = ICON_S * 2 / 18
        bw = (ICON_S - gap) / 2
        sl = Text("Session", font_size=14, color=GRAY_C).next_to(
            ic + LEFT * (gap / 2 + bw / 2), DOWN, buff=ICON_S / 2 + 0.15
        )
        bl = Text("Daily Budget", font_size=14, color=GRAY_C).next_to(
            ic + RIGHT * (gap / 2 + bw / 2), DOWN, buff=ICON_S / 2 + 0.15
        )

        sr = always_redraw(
            lambda: Text(
                f"session {sv.get_value():+.0%}", font_size=20, color=GRAY_B
            )
            .next_to(ic, RIGHT, buff=ICON_S / 2 + 0.8)
            .shift(UP * 0.15)
        )
        br = always_redraw(
            lambda: Text(
                f"budget  {bv.get_value():.0%}", font_size=20, color=GRAY_B
            )
            .next_to(ic, RIGHT, buff=ICON_S / 2 + 0.8)
            .shift(DOWN * 0.15)
        )

        desc = VGroup(
            Text("■ Left: session pace", font_size=20, color=GRAY_C),
            Text("■ Right: daily budget", font_size=20, color=GRAY_C),
            Text("■ Budget: green → red", font_size=20, color=GRAY_C),
        ).arrange(DOWN, aligned_edge=LEFT, buff=0.18)
        desc.next_to(ic, RIGHT, buff=ICON_S / 2 + 0.8).shift(DOWN * 1.2)

        self.play(
            FadeIn(icon),
            FadeIn(sl),
            FadeIn(bl),
            FadeIn(sr),
            FadeIn(br),
            FadeIn(desc),
        )
        self.wait(1)

        for s, b, hold in [
            (+0.6, 0.30, 1.5),
            (+0.9, 0.08, 1.5),
            (0, 0.50, 1.0),
            (-0.4, 0.85, 1.5),
            (0, 1.0, 0.8),
        ]:
            self.play(
                sv.animate.set_value(s),
                bv.animate.set_value(b),
                run_time=2.5,
                rate_func=smooth,
            )
            self.wait(hold)

        for m in [icon, sr, br]:
            m.clear_updaters()
        self.play(
            FadeOut(icon),
            FadeOut(sl),
            FadeOut(bl),
            FadeOut(sr),
            FadeOut(br),
            FadeOut(desc),
            FadeOut(header),
        )

    def _side_by_side(self):
        header = Text("Comparison", font_size=40, weight=BOLD)
        header.to_edge(UP, buff=0.5)
        self.play(Write(header, run_time=0.6))

        val = ValueTracker(0)
        bv = ValueTracker(1.0)
        cl = LEFT * 2.2
        dr = RIGHT * 2.2

        ci = always_redraw(lambda: _calibrator_icon(val.get_value(), cl))
        di = always_redraw(
            lambda: _dual_bar_icon(val.get_value(), bv.get_value(), dr)
        )
        clab = Text("Single Bar", font_size=20, color=GRAY_B).next_to(
            cl, DOWN, buff=ICON_S / 2 + 0.2
        )
        dlab = Text("Dual Bar", font_size=20, color=GRAY_B).next_to(
            dr, DOWN, buff=ICON_S / 2 + 0.2
        )

        self.play(FadeIn(ci), FadeIn(di), FadeIn(clab), FadeIn(dlab))
        self.wait(0.8)

        for v, b, hold in [
            (+0.4, 0.6, 1.2),
            (+0.85, 0.15, 1.5),
            (0, 0.5, 1.0),
            (-0.5, 0.9, 1.5),
            (0, 1.0, 0.8),
        ]:
            self.play(
                val.animate.set_value(v),
                bv.animate.set_value(b),
                run_time=2,
                rate_func=smooth,
            )
            self.wait(hold)

        for m in [ci, di]:
            m.clear_updaters()
        self.play(
            FadeOut(ci),
            FadeOut(di),
            FadeOut(clab),
            FadeOut(dlab),
            FadeOut(header),
        )

    def _outro(self):
        title = Text("Clacal", font_size=52, weight=BOLD)
        tag = Text("Know your usage at a glance", font_size=24, color=GRAY_B)
        tag.next_to(title, DOWN, buff=0.3)
        self.play(FadeIn(title, scale=0.8, run_time=1))
        self.play(FadeIn(tag, shift=UP * 0.2, run_time=0.8))
        self.wait(2)
        self.play(FadeOut(title), FadeOut(tag))


# ── icon builders ──────────────────────────────────────


def _calibrator_icon(value, center):
    """Always returns a VGroup with exactly 4 elements to avoid structure
    changes that cause always_redraw rendering glitches."""
    g = VGroup()
    cx, cy = float(center[0]), float(center[1])

    bg = RoundedRectangle(corner_radius=0.12, width=ICON_S, height=ICON_S)
    bg.set_fill(ICON_BG, opacity=1).set_stroke(WHITE, width=1, opacity=0.15)
    bg.move_to(center)
    g.add(bg)

    c = max(-1.0, min(1.0, float(value)))
    bh = abs(c) * ICON_S / 2
    draw_h = max(bh, 0.001)

    bar = Rectangle(width=ICON_S * 0.8, height=draw_h)
    bar.set_fill(usage_color(c), opacity=1 if bh > 0.005 else 0)
    bar.set_stroke(width=0)
    bar.move_to([cx, cy + (draw_h / 2 if c >= 0 else -draw_h / 2), 0])
    g.add(bar)

    g.add(
        Line([cx - ICON_S / 2, cy, 0], [cx + ICON_S / 2, cy, 0]).set_stroke(
            WHITE, width=2
        )
    )

    has_arrow = 0.15 < abs(c) < 0.5
    sz = ICON_S * 0.1
    tri = Triangle().scale(sz)
    if c > 0:
        tri.rotate(PI).move_to([cx, cy - ICON_S / 2 + sz * 1.8, 0])
    else:
        tri.move_to([cx, cy + ICON_S / 2 - sz * 1.8, 0])
    tri.set_fill(WHITE, opacity=1 if has_arrow else 0).set_stroke(width=0)
    g.add(tri)

    return g


def _dual_bar_icon(session, budget, center):
    """Always returns a VGroup with exactly 5 elements to avoid structure
    changes that cause always_redraw rendering glitches."""
    g = VGroup()
    cx, cy = float(center[0]), float(center[1])
    gap = ICON_S * 2 / 18
    bw = (ICON_S - gap) / 2
    lx = cx - gap / 2 - bw / 2
    rx = cx + gap / 2 + bw / 2

    bg = RoundedRectangle(corner_radius=0.12, width=ICON_S, height=ICON_S)
    bg.set_fill(ICON_BG, opacity=1).set_stroke(WHITE, width=1, opacity=0.15)
    bg.move_to(center)
    g.add(bg)

    # left — session deviation
    sc = max(-1.0, min(1.0, float(session)))
    sh = abs(sc) * ICON_S / 2
    draw_sh = max(sh, 0.001)
    lb = Rectangle(width=bw, height=draw_sh)
    lb.set_fill(usage_color(sc), opacity=1 if sh > 0.005 else 0)
    lb.set_stroke(width=0)
    lb.move_to([lx, cy + (draw_sh / 2 if sc >= 0 else -draw_sh / 2), 0])
    g.add(lb)

    # right — budget gauge (centered vertically)
    rem = max(0.0, min(1.0, float(budget)))
    gh = rem * ICON_S
    draw_gh = max(gh, 0.001)
    rb = Rectangle(width=bw, height=draw_gh)
    rb.set_fill(budget_color(rem), opacity=1 if gh > 0.005 else 0)
    rb.set_stroke(width=0)
    rb.move_to([rx, cy, 0])
    g.add(rb)

    # center line — left bar only
    g.add(
        Line([lx - bw / 2, cy, 0], [lx + bw / 2, cy, 0]).set_stroke(
            WHITE, width=2
        )
    )

    # arrow on left bar
    has_arrow = 0.15 < abs(sc) < 0.5
    sz = bw * 0.2
    tri = Triangle().scale(sz)
    if sc > 0:
        tri.rotate(PI).move_to([lx, cy - ICON_S / 2 + sz * 1.8, 0])
    else:
        tri.move_to([lx, cy + ICON_S / 2 - sz * 1.8, 0])
    tri.set_fill(WHITE, opacity=1 if has_arrow else 0).set_stroke(width=0)
    g.add(tri)

    return g


def _status_label(value):
    c = max(-1.0, min(1.0, float(value)))
    if abs(c) < 0.1:
        return Text("On Pace", font_size=24, color=GREEN)
    if c > 0.5:
        return Text("Heavy Usage — Ease Off", font_size=24, color=RED)
    if c > 0.15:
        return Text("Slightly Over — Ease Off", font_size=24, color=YELLOW)
    if c < -0.5:
        return Text("Very Light — Use More", font_size=24, color=RED)
    return Text("Light Usage — Use More", font_size=24, color=YELLOW)
